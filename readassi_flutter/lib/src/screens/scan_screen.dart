import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:image/image.dart' as img;

import '../app_state.dart';
import '../services/claude_service.dart';
import '../services/hand_detection_service.dart';
import 'book_detail_screen.dart';
import 'scan_camera_view.dart';

class ScanScreen extends StatefulWidget {
  final String bookId;
  final String bookTitle;

  const ScanScreen({super.key, required this.bookId, required this.bookTitle});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  static const Duration _stabilityRequiredDuration = Duration(
    milliseconds: 1200,
  );
  static const Duration _captureCooldownDuration = Duration(seconds: 2);
  static const Duration _frameProcessingThrottle = Duration(milliseconds: 250);
  static const double _motionDiffThreshold = 12.0;
  static const int _lumaSampleCount = 64;
  static const Duration _handDetectionThrottle = Duration(milliseconds: 700);
  // 촬영 직전 손 게이트가 신뢰할 손 감지 결과의 최대 허용 나이.
  static const Duration _handResultMaxAge = Duration(milliseconds: 1600);
  // 손 래치(추적 유지) 파라미터.
  // 손이 작아지며 빠져나가던 중이면 짧은 유예 후 해제.
  static const Duration _handExitGrace = Duration(milliseconds: 500);
  // 큰 손이 갑자기 사라지면(화면 밖으로만 나감) 더 오래 유지.
  static const Duration _handLatchTimeout = Duration(milliseconds: 2600);
  // 마지막 손 크기가 최대 크기 대비 이 비율 이하면 '빠져나가던 중'으로 본다.
  static const double _handExitShrinkRatio = 0.5;
  // 하단 여백 경계 슬라이더의 허용 범위.
  static const double _bottomRegionMin = 0.5;
  static const double _bottomRegionMax = 0.95;
  // 명령 3: 페이지를 가로 띠로 나눠, 손이 안 가린 띠만 모아 한 페이지를 조립한다.
  static const int _bandCount = 4;
  // 명령 3: 인접 캡처가 텍스트를 공유하도록 띠 구간 위아래에 두는 겹침 여유(정규화 높이).
  // 넉넉할수록 스티칭 앵커를 잡기 쉽고 품질 투표할 줄도 늘어난다(책 흔들림 대비).
  static const double _bandOverlap = 0.12;
  // 명령 3 스티칭: 겹침 앵커로 인정할 최소 연속 일치 줄 수.
  static const int _stitchMinRun = 2;
  // 명령 3 스티칭: 두 줄을 같은 줄로 볼 퍼지 유사도 임계값(0~1).
  static const double _stitchSimThreshold = 0.80;
  // 명령 3 스티칭: 겹침 앵커를 탐색할 윈도우 크기(줄 수).
  static const int _stitchWindow = 14;
  // 명령 3: 좌우 2페이지를 가르는 책등(중심선) 가로 위치(정규화 0~1)의 기본값·범위.
  static const double _spineXDefault = 0.5;
  static const double _spineMin = 0.30;
  static const double _spineMax = 0.70;
  // 슬라이스 1: 페이지 저장소(재독·누락 감지) 파라미터.
  static const int _fingerprintLineCount = 3; // 좌/우 각 상단에서 지문에 쓸 줄 수
  static const double _rereadSimThreshold = 0.6; // 재독으로 볼 지문 유사도(0~1)
  static const int _runningHeaderMinPages = 3; // 러닝 헤더로 볼 최소 출현 페이지 수
  static const int _pageNumberSearchLines = 6; // 하단 페이지번호를 찾을 줄 수
  static const int _pageNumberMaxTokens = 6; // 페이지번호 줄로 볼 최대 어절 수

  final String _googleVisionApiKey = dotenv.env['_googleVisionApiKey'] ?? "";
  final String _geminiApiKey = dotenv.env['_geminiApiKey'] ?? "";
  final ClaudeService _claudeService = ClaudeService();
  final HandDetectionService _handDetectionService = HandDetectionService();

  bool _isAutoMode = false;
  bool _isImageStreamActive = false;
  bool _awaitingMotionBeforeNextCapture = false;
  DateTime? _stableSince;
  DateTime? _lastCaptureAt;
  DateTime? _lastFrameProcessedAt;
  List<int>? _lastFrameSignature;

  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isCaptureBusy = false;
  bool _isProcessingAnalysis = false;

  double _minZoomLevel = 1.0;
  double _maxZoomLevel = 1.0;
  double _currentZoomLevel = 1.0;

  bool _debugPanelEnabled = false;
  bool _handDetectionBusy = false;
  DateTime? _lastHandDetectionAt;
  HandDetectionResult? _handResult;
  DateTime? _handResultAt;

  _CaptureStatus _captureStatus = _CaptureStatus.idle;
  String? _lastOcrSummary;

  // 손 래치: 한 번 검출된 손은 검출이 끊겨도 일정 조건까지 '있음'으로 유지한다.
  bool _handLatched = false;
  HandBox? _lastHandBox;
  DateTime? _lastHandSeenAt;
  double _lastHandArea = 0;
  double _peakHandArea = 0;

  // 손 위치 게이트: 손 박스가 이 높이 비율 아래(하단 여백)에 완전히 들어가
  // 있으면 본문을 안 가린 것으로 보고 촬영을 허용한다. 디버그 패널 슬라이더로 조절.
  double _bottomRegionTop = 0.80;

  // 명령 3: 책등 가로 위치(좌우 페이지 분리선). 캡처 시 자동 감지로 갱신되며,
  // 디버그 슬라이더를 건드리면 수동 모드로 전환돼 자동 갱신이 멈춘다.
  double _spineX = _spineXDefault;
  bool _spineManualOverride = false;

  // 명령 3: 가로 띠별 수집 상태 + 캡처별 텍스트 세그먼트(겹침 스티칭 입력).
  final List<bool> _bandCollected = List<bool>.filled(_bandCount, false);
  final List<_BandSegment> _bandSegments = [];
  // 디버그 'OCR 결과 전체보기'용 — 마지막 OCR/조립 전체 텍스트.
  String? _lastOcrFullText;

  // 슬라이스 1: 명령 3로 조립된 펼침면을 페이지 번호 키로 보관하는 저장소.
  // 재독(이미 읽은 페이지) 감지·중복 방지·누락 페이지 기록의 source of truth.
  final List<_StoredPage> _pageStore = [];
  // 러닝 헤더 감지용: 페이지 상단에 반복 인쇄되는 줄의 출현 페이지 수.
  final Map<String, int> _topLineFrequency = {};
  // 직전에 저장(또는 재독으로 확인)된 펼침면의 오른쪽 페이지 번호 — 다음 기대값 계산용.
  int? _lastCommittedRight;

  @override
  void initState() {
    super.initState();
    // 가로 모드 고정
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _initCamera();
    _loadPageStore();
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _controller?.dispose();
    super.dispose();
  }

  // --- 카메라 제어 로직 ---
  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      _controller = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await _controller!.initialize();

      _minZoomLevel = await _controller!.getMinZoomLevel();
      _maxZoomLevel = await _controller!.getMaxZoomLevel();

      if (!mounted) return;
      setState(() => _isCameraInitialized = true);
    } catch (e) {
      debugPrint("카메라 에러: $e");
    }
  }

  Future<void> _updateZoom(double zoom) async {
    if (_controller == null) return;
    final clampedZoom = zoom.clamp(_minZoomLevel, _maxZoomLevel);
    try {
      await _controller!.setZoomLevel(clampedZoom);
      setState(() => _currentZoomLevel = clampedZoom);
    } catch (e) {
      debugPrint("줌 설정 에러: $e");
    }
  }

  // --- 파일 시스템 로직 (로직 고도화 반영) ---
  Future<Map<String, String>> _getFilePaths() async {
    final dir = await getApplicationDocumentsDirectory();
    final bookDir = Directory(p.join(dir.path, 'books'));
    await bookDir.create(recursive: true);

    return {
      'pages': p.join(
        bookDir.path,
        '${widget.bookId}_pages.json',
      ), // 슬라이스 1: 페이지 저장소(분석 후 삭제됨)
      'story_db': p.join(
        bookDir.path,
        '${widget.bookId}_story_db.json',
      ), // AI 내부 참고용 상세 줄거리 DB
      'char_db': p.join(
        bookDir.path,
        '${widget.bookId}_char_db.json',
      ), // AI 내부 참고용 상세 인물 DB
    };
  }

  // --- OCR 및 촬영 로직 ---
  // 명령 3: Vision OCR 결과를 줄 단위로 파싱한다. 줄바꿈은 Vision의
  // detectedBreak가 아니라 단어 경계상자 좌표(X 리셋·Y 점프)로 직접 판정한다 —
  // 좁은 크롭에서는 Vision의 줄 그룹핑이 자주 틀려 두 줄이 합쳐지기 때문.
  Future<List<_VisionLine>> _getVisionLines(Uint8List bytes) async {
    final base64Image = base64Encode(bytes);
    final response = await http.post(
      Uri.parse(
        'https://vision.googleapis.com/v1/images:annotate?key=$_googleVisionApiKey',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'requests': [
          {
            'image': {'content': base64Image},
            'features': [
              {'type': 'DOCUMENT_TEXT_DETECTION'},
            ],
            'imageContext': {
              'languageHints': ['ko'],
            },
          },
        ],
      }),
    );

    if (response.statusCode != 200) return const [];
    final data = jsonDecode(response.body);
    final fullText = data['responses']?[0]?['fullTextAnnotation'];
    if (fullText == null) return const [];
    final pages = fullText['pages'] as List?;
    if (pages == null || pages.isEmpty) return const [];
    final page = pages.first;
    final pageHeight = (page['height'] as num?)?.toDouble() ?? 0;
    if (pageHeight <= 0) return const [];

    // 1단계: 모든 단어를 문단별로 모은다(경계상자 + 텍스트).
    final paragraphsWords = <List<_OcrWord>>[];
    final blocks = (page['blocks'] as List?) ?? const [];
    for (final block in blocks) {
      final paragraphs = (block['paragraphs'] as List?) ?? const [];
      for (final paragraph in paragraphs) {
        final words = (paragraph['words'] as List?) ?? const [];
        final wordList = <_OcrWord>[];
        for (final word in words) {
          final symbols = (word['symbols'] as List?) ?? const [];
          final sb = StringBuffer();
          for (final symbol in symbols) {
            sb.write((symbol['text'] as String?) ?? '');
          }
          final text = sb.toString();
          if (text.isEmpty) continue;
          final vertices = word['boundingBox']?['vertices'] as List?;
          if (vertices == null) continue;
          double minX = double.infinity, maxX = -1;
          double minY = double.infinity, maxY = -1;
          for (final vertex in vertices) {
            final vx = (vertex['x'] as num?)?.toDouble();
            final vy = (vertex['y'] as num?)?.toDouble();
            if (vx != null) {
              if (vx < minX) minX = vx;
              if (vx > maxX) maxX = vx;
            }
            if (vy != null) {
              if (vy < minY) minY = vy;
              if (vy > maxY) maxY = vy;
            }
          }
          if (maxX < 0 || maxY < 0) continue;
          wordList.add(_OcrWord(text, minX, maxX, minY, maxY));
        }
        if (wordList.isNotEmpty) paragraphsWords.add(wordList);
      }
    }
    if (paragraphsWords.isEmpty) return const [];

    // 2단계: 단어 높이의 중앙값 — 줄바꿈 임계값의 기준 스케일.
    final heights = <double>[];
    for (final words in paragraphsWords) {
      for (final w in words) {
        final h = w.maxY - w.minY;
        if (h > 0) heights.add(h);
      }
    }
    heights.sort();
    final medianHeight =
        heights.isEmpty ? pageHeight * 0.025 : heights[heights.length ~/ 2];
    // 같은 줄 안의 인접 단어는 X가 단조 증가하고 Y는 거의 그대로다.
    // 줄바꿈은 ① X가 왼쪽으로 리셋되거나 ② Y가 한 줄 높이만큼 아래로 점프한다.
    // ①은 카메라 세로 기울기에 영향받지 않고, ②는 X가 비슷할 때(기울기 영향이
    // 작을 때)만 실제로 작동하므로, 두 신호를 OR로 합치면 기울어진 사진에도 견고하다.
    final xResetMargin = medianHeight;
    final yJumpThreshold = medianHeight * 0.7;

    // 3단계: 문단별로 단어를 읽기순으로 보며 줄을 직접 끊는다.
    final result = <_VisionLine>[];
    for (final words in paragraphsWords) {
      final buffer = StringBuffer();
      double yTop = double.infinity;
      double yBottom = -1;

      void flushLine() {
        final text = buffer.toString().trim();
        if (text.isNotEmpty && yBottom >= 0) {
          result.add(_VisionLine(text, ((yTop + yBottom) / 2) / pageHeight));
        }
        buffer.clear();
        yTop = double.infinity;
        yBottom = -1;
      }

      _OcrWord? prev;
      for (final w in words) {
        final p = prev;
        if (p != null) {
          final xReset = w.minX < p.minX - xResetMargin;
          final yJump =
              (w.minY + w.maxY) / 2 - (p.minY + p.maxY) / 2 > yJumpThreshold;
          if (xReset || yJump) {
            flushLine();
          } else {
            buffer.write(' ');
          }
        }
        buffer.write(w.text);
        if (w.minY < yTop) yTop = w.minY;
        if (w.maxY > yBottom) yBottom = w.maxY;
        prev = w;
      }
      flushLine();
    }
    result.sort((a, b) => a.centerY.compareTo(b.centerY));
    return result;
  }

  // 명령 3: 한 이미지를 Vision OCR해 비지 않은 줄(_VisionLine, 세로순)로 돌려준다.
  // 줄별 centerY는 스티칭 품질 투표(크롭 경계에서의 거리)에 쓰인다.
  Future<List<_VisionLine>> _ocrLines(Uint8List bytes) async {
    final visionLines = await _getVisionLines(bytes);
    return visionLines.where((l) => l.text.trim().isNotEmpty).toList();
  }

  Future<void> _startAutoCapture() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isAutoMode ||
        _isCaptureBusy ||
        _isProcessingAnalysis) {
      return;
    }

    setState(() {
      _isAutoMode = true;
      _awaitingMotionBeforeNextCapture = false;
      _stableSince = null;
      _lastCaptureAt = null;
      _lastFrameProcessedAt = null;
      _lastFrameSignature = null;
      _lastHandDetectionAt = null;
      _handResult = null;
      _handResultAt = null;
      _captureStatus = _CaptureStatus.motion;
      _lastOcrSummary = null;
      _lastOcrFullText = null;
      _handLatched = false;
      _lastHandBox = null;
      _lastHandSeenAt = null;
      _lastHandArea = 0;
      _peakHandArea = 0;
      _resetBandCollection();
    });

    await _ensureImageStreamRunning();

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("자동 촬영을 시작합니다.")));
  }

  Future<void> _captureSinglePage() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isCaptureBusy ||
        _isProcessingAnalysis) {
      return;
    }

    setState(() => _isCaptureBusy = true);
    try {
      final wasStreaming = _isImageStreamActive;
      if (wasStreaming) {
        await _stopImageStream();
      }

      final photo = await _controller!.takePicture();
      final bytes = await File(photo.path).readAsBytes();

      // 명령 3과 동일하게 책등 기준 좌우로 갈라 각각 OCR한 뒤 같은 페이지 저장소로 보낸다.
      final oriented = _decodeOriented(bytes);
      List<_VisionLine> leftLines;
      List<_VisionLine> rightLines;
      if (oriented == null) {
        // 디코딩 실패 — 통짜 OCR로 폴백(좌우 분리 포기).
        leftLines = await _ocrLines(bytes);
        rightLines = const [];
      } else {
        if (!_spineManualOverride) {
          final detected = _detectSpineX(oriented);
          if (detected != null && mounted) {
            setState(() => _spineX = detected.clamp(_spineMin, _spineMax));
          }
        }
        final leftCrop = _cropEncode(oriented, 0.0, 1.0, 0.0, _spineX);
        final rightCrop = _cropEncode(oriented, 0.0, 1.0, _spineX, 1.0);
        leftLines = await _ocrLines(leftCrop);
        rightLines = await _ocrLines(rightCrop);
      }
      await _commitSpread(leftLines, rightLines, false);
      // 페이지 전체를 깨끗하게 한 장으로 찍었으므로, 진행 중이던 띠 수집은 폐기.
      _resetBandCollection();

      if (mounted && _isAutoMode) {
        _lastCaptureAt = DateTime.now();
        _awaitingMotionBeforeNextCapture = true;
        _stableSince = null;
      }

      if (wasStreaming && _isAutoMode) {
        await _ensureImageStreamRunning();
      }
    } catch (e) {
      debugPrint("촬영 오류: $e");
    } finally {
      if (mounted) setState(() => _isCaptureBusy = false);
    }
  }

  Future<void> _stopAutoCapture() async {
    if (!_isAutoMode) return;

    await _stopImageStream();

    setState(() {
      _isAutoMode = false;
      _awaitingMotionBeforeNextCapture = false;
      _stableSince = null;
      _lastCaptureAt = null;
      _lastFrameProcessedAt = null;
      _lastFrameSignature = null;
      _lastHandDetectionAt = null;
      _handResult = null;
      _handResultAt = null;
      _captureStatus = _CaptureStatus.idle;
      _handLatched = false;
      _lastHandBox = null;
      _lastHandSeenAt = null;
      _lastHandArea = 0;
      _peakHandArea = 0;
      _resetBandCollection();
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("자동 촬영을 멈췄습니다. 분석을 눌러 결과를 반영하세요.")),
    );
  }

  Future<void> _ensureImageStreamRunning() async {
    if (_controller == null || _isImageStreamActive) return;
    try {
      await _controller!.startImageStream(_handleCameraImage);
      _isImageStreamActive = true;
    } catch (e) {
      debugPrint("이미지 스트림 시작 오류: $e");
    }
  }

  Future<void> _stopImageStream() async {
    if (_controller == null || !_isImageStreamActive) return;
    try {
      await _controller!.stopImageStream();
    } catch (e) {
      debugPrint("이미지 스트림 종료 오류: $e");
    } finally {
      _isImageStreamActive = false;
    }
  }

  Future<void> _handleCameraImage(CameraImage image) async {
    if (!_isAutoMode || _isCaptureBusy || _isProcessingAnalysis) return;

    final now = DateTime.now();

    // 손 감지는 디버그 토글과 무관하게 촬영 중 항상 실행한다(촬영 게이트가 사용).
    _maybeRunHandDetection(image, now);

    if (_lastFrameProcessedAt != null &&
        now.difference(_lastFrameProcessedAt!) < _frameProcessingThrottle) {
      return;
    }
    _lastFrameProcessedAt = now;

    final signature = _buildFrameSignature(image);
    if (signature.isEmpty) return;

    if (_lastFrameSignature == null) {
      _lastFrameSignature = signature;
      return;
    }

    final diff = _calculateFrameDiff(_lastFrameSignature!, signature);
    _lastFrameSignature = signature;

    if (diff >= _motionDiffThreshold) {
      _stableSince = null;
      _awaitingMotionBeforeNextCapture = false;
      _setCaptureStatus(_CaptureStatus.motion);
      return;
    }

    if (_awaitingMotionBeforeNextCapture) {
      // 직전 촬영 후 다음 페이지로 넘기는 움직임을 기다리는 중.
      _setCaptureStatus(_CaptureStatus.motion);
      return;
    }

    _stableSince ??= now;

    final stableDuration = now.difference(_stableSince!);
    final cooldownFinished =
        _lastCaptureAt == null ||
        now.difference(_lastCaptureAt!) >= _captureCooldownDuration;

    if (!(cooldownFinished && stableDuration >= _stabilityRequiredDuration)) {
      // 아직 안정 시간이 모자람 — 안정될 때까지 대기.
      _setCaptureStatus(_CaptureStatus.motion);
      return;
    }

    // 안정됨 → 촬영 직전, 손이 본문(=전체 프레임)과 겹치는지 검사한다.
    final hand = _handResult;
    final handFresh =
        hand != null &&
        _handResultAt != null &&
        now.difference(_handResultAt!) <= _handResultMaxAge;

    if (hand == null || !handFresh || hand.error != null) {
      // 최신 손 감지 결과가 아직 없음 — 확정될 때까지 촬영을 보류한다.
      _setCaptureStatus(_CaptureStatus.checkingHand);
      return;
    }

    if (_handLatched && _handCoversText()) {
      // 손이 본문을 가림 → 명령 3: 손이 안 가린 깨끗한 띠만 골라 수집한다.
      await _collectCleanBands();
      return;
    }
    // 손이 검출/추적되더라도 하단 여백 영역 안에만 있으면 본문은 안 가린 것으로 본다.

    // 손이 본문과 안 겹침 → 깨끗한 프레임. 명령 2: 페이지 전체를 한 장으로 촬영.
    _setCaptureStatus(_CaptureStatus.capturing);
    await _captureSinglePage();
  }

  // 디버그 패널용 손 감지. 밝기 게이트와 무관하게 자체 스로틀로 띄엄띄엄 실행한다.
  void _maybeRunHandDetection(CameraImage image, DateTime now) {
    if (_handDetectionBusy) return;
    if (_lastHandDetectionAt != null &&
        now.difference(_lastHandDetectionAt!) < _handDetectionThrottle) {
      return;
    }
    _lastHandDetectionAt = now;
    _handDetectionBusy = true;

    _handDetectionService
        .detect(image)
        .then((result) {
          if (!mounted) return;
          final at = DateTime.now();
          setState(() {
            _handResult = result;
            _handResultAt = at;
            _updateHandLatch(result, at);
          });
        })
        .whenComplete(() => _handDetectionBusy = false);
  }

  // 손 래치 갱신: 한 번 검출된 손은 검출이 끊겨도 일정 조건까지 '있음'으로 유지한다.
  void _updateHandLatch(HandDetectionResult result, DateTime now) {
    if (result.error != null) {
      // 감지 오류 시 래치 상태를 보수적으로 그대로 둔다.
      return;
    }

    if (result.detected && result.boxes.isNotEmpty) {
      final box = _largestHandBox(result.boxes);
      final area = _boxArea(box);
      _lastHandBox = box;
      _lastHandArea = area;
      _lastHandSeenAt = now;
      if (!_handLatched) {
        _handLatched = true;
        _peakHandArea = area;
      } else if (area > _peakHandArea) {
        _peakHandArea = area;
      }
      return;
    }

    // 검출이 끊김 — 래치돼 있으면 풀지 여부를 판정한다.
    if (!_handLatched) return;
    final lastSeen = _lastHandSeenAt;
    if (lastSeen == null) {
      _clearHandLatch();
      return;
    }

    final sinceSeen = now.difference(lastSeen);
    // 마지막에 본 손이 최대 크기 대비 충분히 작아졌으면(=빠져나가던 중) 빨리 해제,
    // 큰 상태로 갑자기 사라졌으면(=화면 밖으로만 나감, 본문 여전히 가림) 오래 유지.
    final wasShrinking =
        _peakHandArea > 0 &&
        _lastHandArea <= _peakHandArea * _handExitShrinkRatio;
    final wasTiny = _lastHandArea <= 0.04;
    final wasExiting = wasShrinking || wasTiny;

    final expired = wasExiting
        ? sinceSeen >= _handExitGrace
        : sinceSeen >= _handLatchTimeout;
    if (expired) {
      _clearHandLatch();
    }
  }

  void _clearHandLatch() {
    _handLatched = false;
    _lastHandBox = null;
    _lastHandSeenAt = null;
    _lastHandArea = 0;
    _peakHandArea = 0;
  }

  HandBox _largestHandBox(List<HandBox> boxes) {
    HandBox best = boxes.first;
    double bestArea = _boxArea(best);
    for (final box in boxes.skip(1)) {
      final area = _boxArea(box);
      if (area > bestArea) {
        best = box;
        bestArea = area;
      }
    }
    return best;
  }

  double _boxArea(HandBox box) {
    final width = (box.right - box.left).clamp(0.0, 1.0);
    final height = (box.bottom - box.top).clamp(0.0, 1.0);
    return width * height;
  }

  // 게이트 판정에 쓸 손 박스 목록: 실시간 검출 박스가 있으면 그걸,
  // 검출이 끊겨 추적 유지 중이면 마지막으로 본 박스를 쓴다.
  List<HandBox> _effectiveHandBoxes() {
    final live = _handResult?.boxes ?? const <HandBox>[];
    if (live.isNotEmpty) return live;
    final last = _lastHandBox;
    if (_handLatched && last != null) return [last];
    return const [];
  }

  // 손이 본문 영역(하단 여백 위쪽)을 가리는지 판정한다.
  // 손 박스 윗변이 하단 여백 경계보다 위에 있으면 본문을 가리는 것으로 본다.
  bool _handCoversText() {
    final boxes = _effectiveHandBoxes();
    if (boxes.isEmpty) return true; // 위치 정보 없음 → 보수적으로 가림 간주
    for (final box in boxes) {
      if (box.top < _bottomRegionTop) return true;
    }
    return false;
  }

  // 디버그 패널 슬라이더에서 하단 여백 경계를 조절한다.
  void _updateBottomRegionTop(double value) {
    final clamped = value.clamp(_bottomRegionMin, _bottomRegionMax);
    if (clamped == _bottomRegionTop || !mounted) return;
    setState(() => _bottomRegionTop = clamped);
  }

  // 명령 3: 디버그 패널 슬라이더에서 책등 위치를 수동 보정한다(수동 모드 전환).
  void _updateSpineX(double value) {
    if (!mounted) return;
    setState(() {
      _spineX = value.clamp(_spineMin, _spineMax);
      _spineManualOverride = true;
    });
  }

  // 명령 3: 책등 위치를 자동 감지 모드로 되돌린다(다음 캡처에서 다시 감지).
  void _resetSpineAuto() {
    if (!mounted) return;
    setState(() => _spineManualOverride = false);
  }

  // 명령 3: 각 가로 띠를 손이 가리고 있는지 판정한다(손 박스의 세로 구간 겹침).
  List<bool> _bandCoverage() {
    final covered = List<bool>.filled(_bandCount, false);
    final boxes = _effectiveHandBoxes();
    if (boxes.isEmpty) return covered;
    for (int i = 0; i < _bandCount; i++) {
      final bandTop = i / _bandCount;
      final bandBottom = (i + 1) / _bandCount;
      for (final box in boxes) {
        if (box.bottom > bandTop && box.top < bandBottom) {
          covered[i] = true;
          break;
        }
      }
    }
    return covered;
  }

  // 명령 3: 띠 수집 상태를 초기화한다(새 페이지 시작/완성/전체촬영 시).
  void _resetBandCollection() {
    for (int i = 0; i < _bandCount; i++) {
      _bandCollected[i] = false;
    }
    _bandSegments.clear();
  }

  // 명령 3: 손이 본문을 가린 동안, 손이 안 가린 깨끗한 띠 구간을 골라 수집한다.
  Future<void> _collectCleanBands() async {
    final coverage = _bandCoverage();
    // 손에 안 가린(coverage=false) 미수집 띠들 중 위에서부터 첫 연속 구간을 찾는다.
    int start = -1;
    int end = -1;
    for (int i = 0; i < _bandCount; i++) {
      final clean = !_bandCollected[i] && !coverage[i];
      if (clean) {
        if (start < 0) start = i;
        end = i;
      } else if (start >= 0) {
        break;
      }
    }
    if (start < 0) {
      // 아직 못 모은 띠가 전부 손에 가려짐 — 대기.
      _setCaptureStatus(_CaptureStatus.handOverlap);
      return;
    }
    _setCaptureStatus(_CaptureStatus.capturing);
    await _captureBandFrame(start, end);
  }

  // 명령 3: 깨끗한 띠 구간[bandStart..bandEnd]을 촬영·크롭해 OCR하고 세그먼트로 저장한다.
  Future<void> _captureBandFrame(int bandStart, int bandEnd) async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isCaptureBusy ||
        _isProcessingAnalysis) {
      return;
    }

    setState(() => _isCaptureBusy = true);
    try {
      final wasStreaming = _isImageStreamActive;
      if (wasStreaming) {
        await _stopImageStream();
      }

      final photo = await _controller!.takePicture();
      final bytes = await File(photo.path).readAsBytes();
      // 깨끗한 띠 구간만 세로로 크롭 → 손 영역을 제거해 Vision 레이아웃 교란을 줄인다.
      // 인접 캡처와 텍스트를 공유하도록 위아래로 _bandOverlap만큼 넉넉히 자른다.
      final cropTop = (bandStart / _bandCount) - _bandOverlap;
      final cropBottom = ((bandEnd + 1) / _bandCount) + _bandOverlap;
      // 좌우 2페이지는 책등에서 갈라 각각 OCR한다 — 가로 띠로 자르면 Vision이
      // 좌우 컬럼을 한 줄로 이어붙여 버려서, 컬럼별로 따로 줘야 순서가 맞는다.
      final oriented = _decodeOriented(bytes);
      List<_VisionLine> leftLines;
      List<_VisionLine> rightLines;
      if (oriented == null) {
        // 디코딩 실패 — 통짜 OCR로 폴백(이 경우 좌우 분리는 포기).
        leftLines = await _ocrLines(bytes);
        rightLines = const [];
      } else {
        // 첫 띠 캡처에서 책등 위치를 자동 감지한다(수동 보정 중이면 건너뜀).
        if (!_spineManualOverride && _bandSegments.isEmpty) {
          final detected = _detectSpineX(oriented);
          if (detected != null && mounted) {
            setState(() => _spineX = detected.clamp(_spineMin, _spineMax));
          }
        }
        final leftCrop = _cropEncode(oriented, cropTop, cropBottom, 0.0, _spineX);
        final rightCrop = _cropEncode(
          oriented,
          cropTop,
          cropBottom,
          _spineX,
          1.0,
        );
        leftLines = await _ocrLines(leftCrop);
        rightLines = await _ocrLines(rightCrop);
      }

      _bandSegments.add(
        _BandSegment(bandStart, bandEnd, leftLines, rightLines),
      );
      for (int i = bandStart; i <= bandEnd; i++) {
        _bandCollected[i] = true;
      }

      if (mounted && _isAutoMode) {
        // 띠 캡처 사이에는 움직임을 기다리지 않는다 — 다음 깨끗한 띠가 생기면 바로 잡는다.
        _lastCaptureAt = DateTime.now();
        _stableSince = null;
      }

      if (_bandCollected.every((c) => c)) {
        await _assembleAndSaveBands();
      } else {
        // 슬라이스 3: 맨 위 띠가 모였으면 재독을 미리 검사해 조기 종료한다.
        _checkEarlyReread();
      }

      if (wasStreaming && _isAutoMode) {
        await _ensureImageStreamRunning();
      }
    } catch (e) {
      debugPrint("띠 촬영 오류: $e");
    } finally {
      if (mounted) setState(() => _isCaptureBusy = false);
    }
  }

  // 명령 3: JPEG 바이트를 디코딩하고 EXIF 회전을 픽셀에 반영해 돌려준다.
  // (회전을 반영해야 이후 세로/가로 크롭 축이 맞는다.) 실패 시 null.
  img.Image? _decodeOriented(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      return img.bakeOrientation(decoded);
    } catch (e) {
      debugPrint("명령 3: 사진 디코딩 실패 — 통짜 OCR로 폴백: $e");
      return null;
    }
  }

  // 명령 3: 이미지를 정규화 사각형 [left..right]×[top..bottom]으로 크롭해 JPEG로 인코딩한다.
  Uint8List _cropEncode(
    img.Image src,
    double topFrac,
    double bottomFrac,
    double leftFrac,
    double rightFrac,
  ) {
    final w = src.width;
    final h = src.height;
    final x = (leftFrac.clamp(0.0, 1.0) * w).round().clamp(0, w - 1);
    final right = (rightFrac.clamp(0.0, 1.0) * w).round().clamp(x + 1, w);
    final y = (topFrac.clamp(0.0, 1.0) * h).round().clamp(0, h - 1);
    final bottom = (bottomFrac.clamp(0.0, 1.0) * h).round().clamp(y + 1, h);
    final crop = img.copyCrop(
      src,
      x: x,
      y: y,
      width: right - x,
      height: bottom - y,
    );
    return Uint8List.fromList(img.encodeJpg(crop, quality: 90));
  }

  // 명령 3: 펼친 책의 책등(좌우 페이지 사이 골) 가로 위치를 자동 감지한다.
  // 책등은 글자가 없어 가로 명암 변화(텍스처)가 가장 적은 세로 컬럼이다.
  // 가로 중앙 30~70% 구간에서 텍스처가 최소인 컬럼을 찾는다. 실패 시 null.
  double? _detectSpineX(img.Image src) {
    // 스캔을 가볍게 하려고 폭 480으로 축소한다.
    final small = src.width > 480 ? img.copyResize(src, width: 480) : src;
    final w = small.width;
    final h = small.height;
    if (w < 20 || h < 20) return null;
    // 세로 중앙 25~75% 행, 가로 중앙 30~70% 열만 본다(머리/꼬리·바깥여백 제외).
    final yStart = (h * 0.25).round();
    final yEnd = (h * 0.75).round();
    final xStart = (w * 0.30).round();
    final xEnd = (w * 0.70).round();
    if (xStart < 1 || xEnd > w || xEnd - xStart < 3 || yEnd - yStart < 3) {
      return null;
    }

    // 컬럼별 가로 명암 변화량 합 — 글자 컬럼은 크고, 책등 골은 작다.
    final energy = List<double>.filled(xEnd - xStart, 0);
    for (int x = xStart; x < xEnd; x++) {
      double sum = 0;
      for (int y = yStart; y < yEnd; y++) {
        final cur = small.getPixel(x, y);
        final prev = small.getPixel(x - 1, y);
        final cl = (cur.r + cur.g + cur.b) / 3;
        final pl = (prev.r + prev.g + prev.b) / 3;
        sum += (cl - pl).abs();
      }
      energy[x - xStart] = sum;
    }

    // 살짝 평활화한 뒤 텍스처가 최소인 컬럼을 책등으로 본다.
    double bestScore = double.infinity;
    int bestIdx = -1;
    const window = 2;
    for (int i = 0; i < energy.length; i++) {
      double acc = 0;
      int n = 0;
      for (int k = -window; k <= window; k++) {
        final j = i + k;
        if (j >= 0 && j < energy.length) {
          acc += energy[j];
          n++;
        }
      }
      final score = acc / n;
      if (score < bestScore) {
        bestScore = score;
        bestIdx = i;
      }
    }
    if (bestIdx < 0) return null;
    return (xStart + bestIdx) / w;
  }

  // 명령 3: 한 컬럼(좌 또는 우)의 띠 세그먼트들을 겹침 앵커로 이어붙인다.
  // 앵커가 잡히면 겹침 구간의 각 줄은 두 띠 중 크롭 경계에서 더 안쪽(품질 높은)
  // 사본을 채택한다. 앵커를 못 찾으면 무손실로 그대로 이어붙이고 실패 플래그를 켠다.
  (List<_VisionLine>, bool) _stitchColumn(
    List<List<_VisionLine>> columnSegments,
  ) {
    final merged = <_VisionLine>[];
    bool failed = false;
    for (final lines in columnSegments) {
      if (lines.isEmpty) continue;
      if (merged.isEmpty) {
        merged.addAll(lines);
        continue;
      }
      final anchor = _findStitchAnchor(merged, lines);
      if (anchor == null) {
        // 앵커 없음 — 무음 손실 대신 그대로 이어붙이고 경고한다.
        failed = true;
        merged.addAll(lines);
        continue;
      }
      // 앵커가 정한 offset(delta)으로 겹침 구간 줄을 1:1로 짝짓는다.
      // merged(위 띠)의 꼬리는 곧 겹침 구간이므로, 각 짝에서 품질 높은 쪽을 남긴다.
      //   merged 인덱스 (j + delta)  ↔  lines 인덱스 j
      final delta = anchor.tailIndex - anchor.headIndex;
      int jStart = math.max(0, -delta);
      int jEnd = math.min(lines.length, merged.length - delta);
      if (jEnd < jStart) jEnd = jStart;
      int upperEnd = jStart + delta;
      if (upperEnd < 0) upperEnd = 0;
      if (upperEnd > merged.length) upperEnd = merged.length;

      final upperUnique = merged.sublist(0, upperEnd); // 위 띠 고유 구간
      final voted = <_VisionLine>[]; // 겹침 구간 — 품질 높은 사본 채택
      for (int j = jStart; j < jEnd; j++) {
        final fromUpper = merged[j + delta];
        final fromLower = lines[j];
        voted.add(
          _lineQuality(fromLower) > _lineQuality(fromUpper)
              ? fromLower
              : fromUpper,
        );
      }
      final lowerUnique = lines.sublist(jEnd); // 아래 띠 고유 구간

      merged
        ..clear()
        ..addAll(upperUnique)
        ..addAll(voted)
        ..addAll(lowerUnique);
    }
    return (merged, failed);
  }

  // 명령 3 스티칭: 줄의 품질 = 크롭 경계에서의 거리(0=경계, 0.5=중앙).
  // 경계에 가까운 줄일수록 글자가 잘려 손상되므로, 클수록 신뢰할 수 있다.
  double _lineQuality(_VisionLine line) {
    final c = line.centerY;
    return c < 1 - c ? c : 1 - c;
  }

  // 명령 3 스티칭: result(앞 누적)와 next(다음 세그먼트)의 겹침 앵커를 찾는다.
  // 못 찾으면 null. 찾으면 result는 tailIndex 이후를 버리고 next를 headIndex부터 붙인다.
  _StitchAnchor? _findStitchAnchor(
    List<_VisionLine> result,
    List<_VisionLine> next,
  ) {
    final tailStart = math.max(0, result.length - _stitchWindow);
    final headEnd = math.min(next.length, _stitchWindow);
    _StitchAnchor? best;
    double bestScore = 0;
    for (int ti = tailStart; ti < result.length; ti++) {
      for (int hi = 0; hi < headEnd; hi++) {
        int run = 0;
        double score = 0;
        while (ti + run < result.length &&
            hi + run < next.length &&
            _lineSimilar(result[ti + run].text, next[hi + run].text)) {
          score += _anchorWeight(next[hi + run].text);
          run++;
        }
        // 연속 N줄 이상 일치할 때만 앵커로 인정 — 단일 줄 오매칭을 막는다.
        if (run >= _stitchMinRun && score > bestScore) {
          bestScore = score;
          best = _StitchAnchor(ti, hi);
        }
      }
    }
    return best;
  }

  // 두 줄이 같은 줄인지 — 공백 제거 후 편집거리 기반 퍼지 유사도로 판정한다.
  bool _lineSimilar(String a, String b) {
    final na = a.replaceAll(RegExp(r'\s+'), '');
    final nb = b.replaceAll(RegExp(r'\s+'), '');
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb) return true;
    final maxLen = math.max(na.length, nb.length);
    return 1.0 - _levenshtein(na, nb) / maxLen >= _stitchSimThreshold;
  }

  // 앵커 우선순위 가중치 — 길고 어절(토큰)이 많은 '특이한' 줄일수록 높게 친다.
  double _anchorWeight(String line) {
    final tokens = line
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .length;
    return tokens + line.replaceAll(RegExp(r'\s+'), '').length / 10.0;
  }

  // 두 문자열의 Levenshtein 편집거리(롤링 배열).
  int _levenshtein(String a, String b) {
    final m = a.length;
    final n = b.length;
    if (m == 0) return n;
    if (n == 0) return m;
    var prev = List<int>.generate(n + 1, (i) => i);
    var cur = List<int>.filled(n + 1, 0);
    for (int i = 1; i <= m; i++) {
      cur[0] = i;
      for (int j = 1; j <= n; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = math.min(
          math.min(cur[j - 1] + 1, prev[j] + 1),
          prev[j - 1] + cost,
        );
      }
      final tmp = prev;
      prev = cur;
      cur = tmp;
    }
    return prev[n];
  }

  // 명령 3: 모든 띠가 모이면 좌/우 컬럼을 각각 스티칭한 뒤 페이지 저장소에 반영한다.
  Future<void> _assembleAndSaveBands() async {
    // 세그먼트를 띠 순서(위→아래)로 정렬한 뒤 컬럼별로 겹침 앵커 스티칭한다.
    final segments = List<_BandSegment>.from(_bandSegments)
      ..sort((a, b) => a.bandStart.compareTo(b.bandStart));
    final (leftMerged, leftFailed) = _stitchColumn([
      for (final s in segments) s.leftLines,
    ]);
    final (rightMerged, rightFailed) = _stitchColumn([
      for (final s in segments) s.rightLines,
    ]);
    final stitchFailed = leftFailed || rightFailed;

    _resetBandCollection();
    // 한 페이지 완성 — 다음 페이지로 넘기는 움직임을 기다린다.
    _awaitingMotionBeforeNextCapture = true;
    _stableSince = null;

    await _commitSpread(leftMerged, rightMerged, stitchFailed);
  }

  // 슬라이스 1: 조립된 펼침면 한 장을 페이지 저장소에 반영한다.
  // 상단 지문으로 지금까지 읽은 모든 페이지와 비교해 재독이면 중복 저장하지 않고,
  // 새 페이지면 좌/우 하단에서 페이지 번호를 매겨 보관한다.
  Future<void> _commitSpread(
    List<_VisionLine> leftLines,
    List<_VisionLine> rightLines,
    bool stitchFailed,
  ) async {
    final leftText = leftLines
        .map((l) => l.text.trim())
        .where((t) => t.isNotEmpty)
        .join('\n');
    final rightText = rightLines
        .map((l) => l.text.trim())
        .where((t) => t.isNotEmpty)
        .join('\n');
    final pageText = [
      leftText,
      rightText,
    ].where((t) => t.trim().isNotEmpty).join('\n');
    if (pageText.trim().isEmpty) {
      debugPrint("명령 3: 조립된 텍스트가 비어 저장하지 않습니다.");
      return;
    }

    final fingerprint = _buildFingerprintLines(leftLines, rightLines);
    final quality = _pageQuality(pageText);
    final warn = stitchFailed ? " · 스티칭 경고" : "";

    // 재독 검사: 지금까지 저장된 모든 페이지의 상단 지문과 비교한다.
    _StoredPage? matched;
    double bestSim = 0;
    for (final page in _pageStore) {
      final sim = _fingerprintSimilarity(fingerprint, page.topLines);
      if (sim > bestSim) {
        bestSim = sim;
        matched = page;
      }
    }

    if (matched != null && bestSim >= _rereadSimThreshold) {
      // 이미 읽은 페이지 — 새로 저장하지 않는다. 더 선명하면 본문만 교체한다.
      final hit = matched;
      if (quality > hit.quality) {
        hit.text = pageText;
        hit.quality = quality;
      }
      _lastCommittedRight = hit.rightNumber;
      debugPrint(
        "명령 3: 재독으로 판단 — 기존 ${hit.rightNumber}P 유지"
        "(유사도 ${bestSim.toStringAsFixed(2)}).",
      );
      if (mounted) {
        AppStateScope.of(
          context,
        ).updateBookCurrentPage(widget.bookId, hit.rightNumber);
      }
      await _persistPageStore();
      if (mounted) {
        setState(() {
          _lastOcrFullText = pageText;
          _lastOcrSummary = _summaryOf(pageText);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("이미 읽은 페이지로 인식 — ${hit.rightNumber}P, 재저장 안 함$warn"),
          ),
        );
      }
      return;
    }

    // 새 페이지 — 좌/우 하단에서 페이지 번호를 각각 추출한다(B안).
    final expectedLeft = _lastCommittedRight == null
        ? null
        : _lastCommittedRight! + 1;
    int? leftNumber = _extractBottomPageNumber(leftLines);
    int? rightNumber = _extractBottomPageNumber(rightLines);
    final numberConfirmed = leftNumber != null || rightNumber != null;
    // 펼침면의 좌·우 페이지 번호는 연속이어야 한다(left = right - 1).
    // 둘 다 잡혔는데 인접하지 않으면 한쪽이 장·절 번호 등을 오인식한 것 —
    // 더 큰 값을 실제 페이지로 보고, 그 값이 나온 쪽 기준으로 다른 쪽을 보정한다.
    if (leftNumber != null &&
        rightNumber != null &&
        rightNumber != leftNumber + 1) {
      if (leftNumber >= rightNumber) {
        rightNumber = leftNumber + 1;
      } else {
        leftNumber = rightNumber - 1;
      }
    }
    // 한쪽만 잡혔으면 다른 쪽을 인접 번호로 역산한다.
    leftNumber ??= rightNumber != null ? rightNumber - 1 : (expectedLeft ?? 1);
    rightNumber ??= leftNumber + 1;

    final page = _StoredPage(
      leftNumber: leftNumber,
      rightNumber: rightNumber,
      numberConfirmed: numberConfirmed,
      text: pageText,
      topLines: fingerprint,
      quality: quality,
    );
    _pageStore.add(page);
    _registerTopLines(fingerprint);
    _lastCommittedRight = rightNumber;
    if (mounted) {
      AppStateScope.of(
        context,
      ).updateBookCurrentPage(widget.bookId, rightNumber);
    }
    await _persistPageStore();
    debugPrint("명령 3: 새 페이지를 저장소에 추가했습니다($leftNumber·$rightNumber).");

    if (mounted) {
      setState(() {
        _lastOcrFullText = pageText;
        _lastOcrSummary = _summaryOf(pageText);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            numberConfirmed
                ? "새 페이지 저장 — $leftNumber·${rightNumber}P$warn"
                : "새 페이지 저장 — 번호 미확정(추정 $leftNumber·${rightNumber}P)$warn",
          ),
        ),
      );
    }
  }

  // 슬라이스 3: 맨 위 띠가 모이면 모든 띠를 모으기 전에 상단 지문으로 재독을
  // 미리 판정한다. 재독이면 나머지 띠 OCR을 건너뛰어 비용을 아낀다. 재독이
  // 아니거나 아직 지문이 부족하면 아무것도 하지 않고 평소대로 수집을 잇는다.
  // (조기 검사가 놓쳐도 조립 시점 `_commitSpread`가 다시 거르므로 정확성은 안전.)
  void _checkEarlyReread() {
    if (_pageStore.isEmpty) return;
    final fingerprint = _topPrefixFingerprint();
    if (fingerprint == null || fingerprint.length < _fingerprintLineCount) {
      return;
    }
    _StoredPage? matched;
    double bestSim = 0;
    for (final page in _pageStore) {
      final sim = _fingerprintSimilarity(fingerprint, page.topLines);
      if (sim > bestSim) {
        bestSim = sim;
        matched = page;
      }
    }
    if (matched == null || bestSim < _rereadSimThreshold) return;

    final hit = matched;
    debugPrint(
      "명령 3: 조기 재독 감지 — 기존 ${hit.rightNumber}P, 띠 수집 중단"
      "(유사도 ${bestSim.toStringAsFixed(2)}).",
    );
    _lastCommittedRight = hit.rightNumber;
    _resetBandCollection();
    _awaitingMotionBeforeNextCapture = true;
    _stableSince = null;
    if (mounted) {
      AppStateScope.of(
        context,
      ).updateBookCurrentPage(widget.bookId, hit.rightNumber);
      setState(() {
        _lastOcrFullText = hit.text;
        _lastOcrSummary = _summaryOf(hit.text);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("이미 읽은 페이지 — ${hit.rightNumber}P, 조기 감지로 건너뜀"),
        ),
      );
    }
  }

  // 슬라이스 3: 지금까지 모인 띠 중 맨 위(band 0)부터 끊김 없이 이어진 구간의
  // 좌/우 줄로 상단 지문을 만든다. band 0이 아직 안 모였으면 null.
  List<String>? _topPrefixFingerprint() {
    if (_bandSegments.isEmpty) return null;
    final sorted = List<_BandSegment>.from(_bandSegments)
      ..sort((a, b) => a.bandStart.compareTo(b.bandStart));
    if (sorted.first.bandStart != 0) return null; // 맨 위 띠 미수집
    final prefixLeft = <_VisionLine>[];
    final prefixRight = <_VisionLine>[];
    int nextBand = 0;
    for (final seg in sorted) {
      if (seg.bandStart > nextBand) break; // 끊김 — 여기까지가 연속 구간
      prefixLeft.addAll(seg.leftLines);
      prefixRight.addAll(seg.rightLines);
      nextBand = seg.bandEnd + 1;
    }
    return _buildFingerprintLines(prefixLeft, prefixRight);
  }

  // 슬라이스 1: 펼침면 좌/우 상단 줄을 모아 페이지 식별 지문을 만든다.
  List<String> _buildFingerprintLines(
    List<_VisionLine> leftLines,
    List<_VisionLine> rightLines,
  ) {
    List<String> topOf(List<_VisionLine> lines) => lines
        .map((l) => l.text.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((t) => t.isNotEmpty)
        .take(_fingerprintLineCount)
        .toList();
    return [...topOf(leftLines), ...topOf(rightLines)];
  }

  // 슬라이스 1: 러닝 헤더(반복 인쇄되는 책/장 제목)를 뺀 지문끼리 유사도를 잰다.
  double _fingerprintSimilarity(List<String> a, List<String> b) {
    String body(List<String> lines) =>
        lines.where((l) => !_isRunningHeader(l)).join(' ');
    return _calculateSimilarity(body(a), body(b));
  }

  // 슬라이스 1: 한 페이지의 상단 줄들을 러닝 헤더 빈도표에 누적한다.
  void _registerTopLines(List<String> topLines) {
    for (final line in topLines.toSet()) {
      _topLineFrequency[line] = (_topLineFrequency[line] ?? 0) + 1;
    }
  }

  // 슬라이스 1: 여러 페이지 상단에 반복 출현하면 러닝 헤더로 본다(지문 비교에서 제외).
  bool _isRunningHeader(String line) {
    return (_topLineFrequency[line] ?? 0) >= _runningHeaderMinPages;
  }

  // 슬라이스 1(B안 보강): 한 페이지의 하단 줄에서 페이지 번호를 뽑는다.
  // 페이지 번호는 하단 푸터 줄에 있다 — 책마다 '050'처럼 숫자만 있기도 하고
  // '228 Chapter'·'레이아웃 관리 229'처럼 장 제목과 한 줄에 섞이기도 한다.
  // 그래서 ① 본문 문단(어절 많은 긴 줄)과 ② 'N .' 코드 줄번호 줄을 걸러낸 뒤,
  // 남은 짧은 푸터 줄들의 숫자 중 가장 큰 값을 페이지 번호로 본다. 장·절 번호
  // (4-3 등)는 작아서 자연히 밀린다. 기대값에 의존하지 않아 페이지 점프에 강하다.
  int? _extractBottomPageNumber(List<_VisionLine> lines) {
    if (lines.isEmpty) return null;
    final bottom = lines.sublist(
      math.max(0, lines.length - _pageNumberSearchLines),
    );
    final codeLineNumber = RegExp(r'^\d{1,3}\s*\.\s*$'); // 'N .' 코드 줄번호
    final number = RegExp(r'\d{1,4}');
    int? best;
    for (final line in bottom) {
      final text = line.text.trim();
      if (text.isEmpty || codeLineNumber.hasMatch(text)) continue;
      final tokenCount = text
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .length;
      if (tokenCount > _pageNumberMaxTokens) continue; // 본문 문단 줄 제외
      for (final m in number.allMatches(text)) {
        final n = int.parse(m.group(0)!);
        if (best == null || n > best) best = n;
      }
    }
    return best;
  }

  // 슬라이스 1: 페이지 OCR 품질 점수 — 재독 시 더 선명한 사본으로 교체할지 판단.
  int _pageQuality(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), '');
    final hangul = RegExp(r'[가-힣]').allMatches(compact).length;
    final lineCount = text.split('\n').where((l) => l.trim().isNotEmpty).length;
    return compact.length + lineCount * 12 + hangul;
  }

  // 슬라이스 1: 페이지 저장소를 번호순 평문으로 펼친다. 누락 구간엔 마커를 넣는다.
  String _buildFlatTextFromStore() {
    if (_pageStore.isEmpty) return '';
    final sorted = List<_StoredPage>.from(_pageStore)
      ..sort((a, b) => a.leftNumber.compareTo(b.leftNumber));
    final buffer = StringBuffer();
    int? prevRight;
    for (final page in sorted) {
      if (prevRight != null && page.leftNumber > prevRight + 1) {
        buffer.writeln('[${prevRight + 1}~${page.leftNumber - 1}p 누락]');
        buffer.writeln();
      }
      buffer.writeln(page.text);
      buffer.writeln();
      prevRight = page.rightNumber;
    }
    return buffer.toString();
  }

  // 슬라이스 1: 페이지 저장소를 디스크(JSON)에 저장한다.
  Future<void> _persistPageStore() async {
    try {
      final paths = await _getFilePaths();
      final file = File(paths['pages']!);
      await file.writeAsString(
        jsonEncode([for (final page in _pageStore) page.toJson()]),
      );
    } catch (e) {
      debugPrint("슬라이스 1: 페이지 저장소 저장 오류: $e");
    }
  }

  // 슬라이스 1: 디스크에 저장된 페이지 저장소를 불러온다(앱 재진입 시 이어쓰기·재독 감지).
  Future<void> _loadPageStore() async {
    try {
      final paths = await _getFilePaths();
      final file = File(paths['pages']!);
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _pageStore.clear();
      _topLineFrequency.clear();
      for (final entry in decoded) {
        if (entry is Map<String, dynamic>) {
          final page = _StoredPage.fromJson(entry);
          _pageStore.add(page);
          _registerTopLines(page.topLines);
        }
      }
      if (_pageStore.isNotEmpty) {
        _lastCommittedRight = _pageStore
            .map((page) => page.rightNumber)
            .reduce((a, b) => a > b ? a : b);
      }
      debugPrint("슬라이스 1: 페이지 저장소 ${_pageStore.length}장을 불러왔습니다.");
    } catch (e) {
      debugPrint("슬라이스 1: 페이지 저장소 불러오기 오류: $e");
    }
  }

  // 임의 텍스트의 디버그 패널 요약(글자수·줄수·미리보기).
  String _summaryOf(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final lineCount = text.split('\n').where((l) => l.trim().isNotEmpty).length;
    final preview = normalized.length > 70
        ? '${normalized.substring(0, 70)}…'
        : normalized;
    return '${normalized.length}자 · $lineCount줄\n$preview';
  }

  // 디버그: 마지막 OCR/조립 전체 텍스트를 스크롤 다이얼로그로 보여준다.
  void _showFullOcrDialog() {
    final text = _lastOcrFullText;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('OCR 결과 전체'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              (text == null || text.trim().isEmpty)
                  ? '아직 OCR 결과가 없습니다.'
                  : text,
              style: const TextStyle(fontSize: 13, height: 1.45),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  // 검출이 끊겨 추적으로 유지 중인 마지막 손 위치(디버그 오버레이용).
  HandBox? get _trackedHandBox {
    if (!_handLatched) return null;
    final liveBoxes = _handResult?.boxes ?? const <HandBox>[];
    return liveBoxes.isEmpty ? _lastHandBox : null;
  }

  // 촬영 상태를 갱신한다(값이 바뀔 때만 setState).
  void _setCaptureStatus(_CaptureStatus status) {
    if (_captureStatus == status || !mounted) return;
    setState(() => _captureStatus = status);
  }

  // 디버그 패널에 보여줄 현재 촬영 상태 라벨.
  String get _captureStatusLabel {
    switch (_captureStatus) {
      case _CaptureStatus.idle:
        return '대기 중';
      case _CaptureStatus.motion:
        return '움직임 감지중';
      case _CaptureStatus.checkingHand:
        return '안정 · 손 검사중';
      case _CaptureStatus.handOverlap:
        return '손 겹침 · 대기';
      case _CaptureStatus.capturing:
        return '깨끗 · OCR중';
    }
  }

  List<int> _buildFrameSignature(CameraImage image) {
    if (image.planes.isEmpty) return const [];
    final bytes = image.planes.first.bytes;
    if (bytes.isEmpty) return const [];

    final step = math.max(1, bytes.length ~/ _lumaSampleCount);
    final signature = <int>[];
    for (
      int i = 0;
      i < bytes.length && signature.length < _lumaSampleCount;
      i += step
    ) {
      signature.add(bytes[i]);
    }
    return signature;
  }

  double _calculateFrameDiff(List<int> previous, List<int> current) {
    final length = math.min(previous.length, current.length);
    if (length == 0) return 0.0;

    int totalDiff = 0;
    for (int i = 0; i < length; i++) {
      totalDiff += (previous[i] - current[i]).abs();
    }
    return totalDiff / length;
  }

  // --- 데이터 통합 업데이트 로직 (핵심) ---
  Future<void> _performAnalysis() async {
    if (_isCaptureBusy || _isProcessingAnalysis) return;
    if (_isAutoMode) {
      _stopAutoCapture();
      return;
    }
    setState(() => _isProcessingAnalysis = true);
    final appState = AppStateScope.of(context);

    try {
      final paths = await _getFilePaths();
      final pagesFile = File(paths['pages']!);
      final storyDbFile = File(paths['story_db']!);
      final charDbFile = File(paths['char_db']!);

      // 페이지 저장소를 번호순 평문으로 펼친다(누락 구간엔 마커 삽입).
      final String newRawText = _buildFlatTextFromStore();
      if (newRawText.trim().isEmpty) {
        throw Exception("스캔된 새로운 텍스트가 없습니다.");
      }
      final String oldStoryDb = await storyDbFile.exists()
          ? await storyDbFile.readAsString()
          : "{}";
      final String oldCharDb = await charDbFile.exists()
          ? await charDbFile.readAsString()
          : "{}";

      // 1. Gemini 통합 분석 요청 (4가지 데이터 추출)
      final responseJson = await _getGeminiIntegratedUpdate(
        newRawText,
        oldStoryDb,
        oldCharDb,
      );
      final Map<String, dynamic> result = jsonDecode(responseJson);

      // 2. 앱 UI 데이터 업데이트
      // UI용 요약문
      appState.updateBookSummary(widget.bookId, result['ui_summary'] ?? "");

      // UI용 캐릭터 목록
      if (result['ui_characters'] != null) {
        final rawCharacters = result['ui_characters'];
        if (rawCharacters is List) {
          appState.updateBookCharacters(widget.bookId, rawCharacters);
        }
      }

      // UI용 인물 관계
      if (result['ui_relationships'] != null) {
        final rawRelationships = result['ui_relationships'];
        if (rawRelationships is List) {
          appState.updateBookRelationships(widget.bookId, rawRelationships);
        }
      }

      final bookAfterGemini = appState.findBookById(widget.bookId);
      if (bookAfterGemini != null && _claudeService.isConfigured) {
        final claudeResult = await _claudeService
            .analyzeCharactersAndRelationships(
              book: bookAfterGemini,
              newText: newRawText,
              existingCharacterDb: oldCharDb,
            );

        if (claudeResult != null) {
          if (claudeResult.characters.isNotEmpty) {
            appState.updateBookCharacters(
              widget.bookId,
              claudeResult.charactersAsJson(),
            );
          }
          if (claudeResult.relationships.isNotEmpty) {
            appState.updateBookRelationships(
              widget.bookId,
              claudeResult.relationshipsAsJson(),
            );
          }
        }
      }

      // 3. 내부 고밀도 JSON DB 저장 (다음 분석을 위한 데이터 상속)
      await storyDbFile.writeAsString(jsonEncode(result['internal_story_db']));
      await charDbFile.writeAsString(
        jsonEncode(result['internal_character_db']),
      );

      // 4. ✅ 페이지 저장소 삭제 (토큰 비용 절감 및 최적화)
      if (await pagesFile.exists()) await pagesFile.delete();
      _pageStore.clear();
      _topLineFrequency.clear();
      _lastCommittedRight = null;
      debugPrint("🗑️ 분석 완료 후 페이지 저장소를 삭제하였습니다.");

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✅ 데이터 통합 업데이트가 완료되었습니다."),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => BookDetailScreen(bookId: widget.bookId),
          ),
        );
      }
    } catch (e) {
      debugPrint("❌ 업데이트 실패: $e");
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("업데이트 실패: $e")));
      }
    } finally {
      if (mounted) setState(() => _isProcessingAnalysis = false);
    }
  }

  Future<String> _getGeminiIntegratedUpdate(
    String newText,
    String oldStory,
    String oldChar,
  ) async {
    final prompt =
        """
당신은 독서 보조 시스템의 분석 엔진입니다. 
제공된 기존 데이터와 새로 스캔된 텍스트를 통합하여 반드시 다음 구조의 JSON으로 응답하세요.

[기존 스토리 데이터]
$oldStory

[기존 인물 데이터]
$oldChar

[새로 스캔된 텍스트]
$newText

지침:
1. internal_story_db: AI인 당신이 다음에 분석할 때 참고할 매우 상세한 줄거리 데이터입니다. 주요 복선, 시간순 사건을 JSON으로 구성하세요.
2. internal_character_db: 인물 간의 관계, 성격 변화, 현재 위치 등을 정밀하게 추적하는 JSON 데이터입니다.
3. ui_summary: 사용자가 앱 화면에서 바로 읽을 수 있도록 자연스러운 10줄 내외의 줄거리 요약입니다. (평문)
4. ui_characters: 앱의 인물 탭에 리스트로 보여줄 누적 인물 요약 데이터입니다. 형식: [{"name": "이름", "role": "역할", "description": "설명"}]
   - description은 사용자가 인물 탭에서 바로 이해할 수 있는 한국어 2~3문장으로 작성하세요.
   - 각 인물의 역할, 현재 상황, 성격/태도 변화, 다른 인물과의 관계를 스캔된 텍스트 근거 안에서만 요약하세요.
   - 기존 인물 데이터가 있으면 새 텍스트와 합쳐 누적 업데이트하세요. 새 텍스트에 나오지 않았다는 이유만으로 기존 사실을 지우지 마세요.
   - 확실하지 않은 추측, 앞으로의 전개 예측, 텍스트에 없는 배경 설정은 쓰지 마세요.
   - 잠깐 언급된 인물은 억지로 길게 쓰지 말고 확인된 사실만 짧게 쓰세요.
5. ui_relationships: 앱의 관계 탭에 표시할 인물 관계 데이터입니다. 형식: [{"source": "인물 이름", "target": "인물 이름", "label": "짧은 관계명", "description": "관계 설명", "evidence": "근거", "strength": 1, "type": "관계 유형"}]
   - source와 target은 반드시 ui_characters에 포함된 실제 인물 이름을 그대로 쓰세요.
   - label은 "친구", "가족", "협력", "대립", "스승과 제자"처럼 화면에 올릴 짧은 표현으로 쓰세요.
   - description은 두 인물 사이의 현재 관계를 1~2문장으로 설명하세요.
   - evidence는 스캔 텍스트에서 확인되는 근거를 짧게 요약하세요. 직접 인용이 불확실하면 요약으로 쓰세요.
   - strength는 관계가 얼마나 뚜렷한지 1~5 정수로 쓰세요. 잠깐 언급된 약한 관계는 1, 반복되고 서사적으로 중요한 관계는 5입니다.
   - type은 ally, family, conflict, romance, mentor, mystery, neutral 중 가장 가까운 값을 쓰세요.
   - 관계가 확실하지 않거나 한쪽 인물이 불명확하면 넣지 마세요.
6. ui_characters에는 실제 등장인물만 넣으세요. 다음은 넣지 마세요:
   - 군중, 주민들, 학생들, 사람들 같은 집단 표현
   - 화자, 서술자, 주인공, 누군가, 친구 같은 일반 명사
   - 직책이나 관계만 있고 고유하게 식별되지 않는 표현
   - 장소, 단체, 개념, 사물
7. 이름이 분명하지 않으면 억지로 넣지 말고 제외하세요.
8. 한 번만 스쳐 지나가는 일반 호칭보다, 이야기에서 실제 인물로 추적 가능한 대상만 남기세요.

응답은 반드시 마크다운 기호 없이 순수한 JSON 객체 하나만 출력하세요.
""";

    final response = await http.post(
      Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$_geminiApiKey',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        "contents": [
          {
            "parts": [
              {"text": prompt},
            ],
          },
        ],
        "generationConfig": {
          "temperature": 0.7,
          "response_mime_type": "application/json",
        },
      }),
    );

    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body);
      return decoded['candidates']?[0]?['content']?['parts']?[0]?['text'] ??
          "{}";
    }
    throw Exception(
      "Gemini API 호출 실패 (상태 코드: ${response.statusCode}) ${response.body}",
    );
  }

  double _calculateSimilarity(String s1, String s2) {
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    final set1 = s1.split(RegExp(r'\s+')).toSet();
    final set2 = s2.split(RegExp(r'\s+')).toSet();
    final intersection = set1.intersection(set2);
    return (2.0 * intersection.length) / (set1.length + set2.length);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCameraInitialized || _controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final book = AppStateScope.of(context).findBookById(widget.bookId);
    final currentPage = book?.currentPage ?? 0;

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF7),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 20, 16, 4),
              child: Row(
                children: [
                  Transform.translate(
                    offset: const Offset(0, 30),
                    child: IconButton(
                      icon: const Icon(
                        Icons.arrow_back_ios,
                        size: 22,
                        color: Colors.black87,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          widget.bookTitle,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          "현재 인식된 페이지: $currentPage P",
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: Colors.orange,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: "디버그 패널",
                    icon: Icon(
                      _debugPanelEnabled
                          ? Icons.bug_report
                          : Icons.bug_report_outlined,
                      size: 22,
                      color: _debugPanelEnabled
                          ? const Color(0xFFB5651D)
                          : Colors.black54,
                    ),
                    onPressed: () => setState(
                      () => _debugPanelEnabled = !_debugPanelEnabled,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ScanCameraView(
                controller: _controller!,
                currentZoomLevel: _currentZoomLevel,
                onZoomChanged: _updateZoom,
                isCapturing: _isAutoMode,
                isProcessing: _isProcessingAnalysis,
                onAnalyzePressed: _performAnalysis,
                onCapturePressed: _startAutoCapture,
                onStopPressed: _stopAutoCapture,
                debugEnabled: _debugPanelEnabled,
                handResult: _handResult,
                captureStatusLabel: _captureStatusLabel,
                ocrSummary: _lastOcrSummary,
                handLatched: _handLatched,
                trackedHandBox: _trackedHandBox,
                bottomRegionTop: _bottomRegionTop,
                handCoversText: _handLatched && _handCoversText(),
                onBottomRegionChanged: _updateBottomRegionTop,
                spineX: _spineX,
                spineManualOverride: _spineManualOverride,
                onSpineChanged: _updateSpineX,
                onSpineAutoReset: _resetSpineAuto,
                bandCount: _bandCount,
                bandCoverage: _bandCoverage(),
                bandCollected: List<bool>.unmodifiable(_bandCollected),
                onShowFullOcr: _showFullOcrDialog,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 명령 3: Vision OCR로 인식된 한 줄 — 텍스트 + 정규화 세로중심(0~1).
class _VisionLine {
  const _VisionLine(this.text, this.centerY);

  final String text;
  final double centerY;
}

/// 명령 3: Vision OCR 단어 하나 — 텍스트 + 경계상자(픽셀 좌표).
class _OcrWord {
  const _OcrWord(this.text, this.minX, this.maxX, this.minY, this.maxY);

  final String text;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;
}

/// 명령 3: 한 번의 띠 캡처에서 얻은 텍스트 세그먼트(겹침 스티칭 단위).
/// 좌우 2페이지를 따로 OCR하므로 왼쪽/오른쪽 줄을 분리해 담는다.
/// 줄은 _VisionLine(텍스트 + centerY) — centerY는 스티칭 품질 투표에 쓰인다.
class _BandSegment {
  _BandSegment(this.bandStart, this.bandEnd, this.leftLines, this.rightLines);

  final int bandStart; // 이 캡처가 덮은 첫 띠 인덱스
  final int bandEnd; // 마지막 띠 인덱스(포함)
  final List<_VisionLine> leftLines; // 왼쪽 페이지 OCR 줄(읽기 순서)
  final List<_VisionLine> rightLines; // 오른쪽 페이지 OCR 줄(읽기 순서)
}

/// 슬라이스 1: 페이지 저장소에 보관하는 펼침면 한 장.
/// leftNumber/rightNumber는 좌/우 페이지 번호(확정 또는 추정), topLines는 재독
/// 판정용 상단 지문(러닝 헤더 제거는 비교 시점에 동적으로 한다).
class _StoredPage {
  _StoredPage({
    required this.leftNumber,
    required this.rightNumber,
    required this.numberConfirmed,
    required this.text,
    required this.topLines,
    required this.quality,
  });

  final int leftNumber;
  final int rightNumber;
  final bool numberConfirmed; // 페이지 번호를 OCR로 확정했는지(false=직전+N 추정)
  String text; // 재독 시 더 선명한 사본으로 교체될 수 있음
  final List<String> topLines; // 좌/우 상단 줄(정규화) — 재독 지문
  int quality; // OCR 품질 점수 — 재독 교체 판단

  Map<String, dynamic> toJson() => {
    'leftNumber': leftNumber,
    'rightNumber': rightNumber,
    'numberConfirmed': numberConfirmed,
    'text': text,
    'topLines': topLines,
    'quality': quality,
  };

  static _StoredPage fromJson(Map<String, dynamic> json) => _StoredPage(
    leftNumber: (json['leftNumber'] as num?)?.toInt() ?? 0,
    rightNumber: (json['rightNumber'] as num?)?.toInt() ?? 0,
    numberConfirmed: json['numberConfirmed'] as bool? ?? false,
    text: json['text'] as String? ?? '',
    topLines: ((json['topLines'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    quality: (json['quality'] as num?)?.toInt() ?? 0,
  );
}

/// 명령 3 스티칭: 겹침 앵커 위치 — 앞 누적의 tailIndex, 다음 세그먼트의 headIndex.
class _StitchAnchor {
  const _StitchAnchor(this.tailIndex, this.headIndex);

  final int tailIndex;
  final int headIndex;
}

/// 자동 촬영 진행 상태(디버그 패널 표시 및 손 게이트용).
enum _CaptureStatus {
  idle, // 대기 중 (촬영 시작 전)
  motion, // 움직임 감지중 / 안정화 대기
  checkingHand, // 안정됨, 손 감지 결과 확인 중
  handOverlap, // 손이 본문과 겹침 → 대기
  capturing, // 깨끗한 프레임 → 촬영·OCR 진행 중
}
