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
import '../models/book.dart';
import '../services/book_box_detection_service.dart';
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
  static const Duration _handDetectionThrottle = Duration(milliseconds: 200);
  // 촬영 직전 손 게이트가 신뢰할 손 감지 결과의 최대 허용 나이.
  static const Duration _handResultMaxAge = Duration(milliseconds: 1600);
  // 손 래치(추적 유지) 파라미터.
  // 손이 작아지며 빠져나가던 중이면 짧은 유예 후 해제.
  static const Duration _handExitGrace = Duration(milliseconds: 500);
  // 큰 손이 갑자기 사라지면(화면 밖으로만 나감) 더 오래 유지.
  static const Duration _handLatchTimeout = Duration(milliseconds: 2600);
  // 마지막 손 크기가 최대 크기 대비 이 비율 이하면 '빠져나가던 중'으로 본다.
  static const double _handExitShrinkRatio = 0.5;
  // ② 모서리 손 무시: 책 박스를 이 비율만큼 안으로 들인 영역을 '본문'으로 본다.
  static const double _textRegionInset = 0.10;
  // 손 박스 중 본문 영역과 겹치는 비율이 이 값 이상이면 '본문 가림'으로 본다.
  static const double _handOverlapThreshold = 0.15;
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
  // 명령 3: 좌우 2페이지를 가르는 책등(중심선) 가로 위치(정규화 0~1)의 기본값.
  static const double _spineXDefault = 0.5;
  // 슬라이스 1: 페이지 저장소(재독·누락 감지) 파라미터.
  static const int _fingerprintLineCount = 3; // 좌/우 각 상단에서 지문에 쓸 줄 수
  static const double _rereadSimThreshold = 0.6; // 재독으로 볼 지문 유사도(0~1)
  static const int _runningHeaderMinPages = 3; // 러닝 헤더로 볼 최소 출현 페이지 수
  static const int _pageNumberSearchLines = 6; // 하단 페이지번호를 찾을 줄 수
  static const int _pageNumberMaxTokens = 6; // 페이지번호 줄로 볼 최대 어절 수
  // 페이지 확인용 상단 탐침 띠 높이(정규화) — 본문 전체 OCR 전 재독 판정에 쓴다.
  static const double _probeStripHeight = 0.32;

  final String _googleVisionApiKey = dotenv.env['_googleVisionApiKey'] ?? "";
  final String _geminiApiKey = dotenv.env['_geminiApiKey'] ?? "";
  final ClaudeService _claudeService = ClaudeService();
  final HandDetectionService _handDetectionService = HandDetectionService();
  final BookBoxDetectionService _bookBoxService = BookBoxDetectionService();

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
  // 핀치 줌 제스처 시작 시점의 배율 — 제스처 도중 이 값에 손가락 간격 배율을 곱한다.
  double _zoomGestureBaseLevel = 1.0;

  bool _debugPanelEnabled = false;
  bool _handDetectionBusy = false;
  DateTime? _lastHandDetectionAt;
  HandDetectionResult? _handResult;
  DateTime? _handResultAt;

  // 책 테두리 박스 — 촬영 시작 시 사진 1장으로 1회 검출(프리뷰 정규화 좌표).
  Rect? _bookBox;

  _CaptureStatus _captureStatus = _CaptureStatus.idle;

  // 손 래치: 한 번 검출된 손은 검출이 끊겨도 일정 조건까지 '있음'으로 유지한다.
  bool _handLatched = false;
  HandBox? _lastHandBox;
  DateTime? _lastHandSeenAt;
  double _lastHandArea = 0;
  double _peakHandArea = 0;

  // 명령 3: 책등 가로 위치(좌우 페이지 분리선). 캡처 시 자동 감지로 갱신된다.
  double _spineX = _spineXDefault;

  // 디버그: 페이지 갱신 표시 문구(예: "페이지 업데이트됨 (15P, 16P)").
  // 표시 1초 뒤 _pageUpdateTimer가 자동으로 지운다.
  String? _pageUpdateInfo;
  Timer? _pageUpdateTimer;

  // 상단 표시용 — 방금 인식된 페이지(말 그대로 '현재' 페이지, 최댓값 아님).
  int _currentRecognizedPage = 0;

  // 슬라이스 2: 8칸(4행×2열) 셀별 수집 상태. 인덱스 = 행*2 + 열(0=좌, 1=우).
  // null이면 미수집, 비-null이면 그 칸의 OCR 줄(빈 리스트일 수 있음).
  final List<List<_VisionLine>?> _cellLines = List<List<_VisionLine>?>.filled(
    _bandCount * 2,
    null,
  );
  // 슬라이스 2 (지연 OCR): 좌상단을 제외한 칸은 캡처 시점에 OCR하지 않고
  // 이미지(JPEG 바이트)만 보관한다. 8칸이 다 모이면 한 번에 배치(Future.wait)로
  // OCR해 _cellLines를 채운다. null이면 아직 이미지도 미수집.
  final List<Uint8List?> _pendingCellImages = List<Uint8List?>.filled(
    _bandCount * 2,
    null,
  );
  // 슬라이스 2: 지금 띠 수집 중인 페이지의 상단 지문(페이지 ID). 수집 도중
  // 이 지문이 크게 달라지면 페이지가 넘어간 것으로 보고 띠 버퍼를 리셋한다.
  List<String>? _bandPageFingerprint;
  // 디버그 'OCR 결과 전체보기'용 — 마지막 OCR/조립 전체 텍스트.
  String? _lastOcrFullText;

  // 슬라이스 1: 명령 3로 조립된 펼침면을 페이지 번호 키로 보관하는 저장소.
  // 재독(이미 읽은 페이지) 감지·중복 방지·누락 페이지 기록의 source of truth.
  final List<_StoredPage> _pageStore = [];
  // 러닝 헤더 감지용: 페이지 상단에 반복 인쇄되는 줄의 출현 페이지 수.
  final Map<String, int> _topLineFrequency = {};
  // 페이지 번호 앵커 — 지금까지 확정된 오른쪽 페이지 번호의 최댓값(읽기 진행 위치).
  // 다음 펼침면의 기대값(anchor+1·anchor+2) 계산에 쓴다. 뒤로 돌아간 곁다리는
  // _advanceAnchor의 max 갱신으로 앵커를 끌어내리지 않는다.
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
    _pageUpdateTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  // 디버그: 페이지 갱신 문구를 띄우고 1초 뒤 자동으로 지운다.
  void _flashPageUpdate(String text) {
    _pageUpdateTimer?.cancel();
    if (mounted) setState(() => _pageUpdateInfo = text);
    _pageUpdateTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _pageUpdateInfo = null);
    });
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

      // 카메라 프리뷰/촬영 방향을 가로로 고정한다.
      // SystemChrome.setPreferredOrientations만으로는 UI만 가로로 돌고
      // 카메라는 기기 센서 방향을 따라가, 폰을 세로로 들면 프리뷰가 틀어진다.
      // lockCaptureOrientation은 물리적 기기 방향과 무관하게 가로로 잠근다.
      try {
        await _controller!.lockCaptureOrientation(
          DeviceOrientation.landscapeLeft,
        );
      } catch (e) {
        debugPrint("카메라 방향 고정 실패: $e");
      }

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

  // 핀치 줌 시작 — 현재 배율을 기준값으로 잡는다.
  void _onZoomGestureStart() {
    _zoomGestureBaseLevel = _currentZoomLevel;
  }

  // 핀치 줌 진행 — 기준 배율에 두 손가락 간격 배율을 곱해 적용한다.
  void _onZoomGestureUpdate(double scale) {
    _updateZoom(_zoomGestureBaseLevel * scale);
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
      ), // 슬라이스 1: 작업용 페이지 저장소(분석 후 삭제됨)
      'pagetext': p.join(
        bookDir.path,
        '${widget.bookId}_pagetext.json',
      ), // 페이지 인용 Q&A용 영구 페이지 본문 저장소
      'relmap': p.join(
        bookDir.path,
        '${widget.bookId}_relmap.svg',
      ), // 관계도 SVG (Claude 생성, 분석 시 갱신)
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
      _bookBox = null;
      _captureStatus = _CaptureStatus.motion;
      _lastOcrFullText = null;
      _handLatched = false;
      _lastHandBox = null;
      _lastHandSeenAt = null;
      _lastHandArea = 0;
      _peakHandArea = 0;
      _resetBandCollection();
    });

    // 촬영 시작 시 사진 한 장으로 책 테두리 박스를 1회 검출한다.
    await _detectBookBoxOnce();

    await _ensureImageStreamRunning();
  }

  // 촬영 시작 시 사진 한 장으로 책 테두리 박스를 1회 검출해 세션 내내 고정한다.
  Future<void> _detectBookBoxOnce() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      final photo = await _controller!.takePicture();
      final box = _bookBoxService.detect(photo.path);
      if (!mounted) return;
      setState(() => _bookBox = box);
      if (box == null) {
        debugPrint("책 테두리를 찾지 못했습니다.");
      } else {
        debugPrint("책 테두리 박스 검출 완료: $box");
      }
    } catch (e) {
      debugPrint("책 박스 검출 오류: $e");
    }
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
      debugPrint("전체 페이지 촬영 시작 — 손 게이트 '깨끗' 판정.");
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
        final detected = _detectSpineX(oriented, _captureBox);
        if (mounted) setState(() => _spineX = detected);
        // 슬라이스 1: 크롭을 책 박스 기준으로.
        final box = _captureBox;
        final spine = _spineX.clamp(box.left, box.right);
        final stripBottom = box.top + _probeStripHeight * box.height;
        // 페이지 확인 우선: 상단 좁은 띠만 먼저 OCR해 재독인지 본다.
        // 재독이면 본문 전체 OCR을 건너뛴다.
        // 좌·우 상단 탐침을 동시에(병렬) OCR한다.
        final probeResults = await Future.wait([
          _ocrLines(
            _cropEncode(oriented, box.top, stripBottom, box.left, spine),
          ),
          _ocrLines(
            _cropEncode(oriented, box.top, stripBottom, spine, box.right),
          ),
        ]);
        final probeLeft = probeResults[0];
        final probeRight = probeResults[1];
        final probeFingerprint = _buildFingerprintLines(probeLeft, probeRight);
        final reread = _matchStoredPage(probeFingerprint);
        debugPrint(
          "페이지 확인: 상단 탐침 지문=$probeFingerprint → "
          "${reread != null ? '재독(${reread.rightNumber}P)' : '새 페이지 후보'}.",
        );
        if (reread != null) {
          _handleProbeReread(reread);
          _resetBandCollection();
          if (mounted && _isAutoMode) {
            _lastCaptureAt = DateTime.now();
            _awaitingMotionBeforeNextCapture = true;
            _stableSince = null;
          }
          if (wasStreaming && _isAutoMode) {
            await _ensureImageStreamRunning();
          }
          return;
        }
        // 새 페이지 — 책 박스 전체를 OCR한다.
        _setCaptureStatus(_CaptureStatus.capturing);
        final leftCrop = _cropEncode(
          oriented, box.top, box.bottom, box.left, spine);
        final rightCrop = _cropEncode(
          oriented, box.top, box.bottom, spine, box.right);
        // 좌·우 페이지 본문을 동시에(병렬) OCR한다.
        final fullResults = await Future.wait([
          _ocrLines(leftCrop),
          _ocrLines(rightCrop),
        ]);
        leftLines = fullResults[0];
        rightLines = fullResults[1];
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
      _bookBox = null;
      _captureStatus = _CaptureStatus.idle;
      _handLatched = false;
      _lastHandBox = null;
      _lastHandSeenAt = null;
      _lastHandArea = 0;
      _peakHandArea = 0;
      _resetBandCollection();
    });
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

    // 움직임이 멈춘 뒤 안정 시간(1.2초)만 충족하면 진행한다.
    // 고정 쿨다운은 게이트에서 빼고, 띠 수집 경로에서만 따로 적용한다(아래).
    // 전체 OCR 경로는 직전 캡처 이후 움직임이 한 번 감지돼야 하므로
    // (_awaitingMotionBeforeNextCapture) 중복 캡처 위험 없이 쿨다운을 없앨 수 있다.
    final stableDuration = now.difference(_stableSince!);
    if (stableDuration < _stabilityRequiredDuration) {
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

    // ③ 2~3단계: 책 박스 맨 위 띠에 손이 있으면, 손이 내려갈 때까지 기다린다.
    // 맨 위 띠가 페이지 식별(재독 판정) 기준이므로 먼저 깨끗해야 한다.
    if (_handLatched && _topBandHasHand()) {
      _setCaptureStatus(_CaptureStatus.handOverlap);
      return;
    }

    debugPrint(
      "촬영 라우팅 — handLatched=$_handLatched, "
      "coversText=${_handCoversText()}, 게이트박스 ${_effectiveHandBoxes().length}개, "
      "최신감지 detected=${hand.detected} boxes=${hand.boxes.length}.",
    );
    if (_handLatched && _handCoversText()) {
      // 손이 본문을 가림 → 명령 3: 손이 안 가린 깨끗한 띠만 골라 수집한다.
      // 띠 수집은 현행 페이싱 유지 — 직전 캡처로부터 쿨다운(2초)을 적용한다.
      if (_lastCaptureAt != null &&
          now.difference(_lastCaptureAt!) < _captureCooldownDuration) {
        _setCaptureStatus(_CaptureStatus.motion);
        return;
      }
      await _collectCleanBands();
      return;
    }
    // 손이 검출/추적되더라도 하단 여백 영역 안에만 있으면 본문은 안 가린 것으로 본다.

    // 손이 본문과 안 겹침 → 깨끗한 프레임. 명령 2: 페이지 전체를 한 장으로 촬영.
    // 빠른 경로 — 쿨다운 없이 움직임이 멈춘 즉시 전체 OCR로 잡는다.
    _setCaptureStatus(_CaptureStatus.pageChecking);
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

  // 손이 책 본문 영역을 가리는지 판정한다. 가장자리(여백·모서리)만 잡은 손은 무시.
  bool _handCoversText() {
    final boxes = _effectiveHandBoxes();
    if (boxes.isEmpty) return true; // 위치 정보 없음 → 보수적으로 가림 간주

    // ② 손이 본문 영역과 충분히 겹칠 때만 '가림'으로 본다.
    // 책 모서리·여백만 잡은 손은 본문 영역과 겹침이 작아 무시된다.
    final textRegion = _innerTextRegion();
    for (final box in boxes) {
      final handRect = Rect.fromLTRB(box.left, box.top, box.right, box.bottom);
      final handArea = handRect.width * handRect.height;
      if (handArea <= 0) continue;
      final inter = handRect.intersect(textRegion);
      if (inter.width <= 0 || inter.height <= 0) continue;
      final overlapRatio = (inter.width * inter.height) / handArea;
      if (overlapRatio >= _handOverlapThreshold) return true;
    }
    return false;
  }

  // ② '본문 영역' — 책 박스(미검출이면 프레임 전체)를 가장자리 _textRegionInset
  // 만큼 안으로 들인 사각형. 이 바깥(상·하·좌·우 여백 + 모서리)의 손은 무시된다.
  Rect _innerTextRegion() {
    final box = _bookBox ?? const Rect.fromLTRB(0, 0, 1, 1);
    final marginX = box.width * _textRegionInset;
    final marginY = box.height * _textRegionInset;
    return Rect.fromLTRB(
      box.left + marginX,
      box.top + marginY,
      box.right - marginX,
      box.bottom - marginY,
    );
  }

  // ③ 책 본문 영역의 '좌상단 셀'(왼쪽 절반 × 상단 1/4)에 손이 들어와 있는지.
  // 이 칸이 페이지 식별 지문 기준이라, 여기만 깨끗하면 된다(오른쪽 손은 무관).
  bool _topBandHasHand() {
    final boxes = _effectiveHandBoxes();
    if (boxes.isEmpty) return false;
    final region = _innerTextRegion();
    final topBand = Rect.fromLTRB(
      region.left,
      region.top,
      region.left + region.width / 2,
      region.top + region.height / 4,
    );
    for (final box in boxes) {
      final handRect = Rect.fromLTRB(box.left, box.top, box.right, box.bottom);
      final handArea = handRect.width * handRect.height;
      if (handArea <= 0) continue;
      final inter = handRect.intersect(topBand);
      if (inter.width <= 0 || inter.height <= 0) continue;
      if ((inter.width * inter.height) / handArea >= _handOverlapThreshold) {
        return true;
      }
    }
    return false;
  }


  // 슬라이스 1: 띠·크롭의 기준 사각형 — 검출된 책 박스(미검출이면 프레임 전체).
  Rect get _captureBox => _bookBox ?? const Rect.fromLTRB(0, 0, 1, 1);

  // 슬라이스 1: 띠 index의 세로 범위(프레임 정규화) — 책 박스 안에서 4등분한다.
  (double, double) _bandBounds(int band) {
    final box = _captureBox;
    return (
      box.top + band / _bandCount * box.height,
      box.top + (band + 1) / _bandCount * box.height,
    );
  }

  // 슬라이스 2: 셀(row, col)의 사각형(프레임 정규화). col 0=좌, 1=우.
  Rect _cellRect(int row, int col) {
    final box = _captureBox;
    final (top, bottom) = _bandBounds(row);
    final midX = (box.left + box.right) / 2;
    return col == 0
        ? Rect.fromLTRB(box.left, top, midX, bottom)
        : Rect.fromLTRB(midX, top, box.right, bottom);
  }

  // 슬라이스 2: 8칸 각각을 손이 가리고 있는지(손 박스가 칸과 겹치면 가림).
  List<bool> _cellCoverage() {
    final covered = List<bool>.filled(_bandCount * 2, false);
    final boxes = _effectiveHandBoxes();
    if (boxes.isEmpty) return covered;
    // 셀을 '본문 영역'(인셋된 책 박스)으로 클리핑해, 가장자리(여백/모서리)
    // 부분과 손이 닿는 건 가려짐으로 보지 않는다. 전체 OCR 게이트(_handCoversText)
    // 와 같은 기준을 셀 단위에 적용 — 가장자리 손이 띠 수집을 막던 회귀를 해소.
    final inner = _innerTextRegion();
    for (int row = 0; row < _bandCount; row++) {
      for (int col = 0; col < 2; col++) {
        final cell = _cellRect(row, col);
        final cellInner = cell.intersect(inner);
        if (cellInner.width <= 0 || cellInner.height <= 0) {
          // 셀이 통째로 인셋 바깥(본문 없음) — 가려질 일도 없음.
          continue;
        }
        for (final box in boxes) {
          if (box.right > cellInner.left &&
              box.left < cellInner.right &&
              box.bottom > cellInner.top &&
              box.top < cellInner.bottom) {
            covered[row * 2 + col] = true;
            break;
          }
        }
      }
    }
    return covered;
  }

  // 디버그 오버레이용 8칸 수집 상태(OCR 결과든 보류 이미지든 데이터가 있으면 수집됨).
  List<bool> _cellCollectedView() {
    return [
      for (int i = 0; i < _cellLines.length; i++)
        _cellLines[i] != null || _pendingCellImages[i] != null,
    ];
  }

  // 명령 3: 셀 수집 상태를 초기화한다(새 페이지 시작/완성/전체촬영 시).
  void _resetBandCollection() {
    for (int i = 0; i < _cellLines.length; i++) {
      _cellLines[i] = null;
      _pendingCellImages[i] = null;
    }
    _bandPageFingerprint = null;
  }

  // 명령 3 + 슬라이스 2 (지연 OCR): 손이 본문을 가린 동안 한 장 찍어,
  // ① 좌상단을 매번 OCR해 페이지 ID를 검증(재독 / 페이지 넘김 감지),
  // ② 나머지 깨끗한 칸은 이미지로만 보관하고,
  // ③ 8칸이 다 모이면 보관된 이미지들을 한꺼번에(병렬) OCR해 페이지 조립한다.
  Future<void> _collectCleanBands() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isCaptureBusy ||
        _isProcessingAnalysis) {
      return;
    }

    // 미수집이면서 지금 손에 안 가린 칸이 하나도 없으면 대기한다.
    final coverage = _cellCoverage();
    bool anyHarvestable = false;
    for (int i = 0; i < _cellLines.length; i++) {
      final hasData = _cellLines[i] != null || _pendingCellImages[i] != null;
      if (!hasData && !coverage[i]) {
        anyHarvestable = true;
        break;
      }
    }
    if (!anyHarvestable) {
      _setCaptureStatus(_CaptureStatus.handOverlap);
      return;
    }
    // 좌상단(셀 0)이 깨끗하면 페이지 ID를 다루는 단계라 '페이지 검사중' 표시.
    _setCaptureStatus(
      !coverage[0] ? _CaptureStatus.pageChecking : _CaptureStatus.capturing,
    );

    setState(() => _isCaptureBusy = true);
    try {
      final wasStreaming = _isImageStreamActive;
      if (wasStreaming) {
        await _stopImageStream();
      }

      final photo = await _controller!.takePicture();
      final bytes = await File(photo.path).readAsBytes();
      final oriented = _decodeOriented(bytes);
      if (oriented == null) {
        debugPrint("명령 3: 사진 디코딩 실패 — 이번 프레임 건너뜀.");
        if (wasStreaming && _isAutoMode) await _ensureImageStreamRunning();
        return;
      }

      // 첫 수집 캡처에서 책등 위치를 자동 감지한다.
      final fresh =
          _cellLines.every((c) => c == null) &&
          _pendingCellImages.every((b) => b == null);
      if (fresh) {
        final detected = _detectSpineX(oriented, _captureBox);
        if (mounted) setState(() => _spineX = detected);
      }

      final box = _captureBox;
      final spine = _spineX.clamp(box.left, box.right);
      final overlap = _bandOverlap * box.height;

      // ── ① 좌상단 OCR — 매 캡처마다 페이지 ID 검증 ─────────────────
      // 좌상단은 _topBandHasHand 게이트로 깨끗함이 보장된 상태. 매번 OCR해
      // 진행 중인 페이지와 같은지 확인한다(움직임이 페이지 넘김이었는지 판정).
      final (bandTop0, bandBottom0) = _bandBounds(0);
      final topLeftCrop = _cropEncode(
        oriented,
        bandTop0 - overlap,
        bandBottom0 + overlap,
        box.left,
        spine,
      );
      final topLeftLines = await _ocrLines(topLeftCrop);
      final currentFp = _buildFingerprintLines(topLeftLines, const []);

      bool isStage1 = _bandPageFingerprint == null;
      if (!isStage1 &&
          currentFp.isNotEmpty &&
          _fingerprintSimilarity(currentFp, _bandPageFingerprint!) <
              _rereadSimThreshold) {
        // 페이지가 바뀜 → 버퍼 리셋, 이번 캡처를 새 stage-1로 본다.
        debugPrint("수집 중 페이지 넘김 감지 — 버퍼 리셋, 새 페이지 재시작.");
        _resetBandCollection();
        isStage1 = true;
      }

      if (isStage1) {
        // stage 1: 저장된 페이지와의 재독 검사.
        if (currentFp.length >= _fingerprintLineCount) {
          final stored = _matchStoredPage(currentFp);
          if (stored != null) {
            _handleProbeReread(stored);
            _resetBandCollection();
            if (mounted && _isAutoMode) {
              _lastCaptureAt = DateTime.now();
              _awaitingMotionBeforeNextCapture = true;
              _stableSince = null;
            }
            if (wasStreaming && _isAutoMode) {
              await _ensureImageStreamRunning();
            }
            return;
          }
        }
        // 새 페이지로 확정.
        _bandPageFingerprint = currentFp;
      }

      // 좌상단 OCR 결과 저장(아직 없거나 비어 있던 자리에 더 풍부한 OCR이면 갱신).
      final stored = _cellLines[0];
      if (stored == null || (stored.isEmpty && topLeftLines.isNotEmpty)) {
        _cellLines[0] = topLeftLines;
      }

      // ── ② 나머지 깨끗한 칸은 이미지로만 저장(OCR 지연) ──────────────
      for (int row = 0; row < _bandCount; row++) {
        final (bandTop, bandBottom) = _bandBounds(row);
        final cropTop = bandTop - overlap;
        final cropBottom = bandBottom + overlap;
        for (int col = 0; col < 2; col++) {
          final idx = row * 2 + col;
          if (idx == 0) continue; // 좌상단은 위에서 처리됨
          if (_cellLines[idx] != null || _pendingCellImages[idx] != null) {
            continue;
          }
          if (coverage[idx]) continue;
          final left = col == 0 ? box.left : spine;
          final right = col == 0 ? spine : box.right;
          _pendingCellImages[idx] = _cropEncode(
            oriented,
            cropTop,
            cropBottom,
            left,
            right,
          );
        }
      }

      if (mounted && _isAutoMode) {
        _lastCaptureAt = DateTime.now();
        _stableSince = null;
      }

      // ── ③ 모든 칸이 데이터(OCR or 이미지)를 가졌으면 배치 OCR + 조립 ──
      final allHaveData = [
        for (int i = 0; i < _cellLines.length; i++)
          _cellLines[i] != null || _pendingCellImages[i] != null,
      ].every((b) => b);

      if (allHaveData) {
        final pendingIdxs = <int>[];
        final pendingFutures = <Future<List<_VisionLine>>>[];
        for (int i = 0; i < _cellLines.length; i++) {
          if (_cellLines[i] == null && _pendingCellImages[i] != null) {
            pendingIdxs.add(i);
            pendingFutures.add(_ocrLines(_pendingCellImages[i]!));
          }
        }
        if (pendingFutures.isNotEmpty) {
          debugPrint("배치 OCR: ${pendingFutures.length}장 동시 발사.");
          final results = await Future.wait(pendingFutures);
          for (int k = 0; k < pendingIdxs.length; k++) {
            _cellLines[pendingIdxs[k]] = results[k];
            _pendingCellImages[pendingIdxs[k]] = null;
          }
        }
        await _assembleAndSaveBands();
      }

      if (wasStreaming && _isAutoMode) {
        await _ensureImageStreamRunning();
      }
    } catch (e) {
      debugPrint("명령 3: 셀 수집 오류: $e");
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
  // 책 박스 정중앙을 기준으로 ±20%(박스 너비 대비) 창 안에서만, 텍스처(가로
  // 명암 변화)가 가장 적은 세로 컬럼을 책등으로 본다. 창을 좁혀, 텍스트 가장자리
  // 등 엉뚱한 위치로 오검출되는 일을 막는다. 항상 박스 안 값을 돌려준다(실패 시 중앙).
  double _detectSpineX(img.Image src, Rect box) {
    // 박스 정중앙 — 검출 실패 시 이 값을 그대로 책등으로 쓴다.
    final center = (box.left + box.right) / 2;
    // 스캔을 가볍게 하려고 폭 480으로 축소한다.
    final small = src.width > 480 ? img.copyResize(src, width: 480) : src;
    final w = small.width;
    final h = small.height;
    if (w < 20 || h < 20) return center;
    // 가로: 박스 중앙 ±20%(박스 너비) 창. 세로: 박스 중앙 25~75% 행.
    final halfWin = 0.20 * box.width;
    final xStart = ((center - halfWin) * w).round().clamp(1, w - 1);
    final xEnd = ((center + halfWin) * w).round().clamp(xStart + 1, w);
    final yStart = ((box.top + box.height * 0.25) * h)
        .round()
        .clamp(0, h - 1);
    final yEnd = ((box.top + box.height * 0.75) * h)
        .round()
        .clamp(yStart + 1, h);
    if (xEnd - xStart < 3 || yEnd - yStart < 3) return center;

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
    if (bestIdx < 0) return center;
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

  // 명령 3: 8칸이 모두 모이면 좌/우 컬럼을 각각 스티칭한 뒤 페이지 저장소에 반영한다.
  Future<void> _assembleAndSaveBands() async {
    // 좌·우 컬럼을 행 순서(위→아래)대로 모아 겹침 앵커 스티칭한다.
    final (leftMerged, leftFailed) = _stitchColumn([
      for (int row = 0; row < _bandCount; row++)
        _cellLines[row * 2] ?? const <_VisionLine>[],
    ]);
    final (rightMerged, rightFailed) = _stitchColumn([
      for (int row = 0; row < _bandCount; row++)
        _cellLines[row * 2 + 1] ?? const <_VisionLine>[],
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
    debugPrint(
      "명령 3: 재독 판정 — 최고 유사도 ${bestSim.toStringAsFixed(2)}"
      "(임계 $_rereadSimThreshold), 새 지문=$fingerprint, "
      "저장된 페이지 ${_pageStore.map((p) => p.rightNumber).toList()}.",
    );

    if (matched != null && bestSim >= _rereadSimThreshold) {
      // 이미 읽은 페이지 — 새로 저장하지 않는다. 더 선명하면 본문만 교체한다.
      final hit = matched;
      if (quality > hit.quality) {
        hit.leftText = leftText;
        hit.rightText = rightText;
        hit.quality = quality;
      }
      _advanceAnchor(hit.rightNumber);
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
          _currentRecognizedPage = hit.rightNumber;
        });
        _flashPageUpdate("중복 페이지(${hit.rightNumber}P) - OCR 수행X");
      }
      return;
    }

    // 새 페이지 — 좌·우 연속성 + 앵커 + 혼동쌍으로 페이지 번호를 확정한다.
    final resolved = _resolvePageNumbers(leftLines, rightLines);
    final leftNumber = resolved.left;
    final rightNumber = resolved.right;
    final numberConfirmed = resolved.confirmed;

    final page = _StoredPage(
      leftNumber: leftNumber,
      rightNumber: rightNumber,
      numberConfirmed: numberConfirmed,
      leftText: leftText,
      rightText: rightText,
      topLines: fingerprint,
      quality: quality,
    );
    _pageStore.add(page);
    _registerTopLines(fingerprint);
    _advanceAnchor(rightNumber);
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
        _currentRecognizedPage = rightNumber;
      });
      _flashPageUpdate("페이지 업데이트됨 (${leftNumber}P, ${rightNumber}P)");
    }
  }

  // 상단 지문으로 _pageStore에서 같은 페이지(재독)를 찾는다. 없으면 null.
  _StoredPage? _matchStoredPage(List<String> fingerprint) {
    if (_pageStore.isEmpty || fingerprint.length < _fingerprintLineCount) {
      return null;
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
    return (matched != null && bestSim >= _rereadSimThreshold)
        ? matched
        : null;
  }

  // 슬라이스 1(페이지 확인 우선): 상단 탐침에서 재독으로 판정된 경우 —
  // 본문 전체 OCR을 건너뛰고 기존 페이지를 그대로 유지한다.
  void _handleProbeReread(_StoredPage hit) {
    _advanceAnchor(hit.rightNumber);
    debugPrint(
      "페이지 확인: 상단 탐침에서 재독 감지 — 기존 ${hit.rightNumber}P, 본문 OCR 생략.",
    );
    if (mounted) {
      AppStateScope.of(
        context,
      ).updateBookCurrentPage(widget.bookId, hit.rightNumber);
      setState(() {
        _lastOcrFullText = hit.text;
        _currentRecognizedPage = hit.rightNumber;
      });
      _flashPageUpdate("중복 페이지 - OCR 수행X");
    }
  }

  // 페이지 식별 지문 — 좌측 페이지 상단 줄을 우선 쓰고, 좌측에 글자가 없으면
  // 우측 페이지 상단 줄을 쓴다. 좌측 위주라, 오른쪽을 손으로 가려도 지문이 안 깨진다.
  List<String> _buildFingerprintLines(
    List<_VisionLine> leftLines,
    List<_VisionLine> rightLines,
  ) {
    List<String> topOf(List<_VisionLine> lines) => lines
        .map((l) => l.text.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((t) => t.isNotEmpty)
        .take(_fingerprintLineCount)
        .toList();
    final left = topOf(leftLines);
    return left.isNotEmpty ? left : topOf(rightLines);
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

  // ── 페이지 번호 확정 ──────────────────────────────────────────────
  // ① 베이스라인: OCR을 기본 신뢰(예전 단순 보정 — 비연속이면 큰 쪽 신뢰,
  //    한쪽만 있으면 인접번호 유도, 둘 다 없으면 앵커+1·+2 폴백).
  // ② 방어: 결과가 기대값에서 '갑자기 점프'했거나 패리티 락을 어기면,
  //    혼동쌍 스왑을 모든 조합으로 시도해 기대값과 *정확히 일치*하면 오인으로
  //    보고 기대값으로 교정. 패리티 락 위반인데 스왑도 안 맞으면 기대값 강제.
  // ③ 패리티 학습: 깨끗한 reading(둘 다 OCR + 연속)이 같은 패리티로 연속
  //    _parityLockMinVotes회 나오면 락. 락이 잡히면 이후 위반은 ②가 보정.

  // "갑자기 점프"로 볼 기대값 대비 최소 차이(페이지 수).
  static const int _suddenJumpThreshold = 5;
  // 패리티 락에 필요한 연속 일치 횟수.
  static const int _parityLockMinVotes = 5;

  // OCR이 인쇄체에서 자주 헷갈리는 숫자 쌍.
  static const Map<int, List<int>> _digitConfusions = {
    0: [6, 8],
    1: [4, 7],
    3: [8, 9],
    4: [1, 9],
    5: [6, 8],
    6: [0, 5, 8],
    7: [1, 9],
    8: [0, 3, 5, 6],
    9: [3, 4, 7],
  };

  // 페이지 패리티 락 상태(이 책의 펼침면이 짝-홀인지 홀-짝인지).
  _PageParity? _parityLock;
  _PageParity? _parityRunType;
  int _parityRunCount = 0;

  _PageParity _parityOf(int left) =>
      left.isEven ? _PageParity.evenOdd : _PageParity.oddEven;

  // 한 자릿수에서 OCR이 헷갈릴 수 있는 후보들(자기 자신 포함).
  List<int> _digitVariants(int digit) {
    return [digit, ...(_digitConfusions[digit] ?? const [])];
  }

  // [n]의 자릿수마다 혼동쌍 치환을 곱집합으로 펼친 모든 변형 숫자.
  Set<int> _numberSwapVariants(int n) {
    if (n < 0) return {n};
    final digits = n
        .toString()
        .split('')
        .map((c) => _digitVariants(int.parse(c)))
        .toList();
    final out = <int>{};
    void recurse(int idx, String acc) {
      if (idx == digits.length) {
        out.add(int.parse(acc));
        return;
      }
      for (final d in digits[idx]) {
        recurse(idx + 1, '$acc$d');
      }
    }
    recurse(0, '');
    return out;
  }

  // 좌·우 OCR값을 혼동쌍 스왑으로 (expLeft, expRight)에 정확히 도달할 수 있나.
  // 둘 다 있으면 둘 다, 하나만 있으면 그쪽만 일치하면 된다.
  bool _canCorrectViaSwap(
    int? rawLeft,
    int? rawRight,
    int expLeft,
    int expRight,
  ) {
    if (rawLeft != null && rawRight != null) {
      return _numberSwapVariants(rawLeft).contains(expLeft) &&
          _numberSwapVariants(rawRight).contains(expRight);
    }
    if (rawLeft != null) {
      return _numberSwapVariants(rawLeft).contains(expLeft);
    }
    if (rawRight != null) {
      return _numberSwapVariants(rawRight).contains(expRight);
    }
    return false;
  }

  // 앵커(_lastCommittedRight)를 전진시킨다 — 뒤로 돌아간 곁다리가 앵커를
  // 끌어내리지 않도록 max로만 갱신한다.
  void _advanceAnchor(int right) {
    _lastCommittedRight = _lastCommittedRight == null
        ? right
        : math.max(_lastCommittedRight!, right);
  }

  // 패리티 학습 — 깨끗한 reading일 때만 카운트, 연속 N회면 락.
  void _learnParity(int left) {
    if (_parityLock != null) return; // 이미 락된 책은 학습 안 함
    final p = _parityOf(left);
    if (_parityRunType == p) {
      _parityRunCount++;
    } else {
      _parityRunType = p;
      _parityRunCount = 1;
    }
    if (_parityRunCount >= _parityLockMinVotes) {
      _parityLock = p;
      debugPrint(
        "페이지 패리티 락: ${p == _PageParity.evenOdd ? '짝-홀' : '홀-짝'}",
      );
    }
  }

  // 한 펼침면의 좌·우 페이지 번호를 확정한다.
  // confirmed=false면 OCR을 그대로 안 쓰고 추정/방어 교정된 결과다.
  ({int left, int right, bool confirmed}) _resolvePageNumbers(
    List<_VisionLine> leftLines,
    List<_VisionLine> rightLines,
  ) {
    final rawLeft = _extractBottomPageNumber(leftLines);
    final rawRight = _extractBottomPageNumber(rightLines);
    final anchor = _lastCommittedRight;

    // ① 베이스라인 — OCR 신뢰(예전 방식).
    int? l = rawLeft;
    int? r = rawRight;
    bool confirmed = rawLeft != null || rawRight != null;

    if (l != null && r != null && r != l + 1) {
      // 비연속 — 더 큰 쪽을 진실로 보고 다른 쪽을 ±1로 보정.
      if (l >= r) {
        r = l + 1;
      } else {
        l = r - 1;
      }
    }
    if (l == null && r == null) {
      l = anchor != null ? anchor + 1 : 1;
      r = anchor != null ? anchor + 2 : 2;
    } else {
      l ??= r! - 1;
      r ??= l + 1;
    }

    // ② 방어 — 갑작스러운 점프 or 패리티 락 위반이면 스왑-검산 시도.
    if (anchor != null) {
      final expLeft = anchor + 1;
      final expRight = anchor + 2;
      final sudden = (r - expRight).abs() > _suddenJumpThreshold;
      final parityViolates =
          _parityLock != null && _parityOf(l) != _parityLock;
      if (sudden || parityViolates) {
        if (_canCorrectViaSwap(rawLeft, rawRight, expLeft, expRight)) {
          debugPrint(
            "혼동쌍 스왑 교정: $rawLeft|$rawRight → $expLeft|$expRight",
          );
          l = expLeft;
          r = expRight;
          confirmed = false;
        } else if (parityViolates) {
          // 락 위반인데 스왑으로도 일치 안 함 — 락을 우선해 기대값 강제.
          debugPrint(
            "패리티 락 위반(스왑 실패): $rawLeft|$rawRight → $expLeft|$expRight",
          );
          l = expLeft;
          r = expRight;
          confirmed = false;
        }
        // sudden만이고 스왑도 안 맞으면 → 진짜 점프 후보로 보고 그대로 둔다.
      }
    }

    // ③ 패리티 학습 — 깨끗한(둘 다 OCR + 연속) 베이스라인에만 표 한 장.
    if (confirmed &&
        rawLeft != null &&
        rawRight != null &&
        rawRight == rawLeft + 1) {
      _learnParity(l);
    }

    return (left: l, right: r, confirmed: confirmed);
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

  // 분석용 전체 누적 본문 — 영구 페이지 본문(_pagetext.json)에 이번에 새로
  // 스캔한 페이지를 더해 페이지 번호순으로 펼친다. ui_summary가 새 페이지만이
  // 아니라 책 전체를 요약하는 데 쓰인다.
  Future<String> _buildFullBookText() async {
    final map = <int, String>{};
    try {
      final paths = await _getFilePaths();
      final file = File(paths['pagetext']!);
      if (await file.exists()) {
        final raw = await file.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            decoded.forEach((key, value) {
              final pageNumber = int.tryParse(key.toString());
              if (pageNumber != null &&
                  value is String &&
                  value.trim().isNotEmpty) {
                map[pageNumber] = value;
              }
            });
          }
        }
      }
    } catch (e) {
      debugPrint("전체 누적 본문 읽기 오류: $e");
    }
    // 아직 _pagetext.json에 병합되지 않은 이번 스캔분을 더한다.
    for (final page in _pageStore) {
      if (page.leftText.trim().isNotEmpty) {
        map[page.leftNumber] = page.leftText;
      }
      if (page.rightText.trim().isNotEmpty) {
        map[page.rightNumber] = page.rightText;
      }
    }
    final pageNumbers = map.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final pageNumber in pageNumbers) {
      buffer.writeln('=== $pageNumber쪽 ===');
      buffer.writeln(map[pageNumber]!.trim());
      buffer.writeln();
    }
    return buffer.toString();
  }

  // 관계도 SVG를 백그라운드에서 생성·저장한다(분석 화면 전환을 막지 않음).
  Future<void> _generateRelationshipSvg(
    Book book,
    String fullText,
    String savePath,
  ) async {
    try {
      final svg = await _claudeService
          .generateRelationshipSvg(book: book, fullText: fullText)
          .timeout(const Duration(seconds: 120), onTimeout: () => null);
      if (svg != null && svg.trim().isNotEmpty) {
        await File(savePath).writeAsString(svg);
        debugPrint("관계도 SVG 저장 완료 (${svg.length}자).");
      } else {
        debugPrint("관계도 SVG 생성 실패 — 건너뜀.");
      }
    } catch (e) {
      debugPrint("관계도 SVG 생성 오류: $e");
    }
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

  // 페이지 인용 Q&A용 영구 페이지 본문 저장소(<bookId>_pagetext.json)에
  // 이번 분석분의 페이지별 본문을 병합한다. 페이지 번호를 키로 하므로 같은
  // 페이지를 다시 스캔하면 최신 본문으로 덮어쓴다. 분석 후에도 지우지 않는다.
  Future<void> _mergePageTextStore() async {
    if (_pageStore.isEmpty) return;
    try {
      final paths = await _getFilePaths();
      final file = File(paths['pagetext']!);
      final map = <String, dynamic>{};
      if (await file.exists()) {
        final raw = await file.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) map.addAll(decoded);
        }
      }
      for (final page in _pageStore) {
        if (page.leftText.trim().isNotEmpty) {
          map['${page.leftNumber}'] = page.leftText;
        }
        if (page.rightText.trim().isNotEmpty) {
          map['${page.rightNumber}'] = page.rightText;
        }
      }
      await file.writeAsString(jsonEncode(map));
      debugPrint("페이지 본문 저장소 병합 — 총 ${map.length}쪽.");
    } catch (e) {
      debugPrint("페이지 본문 저장소 병합 오류: $e");
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
      case _CaptureStatus.pageChecking:
        return '페이지 검사중';
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

      // 페이지 저장소를 번호순 평문으로 펼친다(누락 구간엔 마커 삽입).
      final String newRawText = _buildFlatTextFromStore();
      if (newRawText.trim().isEmpty) {
        throw Exception("스캔된 새로운 텍스트가 없습니다.");
      }

      // 기존 맥락 — 직전 분석의 요약·인물을 다음 분석 입력으로 그대로 잇는다.
      final existingBook = appState.findBookById(widget.bookId);
      final String oldStory = (existingBook?.summary ?? '').trim().isEmpty
          ? '(없음)'
          : existingBook!.summary;
      final String oldChar = _buildExistingCharacterText(existingBook);

      // 전체 누적 본문 — 분석은 이 본문 전체를 근거로 한다.
      final String fullBookText = await _buildFullBookText();

      // 1. Gemini 통합 분석 요청 (요약·인물·관계 추출)
      final responseJson = await _getGeminiIntegratedUpdate(
        newRawText,
        oldStory,
        oldChar,
        fullBookText,
      );
      final Map<String, dynamic> result = jsonDecode(responseJson);

      // 2. 앱 UI 데이터 업데이트
      appState.updateBookSummary(widget.bookId, result['ui_summary'] ?? "");

      if (result['ui_characters'] != null) {
        final rawCharacters = result['ui_characters'];
        if (rawCharacters is List) {
          appState.updateBookCharacters(widget.bookId, rawCharacters);
        }
      }

      if (result['ui_relationships'] != null) {
        final rawRelationships = result['ui_relationships'];
        if (rawRelationships is List) {
          appState.updateBookRelationships(widget.bookId, rawRelationships);
        }
      }

      // 3. ✅ 페이지 본문을 영구 저장소에 병합한 뒤 작업용 저장소를 비운다.
      await _mergePageTextStore();
      if (await pagesFile.exists()) await pagesFile.delete();
      _pageStore.clear();
      _topLineFrequency.clear();
      _lastCommittedRight = null;
      debugPrint("🗑️ 분석 완료 — 페이지 본문 보관, 작업 저장소 삭제.");

      // 4. 관계도 SVG 생성(Claude)은 백그라운드로 — 분석 완료·화면 전환을 막지 않는다.
      final analyzedBook = appState.findBookById(widget.bookId);
      if (analyzedBook != null && _claudeService.isConfigured) {
        // 의도적으로 await하지 않는다. 생성이 끝나면 파일로 저장되고
        // 관계 탭이 그 파일을 읽어 표시한다.
        _generateRelationshipSvg(analyzedBook, fullBookText, paths['relmap']!);
      }

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => BookDetailScreen(bookId: widget.bookId),
          ),
        );
      }
    } catch (e) {
      debugPrint("❌ 업데이트 실패: $e");
    } finally {
      if (mounted) setState(() => _isProcessingAnalysis = false);
    }
  }

  // 직전 분석의 인물 목록을 다음 분석 프롬프트의 "기존 인물 데이터"로 넘길 텍스트.
  // 이름을 그대로 보여줘 Gemini가 같은 인물에 새 이름을 붙이지 않도록 돕는다.
  String _buildExistingCharacterText(Book? book) {
    final characters = book?.characters ?? const <Character>[];
    if (characters.isEmpty) return '(없음)';
    return characters
        .map(
          (c) =>
              '- ${c.name} / ${c.role} / 중요도 ${c.importance}'
              '${c.firstPage != null ? ' / 첫등장 ${c.firstPage}쪽' : ''}: '
              '${c.description}',
        )
        .join('\n');
  }

  Future<String> _getGeminiIntegratedUpdate(
    String newText,
    String oldStory,
    String oldChar,
    String fullText,
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

[전체 누적 본문]
$fullText

지침:
1. ui_summary: 사용자가 앱 화면에서 바로 읽을 수 있는 줄거리 요약입니다. (평문)
   - 새로 스캔된 부분만이 아니라, 위 [전체 누적 본문]을 처음부터 끝까지 바탕으로 책 전체 줄거리를 요약하세요.
   - [전체 누적 본문]에 빠진 페이지가 있더라도, 확보된 본문 범위 안에서 자연스럽게 이어지는 요약을 작성하세요.
   - 가독성이 가장 중요합니다. 한 덩어리 글로 쓰지 말고, 사건 흐름에 따라 3~5개의 짧은 문단으로 나누세요.
   - 각 문단은 3~4문장 정도로 짧게 쓰고, 문단과 문단 사이는 반드시 빈 줄 하나(줄바꿈 문자 \\n\\n)로 구분하세요.
   - 시간 순서대로 자연스럽게 이어지게 쓰고, 어려운 표현 없이 쉽게 쓰세요.
2. ui_characters: 앱의 인물 탭·상세 프로필에 보여줄 누적 인물 데이터입니다. 형식: [{"name": "이름", "role": "역할", "description": "소개", "personality": "성격", "motivation": "목표·동기", "first_page": 12, "importance": 4}]
   - importance: 이 인물이 이야기에서 차지하는 비중을 1~5 정수로 쓰세요. 주인공·핵심 인물은 5, 자주 등장하는 주요 인물은 4, 조연은 2~3, 한두 번 스쳐 언급될 뿐인 단역은 1.
   - description: 인물이 누구인지 한국어 2~3문장으로 소개하세요. 역할과 현재 상황 위주로.
   - personality: 인물의 성격·태도를 1~2문장으로 쓰세요. 텍스트에서 확인되는 행동·말에 근거해서. 아직 드러나지 않았으면 빈 문자열("")로 두세요.
   - motivation: 인물이 원하는 것·목표·행동 동기를 1~2문장으로 쓰세요. 아직 드러나지 않았으면 빈 문자열("")로 두세요.
   - first_page: 이 인물이 [전체 누적 본문]에서 처음 등장하는 페이지 번호입니다. "=== N쪽 ===" 표시를 기준으로 정수로 쓰세요. 판단이 어려우면 이 항목을 생략하세요.
   - 모든 항목은 스캔된 텍스트 근거 안에서만 쓰고, 확실하지 않은 추측·앞으로의 전개 예측·텍스트에 없는 배경 설정은 넣지 마세요.
   - 기존 인물 데이터가 있으면 새 텍스트와 합쳐 누적 업데이트하세요. 새 텍스트에 나오지 않았다는 이유만으로 기존 사실을 지우지 마세요.
   - 잠깐 언급된 인물은 억지로 길게 쓰지 말고 확인된 사실만 짧게 쓰세요.
3. ui_relationships: 앱의 관계 탭에 표시할 인물 관계 데이터입니다. 형식: [{"source": "인물 이름", "target": "인물 이름", "label": "짧은 관계명", "description": "관계 설명", "evidence": "근거", "strength": 1, "type": "관계 유형"}]
   - source와 target은 반드시 ui_characters에 포함된 실제 인물 이름을 그대로 쓰세요.
   - label은 "친구", "가족", "협력", "대립", "스승과 제자"처럼 화면에 올릴 짧은 표현으로 쓰세요.
   - description은 두 인물 사이의 현재 관계를 1~2문장으로 설명하세요.
   - evidence는 스캔 텍스트에서 확인되는 근거를 짧게 요약하세요. 직접 인용이 불확실하면 요약으로 쓰세요.
   - strength는 관계가 얼마나 뚜렷한지 1~5 정수로 쓰세요. 잠깐 언급된 약한 관계는 1, 반복되고 서사적으로 중요한 관계는 5입니다.
   - type은 ally, family, conflict, romance, mentor, mystery, neutral 중 가장 가까운 값을 쓰세요.
   - 관계가 확실하지 않거나 한쪽 인물이 불명확하면 넣지 마세요.
4. ui_characters에는 이야기에서 한 개인으로 추적 가능한 등장인물만 넣으세요. 다음은 넣지 마세요:
   - 군중, 주민들, 학생들, 사람들 같은 집단 표현
   - 장소, 단체, 개념, 사물
   - 컴퓨터, 인공지능(AI)·시스템, 기계, 로봇, 장비, 도구, 우주선·차량 같은 인공물 (대화하거나 인격적으로 묘사되더라도 도구이므로 제외)
   - "누군가", "어떤 사람", "친구"처럼 특정 개인을 가리키지 않는 막연한 표현
   - 한 번 스쳐 지나갈 뿐 한 개인으로 추적되지 않는 일반 호칭
5. 등장인물은 사람, 또는 외계 생명체처럼 이야기에서 인격·의지를 지닌 인물로 다뤄지는 생명체에 한합니다. 그 전제 위에서, 이름이 아직 밝혀지지 않은 인물도 이야기에서 한 개인으로 일관되게 추적된다면 반드시 포함하세요.
   - 1인칭 시점으로 서사를 이끄는 화자·주인공은 이름이 없어도 가장 핵심 인물입니다. 반드시 포함하고 name을 "주인공(이름 미상)"으로 표기하세요.
   - 그 밖에 이름은 없지만 한 개인으로 추적되는 인물은 "죽은 동료 A", "정체불명의 남자"처럼 식별 가능한 서술형 이름으로 포함하세요.
   - ★매우 중요★ [기존 인물 데이터]에 이미 있는 인물은 그 이름(name)을 한 글자도 바꾸지 말고 그대로 다시 쓰세요. 같은 인물에게 새 이름이나 다른 표기를 붙이지 마세요. 예: 기존에 "죽은 동료 A"가 있으면 이번에도 반드시 "죽은 동료 A"라고 쓰고, "죽은 동료 1"이나 "사망한 동료" 같은 새 이름을 만들지 마세요.
   - 이름 없는 잠정 인물(죽은 동료 등)은 본문에 실제로 존재하는 인원수만큼만 만드세요. 같은 인물을 여러 항목으로 중복해서 넣지 마세요. 예: 본문에 죽은 동료가 2명이면 항목도 정확히 2개입니다.
   - 기존 인물 데이터에 잠정 이름("이름 미상" 등)의 인물이 있고 새 텍스트에서 실제 이름이 밝혀지면, 잠정 이름 항목을 실명으로 교체해 누적 업데이트하세요(중복 항목을 만들지 마세요).
6. 직책이나 관계만 있고 특정 개인으로 식별·추적되지 않는 대상은 넣지 마세요. 추적 가능한 단수 개인만 남기세요.

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
          // 내부 추론(thinking)을 꺼서 분석 응답 속도를 높인다.
          "thinkingConfig": {"thinkingBudget": 0},
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

    // 상단 표시:
    //   · '현재 페이지' = 방금 인식된 페이지(literal, _currentRecognizedPage)
    //   · '마지막으로 읽은 페이지' = 가장 멀리 읽은 페이지(max, book.currentPage)
    final book = AppStateScope.of(context).findBookById(widget.bookId);
    final currentPage = _currentRecognizedPage;
    final lastReadPage = book?.currentPage ?? 0;

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
                          "마지막으로 읽은 페이지: $lastReadPage P",
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: Color(0xFF455A64),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          widget.bookTitle,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          "현재 페이지: $currentPage P",
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
                onZoomGestureStart: _onZoomGestureStart,
                onZoomGestureUpdate: _onZoomGestureUpdate,
                isCapturing: _isAutoMode,
                isProcessing: _isProcessingAnalysis,
                onAnalyzePressed: _performAnalysis,
                onCapturePressed: _startAutoCapture,
                onStopPressed: _stopAutoCapture,
                debugEnabled: _debugPanelEnabled,
                handResult: _handResult,
                bookBox: _bookBox,
                captureStatusLabel: _captureStatusLabel,
                handLatched: _handLatched,
                trackedHandBox: _trackedHandBox,
                handCoversText: _handLatched && _handCoversText(),
                spineX: _spineX,
                cellCoverage: _cellCoverage(),
                cellCollected: _cellCollectedView(),
                textRegionInset: _textRegionInset,
                onShowFullOcr: _showFullOcrDialog,
                pageUpdateLabel: _pageUpdateInfo,
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
/// 슬라이스 1: 페이지 저장소에 보관하는 펼침면 한 장.
/// leftNumber/rightNumber는 좌/우 페이지 번호(확정 또는 추정), topLines는 재독
/// 판정용 상단 지문(러닝 헤더 제거는 비교 시점에 동적으로 한다).
class _StoredPage {
  _StoredPage({
    required this.leftNumber,
    required this.rightNumber,
    required this.numberConfirmed,
    required this.leftText,
    required this.rightText,
    required this.topLines,
    required this.quality,
  });

  final int leftNumber;
  final int rightNumber;
  final bool numberConfirmed; // 페이지 번호를 OCR로 확정했는지(false=직전+N 추정)
  String leftText; // 왼쪽 페이지 본문 — 재독 시 더 선명한 사본으로 교체될 수 있음
  String rightText; // 오른쪽 페이지 본문 — 재독 시 교체될 수 있음
  final List<String> topLines; // 좌/우 상단 줄(정규화) — 재독 지문
  int quality; // OCR 품질 점수 — 재독 교체 판단

  // 분석용 평문 — 좌·우 페이지 본문을 합친다.
  String get text =>
      [leftText, rightText].where((t) => t.trim().isNotEmpty).join('\n');

  Map<String, dynamic> toJson() => {
    'leftNumber': leftNumber,
    'rightNumber': rightNumber,
    'numberConfirmed': numberConfirmed,
    'leftText': leftText,
    'rightText': rightText,
    'topLines': topLines,
    'quality': quality,
  };

  static _StoredPage fromJson(Map<String, dynamic> json) => _StoredPage(
    leftNumber: (json['leftNumber'] as num?)?.toInt() ?? 0,
    rightNumber: (json['rightNumber'] as num?)?.toInt() ?? 0,
    numberConfirmed: json['numberConfirmed'] as bool? ?? false,
    leftText: json['leftText'] as String? ?? '',
    rightText: json['rightText'] as String? ?? '',
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
  pageChecking, // 상단 띠 OCR로 페이지(재독) 검사 중
}

// 펼침면 패리티 — 책의 본래 페이지매김 규칙.
//   evenOdd: 왼쪽=짝수, 오른쪽=홀수 (LTR 책의 표준; 예 20|21)
//   oddEven: 왼쪽=홀수, 오른쪽=짝수 (RTL/일부 조판; 예 21|22)
enum _PageParity { evenOdd, oddEven }
