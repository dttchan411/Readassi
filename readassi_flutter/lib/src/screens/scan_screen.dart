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
import '../services/demo_dashboard_service.dart';
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
  static const int _pageNumberSearchLines = 6; // 페이지번호를 찾을 줄 수(셀 위/아래)
  static const int _pageNumberMaxTokens = 6; // 페이지번호 줄로 볼 최대 어절 수

  final String _googleVisionApiKey = dotenv.env['_googleVisionApiKey'] ?? "";
  final String _geminiApiKey = dotenv.env['_geminiApiKey'] ?? "";
  final ClaudeService _claudeService = ClaudeService();
  final HandDetectionService _handDetectionService = HandDetectionService();
  final BookBoxDetectionService _bookBoxService = BookBoxDetectionService();
  // 발표 데모용 실시간 대시보드 — 같은 네트워크 노트북 브라우저에서 8칸 상태 본다.
  // static으로 두어 스캔 화면을 떠나도 서버가 죽지 않게 한다(앱 수명 동안 유지).
  static final DemoDashboardService _dashboard = DemoDashboardService();

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
  // OCR 후에도 살아남아 페이지 commit / 미확인 demote 시 디스크에 저장될 셀 이미지.
  // _pendingCellImages는 OCR 발사 후 null로 비워지지만 이건 _resetBandCollection 전까지 유지.
  final List<Uint8List?> _cellImageBytes = List<Uint8List?>.filled(
    _bandCount * 2,
    null,
  );
  // 슬라이스 2: 지금 띠 수집 중인 페이지의 상단 지문(페이지 ID). 수집 도중
  // 이 지문이 크게 달라지면 페이지가 넘어간 것으로 보고 띠 버퍼를 리셋한다.
  List<String>? _bandPageFingerprint;
  // 재독(B 케이스) 시각화 — 저장된 페이지로 판정된 직후 다음 새 페이지가 들어올
  // 때까지 디버그 패널의 8칸을 모두 ●(수집됨)으로 표시한다.
  bool _rereadShowAllCollected = false;
  // 디버그 'OCR 결과 전체보기'용 — 마지막 OCR/조립 전체 텍스트.
  String? _lastOcrFullText;

  // 슬라이스 1: 명령 3로 조립된 펼침면을 페이지 번호 키로 보관하는 저장소.
  // 재독(이미 읽은 페이지) 감지·중복 방지·누락 페이지 기록의 source of truth.
  final List<_StoredPage> _pageStore = [];
  // 미확인 버퍼 — 아직 8칸 다 못 모았지만 페이지 넘김/촬영 중지 등으로 임시 보관 중인
  // 페이지들. 다음 좌상단 OCR이 이 중 매칭되면 그 버퍼를 복원해 이어서 수집.
  // 메타데이터는 메모리, 셀 이미지는 디스크. FIFO로 최근 3개만 유지.
  final List<_PendingPage> _pendingPages = [];
  static const int _pendingBufferLimit = 3;
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
    // 대시보드는 static이라 화면 떠나도 서버 유지(앱 수명 동안).
    // 데모/디버그용이라 명시적 종료는 안 함 — 프로세스 종료 시 자연히 정리.
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

      // 카메라가 켜진 순간부터 손 추적이 돌도록 스트림을 곧장 시작한다.
      // _handleCameraImage가 _isAutoMode와 무관하게 손 검출만 항상 수행하고,
      // 캡처 로직은 _isAutoMode일 때만 발동한다. 촬영 시작 누를 때 손 위치를
      // 이미 알고 있어 책 박스 검출에 즉시 사용 가능.
      await _ensureImageStreamRunning();

      // 발표 데모용 외부 대시보드 시작(같은 Wi-Fi 노트북에서 URL로 접속).
      await _dashboard.start();
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
      'imagesDir': p.join(
        bookDir.path,
        '${widget.bookId}_images',
      ), // 페이지/미확인 셀 이미지 디렉토리(B 케이스 시각화 / 미확인 재현용)
    };
  }

  // 8셀 이미지 바이트를 디스크에 저장하고 경로 리스트(8) 반환.
  // subdir: 'page_<rightNum>' 또는 'pending_<id>' 같은 하위 폴더 이름.
  Future<List<String?>> _saveCellImagesToDisk(
    List<Uint8List?> bytes,
    String subdir,
  ) async {
    final paths = await _getFilePaths();
    final root = Directory(p.join(paths['imagesDir']!, subdir));
    try {
      await root.create(recursive: true);
    } catch (e) {
      debugPrint("이미지 디렉토리 생성 실패: $e");
      return List<String?>.filled(bytes.length, null);
    }
    final result = List<String?>.filled(bytes.length, null);
    for (int i = 0; i < bytes.length; i++) {
      final data = bytes[i];
      if (data == null) continue;
      final filePath = p.join(root.path, 'cell_$i.jpg');
      try {
        await File(filePath).writeAsBytes(data, flush: false);
        result[i] = filePath;
      } catch (e) {
        debugPrint("셀 이미지 저장 실패(idx=$i): $e");
      }
    }
    return result;
  }

  // subdir 단위로 셀 이미지 파일들을 폐기.
  Future<void> _deleteCellImageDir(String subdir) async {
    final paths = await _getFilePaths();
    final dir = Directory(p.join(paths['imagesDir']!, subdir));
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint("이미지 디렉토리 삭제 실패($subdir): $e");
    }
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
      // 손 추적은 카메라 켜진 동안 항상 돌고 있다 — 촬영 시작 직후 인페인팅에
      // 그 결과(_handResult)를 즉시 써야 하므로 여기서 *지우지 않는다*.
      // _lastHandDetectionAt도 그대로 두어 throttle이 자연스럽게 이어진다.
      _bookBox = null;
      _captureStatus = _CaptureStatus.motion;
      _lastOcrFullText = null;
      _rereadShowAllCollected = false;
      // 손 래치(추적 유지)도 그대로 — 현재 카메라 상태를 반영.
      _resetBandCollection();
    });
    // 새 세션 시작 — 외부 대시보드도 빈 칸으로 초기화.
    _dashboard.reset();

    // 촬영 시작 시 사진 한 장으로 책 테두리 박스를 1회 검출한다.
    await _detectBookBoxOnce();

    await _ensureImageStreamRunning();
  }

  // 촬영 시작 시 사진 한 장으로 책 테두리 박스를 1회 검출해 세션 내내 고정한다.
  // 손 추적은 카메라가 켜진 순간부터 백그라운드로 돌고 있으므로 _handResult가
  // 이미 채워져 있다(없으면 손이 그 시점에 안 보인 것). 그 손 위치를 인페인팅에
  // 사용해 박스가 손 따라 늘어나는 걸 막는다.
  Future<void> _detectBookBoxOnce() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      // ① 백그라운드 손 추적의 최신 결과를 그대로 사용.
      final handBoxes = _handResult?.boxes ?? const <HandBox>[];
      final handRegions = handBoxes
          .map((b) => Rect.fromLTRB(b.left, b.top, b.right, b.bottom))
          .toList();

      // ② takePicture는 스트림이 멈춰 있어야 하므로 잠깐 멈춤.
      final wasStreaming = _isImageStreamActive;
      if (wasStreaming) {
        await _stopImageStream();
      }
      final photo = await _controller!.takePicture();
      if (wasStreaming && mounted) {
        await _ensureImageStreamRunning();
      }

      // ③ 손 영역 인페인팅 후 기존 알고리즘으로 책 박스 검출.
      final box = _bookBoxService.detectWithHandMask(photo.path, handRegions);

      if (!mounted) return;
      setState(() => _bookBox = box);
      if (box == null) {
        debugPrint("책 테두리를 찾지 못했습니다.");
      } else {
        debugPrint(
          "책 테두리 박스 검출 완료: $box "
          "(손 박스 ${handRegions.length}개 인페인팅)",
        );
      }
    } catch (e) {
      debugPrint("책 박스 검출 오류: $e");
    }
  }

  Future<void> _stopAutoCapture() async {
    if (!_isAutoMode) return;

    // 스트림은 그대로 유지(손 추적은 카메라 켜진 동안 항상 돌게 함).
    // 자동 캡처 로직만 비활성화.

    // 진행 중인 띠 수집이 있으면 미확인 버퍼로 보존 — 다시 촬영 시작 시
    // 같은 페이지면 좌상단 매칭으로 이어서 수집 가능(D 케이스).
    await _demoteToPending();

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
    final now = DateTime.now();

    // 손 감지는 카메라가 켜져 있는 동안 *항상* 실행한다(촬영 시작 전에도).
    // 그래야 촬영 시작 시점에 손 위치를 즉시 알 수 있어 책 박스 검출에 활용.
    _maybeRunHandDetection(image, now);

    // 캡처/움직임 로직은 자동 촬영 모드에서만.
    if (!_isAutoMode || _isCaptureBusy || _isProcessingAnalysis) return;

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
      "게이트박스 ${_effectiveHandBoxes().length}개, "
      "최신감지 detected=${hand.detected} boxes=${hand.boxes.length}.",
    );
    // 단일 경로 — 손이 본문을 가렸든 아니든 8분할 경로로 수집한다.
    // 손이 본문에 안 닿으면 한 캡처에서 8셀 모두 채워져 즉시 완성된다.
    // 직전 캡처로부터 쿨다운(2초)을 적용해 같은 페이지에서 과한 호출을 막는다.
    if (_lastCaptureAt != null &&
        now.difference(_lastCaptureAt!) < _captureCooldownDuration) {
      _setCaptureStatus(_CaptureStatus.motion);
      return;
    }
    await _collectCleanBands();
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
  // B 케이스(재독 직후)에는 다음 새 페이지가 들어올 때까지 모두 ●로 표시한다.
  List<bool> _cellCollectedView() {
    if (_rereadShowAllCollected) {
      return List<bool>.filled(_cellLines.length, true);
    }
    return [
      for (int i = 0; i < _cellLines.length; i++)
        _cellLines[i] != null || _pendingCellImages[i] != null,
    ];
  }

  // 셀 OCR 결과(_VisionLine 리스트)를 표시용 텍스트로 합친다(대시보드 등에 사용).
  String _cellText(List<_VisionLine> lines) {
    return lines
        .map((l) => l.text.trim())
        .where((t) => t.isNotEmpty)
        .join('\n');
  }

  // 명령 3: 셀 수집 상태를 초기화한다(새 페이지 시작/완성/전체촬영 시).
  // 대시보드는 *동기화하지 않는다* — 페이지가 완성된 뒤에도 결과를 계속 보여줘야 하고,
  // 다음 페이지의 새 이미지가 푸시될 때 자연히 칸별로 덮어쓰임. 명시적 reset은
  // 새 세션 시작(_startAutoCapture) 시점에만 한다.
  void _resetBandCollection() {
    for (int i = 0; i < _cellLines.length; i++) {
      _cellLines[i] = null;
      _pendingCellImages[i] = null;
      _cellImageBytes[i] = null;
    }
    _bandPageFingerprint = null;
  }

  // 현재 수집 중인 진행 버퍼(_cellLines + _cellImageBytes + _bandPageFingerprint)를
  // 미확인 버퍼에 임시 저장한다. 셀 이미지는 디스크에 쓰고 경로만 메모리에 보관.
  // 다음 좌상단 OCR이 이 지문과 매칭되면 _restoreFromPending으로 복원해 이어서 수집.
  Future<void> _demoteToPending() async {
    // 페이지가 바뀌었으므로 B 케이스 시각화(8칸 ●) 해제.
    if (_rereadShowAllCollected && mounted) {
      setState(() => _rereadShowAllCollected = false);
    }
    final fp = _bandPageFingerprint;
    if (fp == null || fp.isEmpty) return;
    final hasAnyData =
        _cellLines.any((c) => c != null) ||
        _cellImageBytes.any((b) => b != null);
    if (!hasAnyData) return;
    final id = 'pending_${DateTime.now().millisecondsSinceEpoch}';
    final savedPaths = await _saveCellImagesToDisk(_cellImageBytes, id);
    final snapshot = List<List<_VisionLine>?>.from(_cellLines);
    final pending = _PendingPage(
      id: id,
      fingerprint: List<String>.from(fp),
      cellLines: snapshot,
      cellImagePaths: savedPaths,
      createdAt: DateTime.now(),
    );
    _pendingPages.add(pending);
    // FIFO — 초과분(가장 오래된 것)을 디스크째 폐기.
    while (_pendingPages.length > _pendingBufferLimit) {
      final dropped = _pendingPages.removeAt(0);
      await _deleteCellImageDir(dropped.id);
      debugPrint("미확인 버퍼 초과 — ${dropped.id} 폐기.");
    }
    debugPrint(
      "미확인 버퍼에 임시 저장 — id=$id, 진행 ${snapshot.where((c) => c != null).length}/8칸. "
      "현재 ${_pendingPages.length}/$_pendingBufferLimit개 보관.",
    );
  }

  // 현재 좌상단 지문과 매칭되는 미확인 페이지 반환(가장 최근 것 우선). 없으면 null.
  _PendingPage? _matchPendingPage(List<String> currentFp) {
    if (_pendingPages.isEmpty || currentFp.length < _fingerprintLineCount) {
      return null;
    }
    _PendingPage? best;
    double bestSim = 0;
    // 최근 것 우선 — 같은 유사도면 더 최근 것을 채택.
    for (int i = _pendingPages.length - 1; i >= 0; i--) {
      final cand = _pendingPages[i];
      final sim = _fingerprintSimilarity(currentFp, cand.fingerprint);
      if (sim >= _rereadSimThreshold && sim > bestSim) {
        bestSim = sim;
        best = cand;
      }
    }
    return best;
  }

  // 미확인 페이지를 현재 진행 버퍼로 복원하고 미확인 목록에서 제거(디스크 이미지는 유지).
  Future<void> _restoreFromPending(_PendingPage pending) async {
    _bandPageFingerprint = List<String>.from(pending.fingerprint);
    if (_rereadShowAllCollected && mounted) {
      setState(() => _rereadShowAllCollected = false);
    }
    // 대시보드도 미확인 시점 상태로 복원 — 이전 페이지 잔상 제거 후 셀 이미지/텍스트 push.
    _dashboard.reset();
    for (int i = 0; i < _cellLines.length; i++) {
      _cellLines[i] = pending.cellLines[i];
      _pendingCellImages[i] = null;
      // 디스크 이미지를 메모리로 다시 로드(_commitSpread에서 디스크 재저장에 사용).
      final path = pending.cellImagePaths[i];
      Uint8List? bytes;
      if (path != null) {
        try {
          final f = File(path);
          if (await f.exists()) bytes = await f.readAsBytes();
        } catch (e) {
          debugPrint("미확인 셀 이미지 로드 실패(idx=$i): $e");
        }
      }
      _cellImageBytes[i] = bytes;
      // 대시보드 셀 상태 복원: 이미지 있으면 push, OCR 결과 있으면 텍스트도 push.
      if (bytes != null) _dashboard.pushImage(i, bytes);
      final cellLines = pending.cellLines[i];
      if (cellLines != null && cellLines.isNotEmpty) {
        _dashboard.pushText(i, _cellText(cellLines));
      }
    }
    _pendingPages.remove(pending);
    await _deleteCellImageDir(pending.id);
    debugPrint(
      "미확인 ${pending.id} 복원 — ${_cellLines.where((c) => c != null).length}/8칸 이어서 수집.",
    );
  }

  // B 케이스(재독) — 저장된 페이지의 셀 이미지를 대시보드에 표시.
  // 디스크 경로가 있는 셀만 이미지로 push. 좌상단엔 페이지 번호 라벨도 push.
  Future<void> _pushStoredPageToDashboard(_StoredPage page) async {
    // 이전 페이지 잔상을 모두 비우고 저장된 페이지로 새로 채운다.
    _dashboard.reset();
    for (int i = 0; i < page.cellImagePaths.length; i++) {
      final path = page.cellImagePaths[i];
      if (path == null) continue;
      try {
        final f = File(path);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          _dashboard.pushImage(i, bytes);
        }
      } catch (e) {
        debugPrint("저장 페이지 셀 이미지 푸시 실패(idx=$i): $e");
      }
    }
    final label =
        '📖 ${page.leftNumber}-${page.rightNumber}P (재독)';
    _dashboard.pushText(0, label);
  }

  // 새 페이지가 _pageStore에 commit될 때 같은 지문의 미확인 항목을 정리.
  Future<void> _evictMatchingPending(List<String> fingerprint) async {
    if (_pendingPages.isEmpty || fingerprint.isEmpty) return;
    final toRemove = <_PendingPage>[];
    for (final cand in _pendingPages) {
      final sim = _fingerprintSimilarity(fingerprint, cand.fingerprint);
      if (sim >= _rereadSimThreshold) toRemove.add(cand);
    }
    for (final cand in toRemove) {
      _pendingPages.remove(cand);
      await _deleteCellImageDir(cand.id);
      debugPrint("미확인 ${cand.id} → 페이지 저장소로 승격, 미확인에서 제거.");
    }
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
      // 대시보드: 좌상단 캡처 이미지를 일단 표시(OCR 끝나면 텍스트로 교체됨).
      _dashboard.pushImage(0, topLeftCrop);
      _cellImageBytes[0] ??= topLeftCrop;
      final topLeftLines = await _ocrLines(topLeftCrop);
      final currentFp = _buildFingerprintLines(topLeftLines, const []);

      bool isStage1 = _bandPageFingerprint == null;
      if (!isStage1 &&
          currentFp.isNotEmpty &&
          _fingerprintSimilarity(currentFp, _bandPageFingerprint!) <
              _rereadSimThreshold) {
        // 페이지가 바뀜 → 진행 중 버퍼를 미확인으로 옮기고 새 페이지로 시작.
        // 대시보드도 비우고 이 캡처의 좌상단 이미지를 다시 push("같이 찍힌 셀 제외하고 비움").
        debugPrint("수집 중 페이지 넘김 감지 — 미확인 버퍼로 옮김.");
        await _demoteToPending();
        _resetBandCollection();
        _dashboard.reset();
        _dashboard.pushImage(0, topLeftCrop);
        isStage1 = true;
      }

      if (isStage1) {
        // stage 1: 매칭 우선순위 = 미확인 버퍼 → 저장된 페이지(재독) → 새 페이지.
        if (currentFp.length >= _fingerprintLineCount) {
          // (1) 미확인 버퍼 매칭 — 같은 페이지를 이전에 잠시 본 적 있으면 복원.
          final pending = _matchPendingPage(currentFp);
          if (pending != null) {
            await _restoreFromPending(pending);
            isStage1 = false; // _bandPageFingerprint 복원됨, 이어서 수집 진행.
          }
        }
        // (2) 미확인 매칭 실패 시 저장된 페이지(재독) 검사.
        if (isStage1 && currentFp.length >= _fingerprintLineCount) {
          final stored = _matchStoredPage(currentFp);
          if (stored != null) {
            // 데모용: 재독이라 OCR은 생략하지만 셀 이미지 자체는 대시보드에
            // 푸시해서 시각화가 끊기지 않게 한다(추가 Vision API 호출 0건).
            _dashboard.pushText(0, _cellText(topLeftLines));
            for (int row = 0; row < _bandCount; row++) {
              final (bandTop, bandBottom) = _bandBounds(row);
              final cropTop = bandTop - overlap;
              final cropBottom = bandBottom + overlap;
              for (int col = 0; col < 2; col++) {
                final idx = row * 2 + col;
                if (idx == 0) continue; // 좌상단은 위에서 이미 푸시됨
                if (coverage[idx]) continue; // 손에 가려진 칸은 스킵
                final left = col == 0 ? box.left : spine;
                final right = col == 0 ? spine : box.right;
                final crop = _cropEncode(
                  oriented,
                  cropTop,
                  cropBottom,
                  left,
                  right,
                );
                _dashboard.pushImage(idx, crop);
              }
            }
            _handleProbeReread(stored);
            _resetBandCollection();
            // B 케이스: 다음 새 페이지가 들어올 때까지 디버그 패널 8칸을 ●로 유지.
            // 또한 저장된 페이지의 셀 이미지를 대시보드에 표시(시각화 끊김 방지).
            await _pushStoredPageToDashboard(stored);
            if (mounted) setState(() => _rereadShowAllCollected = true);
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
        // 새 페이지로 확정 — B 케이스 시각화는 여기서 해제.
        // 미확인 매칭(isStage1=false)이 아닌 진짜 새 페이지 진입이면 대시보드도
        // 이전 페이지 잔상을 비우고 이 캡처의 좌상단 이미지로 다시 시작.
        if (isStage1) {
          _dashboard.reset();
          _dashboard.pushImage(0, topLeftCrop);
        }
        _bandPageFingerprint = currentFp;
        if (_rereadShowAllCollected && mounted) {
          setState(() => _rereadShowAllCollected = false);
        }
      }

      // 좌상단 OCR 결과 저장(아직 없거나 비어 있던 자리에 더 풍부한 OCR이면 갱신).
      final stored = _cellLines[0];
      if (stored == null || (stored.isEmpty && topLeftLines.isNotEmpty)) {
        _cellLines[0] = topLeftLines;
      }
      // 대시보드: 좌상단 이미지를 OCR 텍스트로 교체.
      _dashboard.pushText(0, _cellText(topLeftLines));

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
          final crop = _cropEncode(
            oriented,
            cropTop,
            cropBottom,
            left,
            right,
          );
          _pendingCellImages[idx] = crop;
          _cellImageBytes[idx] = crop;
          // 대시보드: 새로 수집된 칸의 이미지를 즉시 표시.
          _dashboard.pushImage(idx, crop);
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
            // 대시보드: 이미지였던 칸을 OCR 텍스트로 교체.
            _dashboard.pushText(pendingIdxs[k], _cellText(results[k]));
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

    // 페이지 번호 추출용 셀별 데이터 — 1행 좌/우(위쪽 6줄), 4행 좌/우(아래쪽 6줄).
    // _resetBandCollection 호출 전에 스냅샷을 떠 _commitSpread에 넘긴다.
    final leftTopCell = _cellLines[0] ?? const <_VisionLine>[];
    final rightTopCell = _cellLines[1] ?? const <_VisionLine>[];
    final leftBottomCell = _cellLines[6] ?? const <_VisionLine>[];
    final rightBottomCell = _cellLines[7] ?? const <_VisionLine>[];

    // 8칸 합쳐진 전체 OCR 텍스트를 대시보드에 push("전체 OCR 보기" 버튼 활성화).
    // image=null로 보내 이전 페이지의 전체 캡처 사진이 남아 있던 경우를 비운다 — 자동 모드 전환은 하지 않음.
    final leftText = _cellText(leftMerged);
    final rightText = _cellText(rightMerged);
    final full = [leftText, rightText].where((t) => t.trim().isNotEmpty).join('\n\n');
    if (full.trim().isNotEmpty) {
      _dashboard.pushFullPage(image: null, text: full);
    }

    _resetBandCollection();
    // 한 페이지 완성 — 다음 페이지로 넘기는 움직임을 기다린다.
    _awaitingMotionBeforeNextCapture = true;
    _stableSince = null;
    // 8칸 완성 시각화 — 다음 새 페이지가 들어올 때까지 디버그 8칸을 ●로 유지.
    if (mounted) setState(() => _rereadShowAllCollected = true);

    await _commitSpread(
      leftMerged,
      rightMerged,
      stitchFailed,
      leftTopCell: leftTopCell,
      rightTopCell: rightTopCell,
      leftBottomCell: leftBottomCell,
      rightBottomCell: rightBottomCell,
    );
  }

  // 슬라이스 1: 조립된 펼침면 한 장을 페이지 저장소에 반영한다.
  // 상단 지문으로 지금까지 읽은 모든 페이지와 비교해 재독이면 중복 저장하지 않고,
  // 새 페이지면 1행 위 6줄 / 4행 아래 6줄에서 페이지 번호를 매겨 보관한다.
  // 셀별 데이터(leftTopCell 등)는 페이지 번호 추출에 사용 — 본문 숫자 오검출 최소화.
  Future<void> _commitSpread(
    List<_VisionLine> leftLines,
    List<_VisionLine> rightLines,
    bool stitchFailed, {
    List<_VisionLine> leftTopCell = const [],
    List<_VisionLine> rightTopCell = const [],
    List<_VisionLine> leftBottomCell = const [],
    List<_VisionLine> rightBottomCell = const [],
  }) async {
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
        // 더 선명한 이미지로 셀 이미지 디스크도 교체.
        final fresh = await _saveCellImagesToDisk(
          _cellImageBytes,
          'page_${hit.rightNumber}',
        );
        for (int i = 0; i < fresh.length; i++) {
          if (fresh[i] != null) hit.cellImagePaths[i] = fresh[i];
        }
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

    // 새 페이지 — 1행 위 6줄 / 4행 아래 6줄에서만 페이지 번호 후보 추출(셀별).
    final resolved = _resolvePageNumbers(
      leftTopCell,
      rightTopCell,
      leftBottomCell,
      rightBottomCell,
    );
    final leftNumber = resolved.left;
    final rightNumber = resolved.right;
    final numberConfirmed = resolved.confirmed;

    // 셀 이미지 디스크 저장(B 케이스 시각화에 사용).
    final savedPaths = await _saveCellImagesToDisk(
      _cellImageBytes,
      'page_$rightNumber',
    );

    final page = _StoredPage(
      leftNumber: leftNumber,
      rightNumber: rightNumber,
      numberConfirmed: numberConfirmed,
      leftText: leftText,
      rightText: rightText,
      topLines: fingerprint,
      quality: quality,
      cellImagePaths: savedPaths,
    );
    _pageStore.add(page);
    _registerTopLines(fingerprint);
    // 이 페이지를 가리키는 미확인 버퍼 항목이 있었다면 제거(디스크도 정리).
    await _evictMatchingPending(fingerprint);
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

  // 페이지 번호 위치 락 — 'top'(1행 위 6줄) 또는 'bottom'(4행 아래 6줄).
  // 5회 연속 같은 위치에서 검출되면 락 → 이후 그 위치만 검사. 락 위치에서
  // 3회 연속 못 찾으면 해제 → 양쪽 다시 검사. 잘못된 락 회복 가능.
  String? _pageLocationLock;
  String? _pageLocationVoteFor;
  int _pageLocationVoteCount = 0;
  int _pageLocationMissCount = 0;
  static const int _pageLocationLockVotes = 5;
  static const int _pageLocationUnlockMisses = 3;

  // 라인 리스트에서 페이지 번호 후보 숫자를 뽑는다(중복 제거·정렬).
  // 본문 문단(어절 많은 긴 줄)과 'N .' 코드 줄번호 줄은 거른다.
  List<int> _extractNumberCandidatesFromLines(List<_VisionLine> lines) {
    if (lines.isEmpty) return const [];
    final codeLineNumber = RegExp(r'^\d{1,3}\s*\.\s*$');
    final number = RegExp(r'\d{1,4}');
    final cands = <int>{};
    for (final line in lines) {
      final text = line.text.trim();
      if (text.isEmpty || codeLineNumber.hasMatch(text)) continue;
      final tokenCount = text
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .length;
      if (tokenCount > _pageNumberMaxTokens) continue;
      for (final m in number.allMatches(text)) {
        final n = int.parse(m.group(0)!);
        if (n > 0 && n < 10000) cands.add(n);
      }
    }
    final list = cands.toList()..sort();
    return list;
  }

  // 페이지의 한 쪽(좌 or 우)에서 페이지 번호 후보를 위치(top/bottom)별로 모은다.
  // 락이 걸려 있으면 해당 위치만 검사. 결과는 (top후보들, bottom후보들).
  ({List<int> top, List<int> bottom}) _extractPageCandidatesByLocation(
    List<_VisionLine> topCell,
    List<_VisionLine> bottomCell,
  ) {
    final topSlice = topCell.length <= _pageNumberSearchLines
        ? topCell
        : topCell.sublist(0, _pageNumberSearchLines);
    final bottomSlice = bottomCell.length <= _pageNumberSearchLines
        ? bottomCell
        : bottomCell.sublist(bottomCell.length - _pageNumberSearchLines);
    final topCands = _pageLocationLock == 'bottom'
        ? const <int>[]
        : _extractNumberCandidatesFromLines(topSlice);
    final bottomCands = _pageLocationLock == 'top'
        ? const <int>[]
        : _extractNumberCandidatesFromLines(bottomSlice);
    return (top: topCands, bottom: bottomCands);
  }

  // 페이지 번호가 채택된 후, 그 번호가 어느 위치(top/bottom)에서 왔는지에 따라
  // 락/락해제 상태를 갱신한다.
  void _updatePageLocationLock(String? observed) {
    if (observed == null) {
      // 양쪽 어디서도 못 찾음 — 락 상태면 miss 누적, 해제 임계 도달 시 락 풀기.
      if (_pageLocationLock != null) {
        _pageLocationMissCount++;
        debugPrint(
          "페이지 번호 위치 락($_pageLocationLock) miss "
          "$_pageLocationMissCount/$_pageLocationUnlockMisses.",
        );
        if (_pageLocationMissCount >= _pageLocationUnlockMisses) {
          debugPrint("페이지 번호 위치 락 해제 — 양쪽 다시 검사.");
          _pageLocationLock = null;
          _pageLocationVoteFor = null;
          _pageLocationVoteCount = 0;
          _pageLocationMissCount = 0;
        }
      } else {
        _pageLocationVoteFor = null;
        _pageLocationVoteCount = 0;
      }
      return;
    }
    // 검출 성공 — miss 카운트 리셋.
    _pageLocationMissCount = 0;
    if (_pageLocationLock != null) {
      // 락된 상태면 더 할 일 없음(같은 위치에서 계속 찾는 게 정상).
      return;
    }
    if (_pageLocationVoteFor == observed) {
      _pageLocationVoteCount++;
    } else {
      _pageLocationVoteFor = observed;
      _pageLocationVoteCount = 1;
    }
    if (_pageLocationVoteCount >= _pageLocationLockVotes) {
      _pageLocationLock = observed;
      debugPrint("페이지 번호 위치 락 — $observed (연속 $_pageLocationVoteCount회).");
    }
  }

  // ── 페이지 번호 확정 ──────────────────────────────────────────────
  // 좌·우 페이지 하단에서 후보 숫자들을 모두 수집한 뒤, 카운트별 결정 트리:
  //   · N=0 : 앵커+1, +2 폴백
  //   · N=1 : 앵커 근방이면 채택+짝 유도, 아니면 폴백
  //   · N=2 : 연속쌍이면 채택, 아니면 앵커와 일치하는 쪽 채택, 아니면 폴백
  //   · N≥3 : 연속쌍 우선(여럿이면 앵커 매치/근접도로 깸), 없으면 폴백
  // 페이지 번호의 본질적 속성(좌·우는 항상 n, n+1)을 직접 활용해 본문/각주의
  // 잡음 숫자를 자연스럽게 거른다.

  // 패리티 락에 필요한 연속 일치 횟수.
  static const int _parityLockMinVotes = 5;
  // N==1, N==2에서 후보가 '앵커 근방'인지 볼 허용 오차.
  static const int _pageAnchorTolerance = 3;

  // 페이지 패리티 락 상태(이 책의 펼침면이 짝-홀인지 홀-짝인지).
  _PageParity? _parityLock;
  _PageParity? _parityRunType;
  int _parityRunCount = 0;

  _PageParity _parityOf(int left) =>
      left.isEven ? _PageParity.evenOdd : _PageParity.oddEven;

  // 앵커(_lastCommittedRight)를 전진시킨다 — 뒤로 돌아간 곁다리가 앵커를
  // 끌어내리지 않도록 max로만 갱신한다.
  void _advanceAnchor(int right) {
    _lastCommittedRight = _lastCommittedRight == null
        ? right
        : math.max(_lastCommittedRight!, right);
  }

  // 패리티 학습 — 깨끗한(연속쌍 + 앵커 근방=confirmed) reading일 때만 카운트.
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

  bool _isNearAnchor(int v, int expected) =>
      (v - expected).abs() <= _pageAnchorTolerance;

  // v 한 값에서 좌·우 짝 유도. v가 좌(expectedL)에 더 가까우면 (v, v+1),
  // 우(expectedR)에 더 가까우면 (v-1, v)로.
  ({int left, int right, bool confirmed}) _derivePairFromOne(
    int v,
    int expectedL,
    int expectedR,
  ) {
    final distL = (v - expectedL).abs();
    final distR = (v - expectedR).abs();
    return distL <= distR
        ? (left: v, right: v + 1, confirmed: true)
        : (left: v - 1, right: v, confirmed: true);
  }

  // 정렬된 후보 리스트에서 연속쌍 (n, n+1)을 모두 찾고, 그중 앵커와 가장
  // 잘 맞는 쌍을 돌려준다. 연속쌍이 하나도 없으면 null.
  ({int left, int right, bool confirmed})? _findBestConsecutivePair(
    List<int> sorted,
    int expectedL,
    int expectedR,
  ) {
    final set = sorted.toSet();
    final pairs = <(int, int)>[];
    for (final v in sorted) {
      if (set.contains(v + 1)) pairs.add((v, v + 1));
    }
    if (pairs.isEmpty) return null;
    // 1순위 — 기대값과 정확히 일치하는 쌍
    for (final p in pairs) {
      if (p.$1 == expectedL && p.$2 == expectedR) {
        return (left: p.$1, right: p.$2, confirmed: true);
      }
    }
    // 2순위 — 기대값과 가장 가까운 쌍
    pairs.sort((a, b) =>
        (a.$1 - expectedL).abs().compareTo((b.$1 - expectedL).abs()));
    final best = pairs.first;
    final near = _isNearAnchor(best.$2, expectedR);
    return (left: best.$1, right: best.$2, confirmed: near);
  }

  // 앵커 없음(부트스트랩, 첫 페이지) 경로.
  ({int left, int right, bool confirmed}) _resolveBootstrap(
    List<int> leftCands,
    List<int> rightCands,
    List<int> all,
  ) {
    if (all.isEmpty) return (left: 1, right: 2, confirmed: false);
    // 좌·우 교차 연속쌍 우선(좌에 l, 우에 l+1 동시 존재).
    for (final l in leftCands) {
      if (rightCands.contains(l + 1)) {
        return (left: l, right: l + 1, confirmed: true);
      }
    }
    // 합집합 내 연속쌍.
    for (int i = 0; i < all.length - 1; i++) {
      if (all[i + 1] == all[i] + 1) {
        return (left: all[i], right: all[i] + 1, confirmed: true);
      }
    }
    // 단일/다중 비연속 — 가장 큰 값 기준으로 짝 유도.
    final m = all.last;
    final l = m > 1 ? m - 1 : m;
    final r = m > 1 ? m : m + 1;
    return (left: l, right: r, confirmed: true);
  }

  // 한 펼침면의 좌·우 페이지 번호를 확정한다.
  // confirmed=false면 OCR을 그대로 안 쓰고 앵커/추정으로 폴백한 결과다.
  // 셀별 데이터: 1행 좌/우(위쪽 6줄), 4행 좌/우(아래쪽 6줄)에서만 후보를 모은다.
  ({int left, int right, bool confirmed}) _resolvePageNumbers(
    List<_VisionLine> leftTopCell,
    List<_VisionLine> rightTopCell,
    List<_VisionLine> leftBottomCell,
    List<_VisionLine> rightBottomCell,
  ) {
    final leftLoc = _extractPageCandidatesByLocation(
      leftTopCell, leftBottomCell);
    final rightLoc = _extractPageCandidatesByLocation(
      rightTopCell, rightBottomCell);
    final leftCands = [...leftLoc.top, ...leftLoc.bottom];
    final rightCands = [...rightLoc.top, ...rightLoc.bottom];
    final all = ({...leftCands, ...rightCands}).toList()..sort();
    final anchor = _lastCommittedRight;

    debugPrint(
      "페이지 번호 후보 — 락=${_pageLocationLock ?? '없음'} "
      "좌(top=${leftLoc.top}, bot=${leftLoc.bottom}) "
      "우(top=${rightLoc.top}, bot=${rightLoc.bottom}) "
      "합=$all 앵커=${anchor ?? '-'}",
    );

    final result = _decidePageNumbers(leftCands, rightCands, all, anchor);

    // 패리티 학습 — 연속쌍이면서 confirmed일 때만 카운트한다(잡음 차단).
    if (result.confirmed && result.right == result.left + 1) {
      _learnParity(result.left);
    }

    // 위치 락 갱신 — 채택된 페이지 번호가 어디서 왔는지 추적.
    String? observed;
    if (result.confirmed) {
      final picked = {result.left, result.right};
      final topAll = {...leftLoc.top, ...rightLoc.top};
      final botAll = {...leftLoc.bottom, ...rightLoc.bottom};
      final fromTop = picked.intersection(topAll).isNotEmpty;
      final fromBot = picked.intersection(botAll).isNotEmpty;
      if (fromTop && !fromBot) {
        observed = 'top';
      } else if (fromBot && !fromTop) {
        observed = 'bottom';
      }
      // 양쪽 다면 모호 → 투표 안 함(observed=null이지만 confirmed라 miss 아님).
    }
    if (result.confirmed) {
      if (observed != null) _updatePageLocationLock(observed);
      // 양쪽 검출 모호한 confirmed 케이스는 락 상태 변경 없음.
    } else {
      _updatePageLocationLock(null);
    }

    debugPrint(
      "페이지 번호 확정: ${result.left}·${result.right} "
      "(confirmed=${result.confirmed}, 위치=$observed)",
    );
    return result;
  }

  ({int left, int right, bool confirmed}) _decidePageNumbers(
    List<int> leftCands,
    List<int> rightCands,
    List<int> all,
    int? anchor,
  ) {
    if (anchor == null) return _resolveBootstrap(leftCands, rightCands, all);

    final expectedL = anchor + 1;
    final expectedR = anchor + 2;

    // N == 0 : 앵커 폴백.
    if (all.isEmpty) {
      debugPrint("페이지 번호 후보 0개 → 앵커 폴백");
      return (left: expectedL, right: expectedR, confirmed: false);
    }

    // N >= 3 : 연속쌍 우선(여럿이면 앵커 매치·근접도로 깸).
    if (all.length >= 3) {
      final pair = _findBestConsecutivePair(all, expectedL, expectedR);
      if (pair != null) {
        debugPrint("페이지 번호 N≥3 연속쌍 채택: ${pair.left}·${pair.right}");
        return pair;
      }
      debugPrint("페이지 번호 N≥3 연속쌍 없음 → 앵커 폴백");
      return (left: expectedL, right: expectedR, confirmed: false);
    }

    // N == 2 : 연속쌍이면 채택, 아니면 앵커 매치 시도.
    if (all.length == 2) {
      if (all[1] == all[0] + 1) {
        final near = _isNearAnchor(all[1], expectedR);
        debugPrint(
          "페이지 번호 N=2 연속쌍 (${all[0]}, ${all[1]}) "
          "${near ? '앵커 근방' : '점프'} 채택",
        );
        return (left: all[0], right: all[1], confirmed: near);
      }
      for (final v in all) {
        if (_isNearAnchor(v, expectedL) || _isNearAnchor(v, expectedR)) {
          final pair = _derivePairFromOne(v, expectedL, expectedR);
          debugPrint(
            "페이지 번호 N=2 비연속, $v 앵커 근방 → ${pair.left}·${pair.right}",
          );
          return pair;
        }
      }
      debugPrint("페이지 번호 N=2 비연속·앵커 매치 없음 → 앵커 폴백");
      return (left: expectedL, right: expectedR, confirmed: false);
    }

    // N == 1 : 앵커 근방이면 채택+짝 유도, 아니면 폴백.
    final v = all.first;
    if (_isNearAnchor(v, expectedL) || _isNearAnchor(v, expectedR)) {
      final pair = _derivePairFromOne(v, expectedL, expectedR);
      debugPrint("페이지 번호 N=1, $v 앵커 근방 → ${pair.left}·${pair.right}");
      return pair;
    }
    debugPrint("페이지 번호 N=1, $v 앵커와 멂 → 앵커 폴백");
    return (left: expectedL, right: expectedR, confirmed: false);
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
    List<String?>? cellImagePaths,
  }) : cellImagePaths = cellImagePaths ?? List<String?>.filled(8, null);

  final int leftNumber;
  final int rightNumber;
  final bool numberConfirmed; // 페이지 번호를 OCR로 확정했는지(false=직전+N 추정)
  String leftText; // 왼쪽 페이지 본문 — 재독 시 더 선명한 사본으로 교체될 수 있음
  String rightText; // 오른쪽 페이지 본문 — 재독 시 교체될 수 있음
  final List<String> topLines; // 좌/우 상단 줄(정규화) — 재독 지문
  int quality; // OCR 품질 점수 — 재독 교체 판단
  // 8셀 이미지의 디스크 경로(row*2+col). null이면 그 칸은 저장된 이미지 없음.
  // B 케이스(재독) 시 대시보드가 이 경로로 셀 이미지를 다시 보여준다.
  final List<String?> cellImagePaths;

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
    'cellImagePaths': cellImagePaths,
  };

  static _StoredPage fromJson(Map<String, dynamic> json) {
    final paths = List<String?>.filled(8, null);
    final raw = (json['cellImagePaths'] as List?) ?? const [];
    for (int i = 0; i < raw.length && i < 8; i++) {
      paths[i] = raw[i] as String?;
    }
    return _StoredPage(
      leftNumber: (json['leftNumber'] as num?)?.toInt() ?? 0,
      rightNumber: (json['rightNumber'] as num?)?.toInt() ?? 0,
      numberConfirmed: json['numberConfirmed'] as bool? ?? false,
      leftText: json['leftText'] as String? ?? '',
      rightText: json['rightText'] as String? ?? '',
      topLines: ((json['topLines'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      quality: (json['quality'] as num?)?.toInt() ?? 0,
      cellImagePaths: paths,
    );
  }
}

// 8칸 수집 도중이지만 아직 한 페이지로 commit되지 못한 임시 페이지.
// 페이지 넘김 false-negative 회복 + 촬영 중지/재시작 보존을 위해 보관한다.
// 디스크에 셀 이미지를 저장하고 경로만 메모리에 들고 있다가, 매칭되면 복원.
class _PendingPage {
  _PendingPage({
    required this.id,
    required this.fingerprint,
    required this.cellLines,
    required this.cellImagePaths,
    required this.createdAt,
  });

  final String id; // 디렉토리 이름(예: 'pending_1700000000000')
  final List<String> fingerprint; // 페이지 ID = 좌상단 지문
  // OCR 완료된 셀(null이면 미완 — 복원 후 다음 캡처에서 채워짐)
  final List<List<_VisionLine>?> cellLines;
  final List<String?> cellImagePaths; // 디스크 경로(B 케이스 시각화)
  final DateTime createdAt;
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
