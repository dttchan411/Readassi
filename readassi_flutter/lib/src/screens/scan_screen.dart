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

import '../app_state.dart';
import '../services/claude_service.dart';
import '../services/hand_detection_service.dart';
import 'book_detail_screen.dart';
import 'scan_camera_view.dart';
import 'page_extractor.dart';

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

  final String _googleVisionApiKey = dotenv.env['_googleVisionApiKey'] ?? "";
  final String _geminiApiKey = dotenv.env['_geminiApiKey'] ?? "";
  final ClaudeService _claudeService = ClaudeService();
  final HandDetectionService _handDetectionService = HandDetectionService();

  bool _isAutoMode = false;
  _PageCandidate? _pendingPageCandidate;
  _PageCandidate? _pendingUncertainCandidate;
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

  final List<Future<void>> _ocrQueue = [];
  int _pendingOcrCount = 0;

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

  @override
  void initState() {
    super.initState();
    // 가로 모드 고정
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _initCamera();
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
        ResolutionPreset.medium,
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
      'original': p.join(
        bookDir.path,
        '${widget.bookId}_original.txt',
      ), // 원본 텍스트(분석 후 삭제됨)
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
  Future<void> _enqueueOcr(Uint8List bytes) async {
    final completer = Completer<void>();
    _ocrQueue.add(completer.future);
    setState(() => _pendingOcrCount = _ocrQueue.length);

    try {
      final text = await _getVisionText(bytes);
      final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
      final snapshot = _buildSnapshot(text, lines);
      _updateOcrSummary(snapshot);

      if (!_isUsefulOcrResult(snapshot)) {
        debugPrint("OCR 결과가 너무 짧거나 불안정해서 저장하지 않습니다.");
        return;
      }

      if (!mounted) return;
      final pageNumber = PageExtractor.extractPageNumberEnhanced(
        text,
        context,
        widget.bookId,
      );
      final currentCandidate = _PageCandidate(
        text: text,
        snapshot: snapshot,
        pageNumber: pageNumber,
        qualityScore: _calculateOcrQuality(snapshot, pageNumber),
      );

      if (_pendingPageCandidate == null) {
        _pendingPageCandidate = currentCandidate;
        _pendingUncertainCandidate = null;
        _applyCandidatePageNumber(currentCandidate);
        debugPrint("새 페이지 후보를 생성했습니다.");
        return;
      }

      final previousCandidate = _pendingPageCandidate!;

      if (_looksLikeDuplicatePage(
        previousCandidate.snapshot,
        currentCandidate.snapshot,
      )) {
        _pendingUncertainCandidate = null;
        if (_shouldReplaceCandidate(previousCandidate, currentCandidate)) {
          _pendingPageCandidate = currentCandidate;
          _applyCandidatePageNumber(currentCandidate);
          debugPrint("같은 페이지의 더 좋은 OCR 결과로 후보를 교체했습니다.");
        } else {
          debugPrint("같은 페이지로 판단되어 기존 후보를 유지합니다.");
        }
        return;
      }

      final uncertainCandidate = _pendingUncertainCandidate;
      if (uncertainCandidate != null &&
          _looksLikeDuplicatePage(
            uncertainCandidate.snapshot,
            currentCandidate.snapshot,
          )) {
        final promotedCandidate = _betterCandidate(
          uncertainCandidate,
          currentCandidate,
        );
        await _flushPendingCandidateToFile();
        _pendingPageCandidate = promotedCandidate;
        _pendingUncertainCandidate = null;
        _applyCandidatePageNumber(promotedCandidate);
        debugPrint("보류 중이던 후보가 다음 프레임으로 확인되어 새 페이지로 승격되었습니다.");
        return;
      }

      if (_looksUncertainComparedToCandidate(
        previousCandidate,
        currentCandidate,
      )) {
        _rememberUncertainCandidate(currentCandidate);
        debugPrint("손 가림 또는 저품질 프레임으로 의심되어 저장을 보류합니다.");
        return;
      }

      await _flushPendingCandidateToFile();
      _pendingPageCandidate = currentCandidate;
      _pendingUncertainCandidate = null;
      _applyCandidatePageNumber(currentCandidate);
      debugPrint("이전 페이지 후보를 저장하고 새 후보를 시작했습니다.");
    } catch (e) {
      debugPrint("OCR 처리 중 오류: $e");
    } finally {
      completer.complete();
      _ocrQueue.removeAt(0);
      if (mounted) setState(() => _pendingOcrCount = _ocrQueue.length);
    }
  }

  Future<String> _getVisionText(Uint8List bytes) async {
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

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['responses']?[0]?['fullTextAnnotation']?['text'] ?? "인식 실패";
    }
    return "텍스트 추출 실패";
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
      _handLatched = false;
      _lastHandBox = null;
      _lastHandSeenAt = null;
      _lastHandArea = 0;
      _peakHandArea = 0;
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
      await _enqueueOcr(bytes);

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
      // 손이 본문 영역(하단 여백 위쪽)을 가림 → 깨끗한 프레임이 아님.
      // 명령 2에서는 대기만 한다(겹친 프레임의 줄 단위 누적은 명령 3 범위).
      _setCaptureStatus(_CaptureStatus.handOverlap);
      return;
    }
    // 손이 검출/추적되더라도 하단 여백 영역 안에만 있으면 본문은 안 가린 것으로 본다.

    // 손이 본문과 안 겹침 → 깨끗한 프레임. 기존 Vision OCR 흐름을 진행한다.
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

  // 디버그 패널에 보여줄 최근 OCR 결과 요약을 갱신한다.
  void _updateOcrSummary(_OcrTextSnapshot snapshot) {
    final fullText = snapshot.fullText;
    final preview = fullText.length > 70
        ? '${fullText.substring(0, 70)}…'
        : fullText;
    final summary = fullText.isEmpty
        ? 'OCR 결과 없음'
        : '${snapshot.textLength}자 · ${snapshot.lineCount}줄\n$preview';
    if (!mounted) return;
    setState(() => _lastOcrSummary = summary);
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
      if (_ocrQueue.isNotEmpty) await Future.wait(_ocrQueue);
      await _flushPendingCandidateToFile();
      _pendingUncertainCandidate = null;

      final paths = await _getFilePaths();
      final originalFile = File(paths['original']!);
      final storyDbFile = File(paths['story_db']!);
      final charDbFile = File(paths['char_db']!);

      if (!await originalFile.exists()) throw Exception("스캔된 새로운 텍스트가 없습니다.");

      final String newRawText = await originalFile.readAsString();
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

      // 4. ✅ 원본 텍스트 삭제 (토큰 비용 절감 및 최적화)
      await originalFile.delete();
      debugPrint("🗑️ 분석 완료 후 원본 텍스트 파일을 삭제하였습니다.");

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

  _OcrTextSnapshot _buildSnapshot(String fullText, List<String> lines) {
    final normalizedLines = lines
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final top = normalizedLines.take(4).join('\n');
    final bottom = normalizedLines.length > 4
        ? normalizedLines.sublist(normalizedLines.length - 4).join('\n')
        : normalizedLines.join('\n');

    final middleStart = normalizedLines.length < 6
        ? 0
        : ((normalizedLines.length / 2).floor() - 2).clamp(
            0,
            normalizedLines.length - 1,
          );
    final middleEnd = normalizedLines.isEmpty
        ? 0
        : (middleStart + 4).clamp(0, normalizedLines.length);
    final middle = normalizedLines.sublist(middleStart, middleEnd).join('\n');

    final normalizedFullText = fullText.replaceAll(RegExp(r'\s+'), ' ').trim();

    return _OcrTextSnapshot(
      fullText: normalizedFullText,
      topExcerpt: top,
      middleExcerpt: middle,
      bottomExcerpt: bottom,
      lineCount: normalizedLines.length,
      textLength: normalizedFullText.length,
    );
  }

  bool _isUsefulOcrResult(_OcrTextSnapshot snapshot) {
    if (snapshot.fullText.isEmpty) return false;
    if (snapshot.fullText == "인식 실패") return false;
    if (snapshot.fullText == "텍스트 추출 실패") return false;
    if (snapshot.lineCount < 3) return false;
    if (snapshot.textLength < 40) return false;
    return true;
  }

  bool _looksLikeDuplicatePage(
    _OcrTextSnapshot previous,
    _OcrTextSnapshot current,
  ) {
    final bottomSimilarity = _calculateSimilarity(
      previous.bottomExcerpt,
      current.bottomExcerpt,
    );
    final middleSimilarity = _calculateSimilarity(
      previous.middleExcerpt,
      current.middleExcerpt,
    );
    final topSimilarity = _calculateSimilarity(
      previous.topExcerpt,
      current.topExcerpt,
    );
    final fullSimilarity = _calculateSimilarity(
      previous.fullText,
      current.fullText,
    );

    final shorterLength = previous.textLength < current.textLength
        ? previous.textLength
        : current.textLength;
    final longerLength = previous.textLength > current.textLength
        ? previous.textLength
        : current.textLength;
    final lengthRatio = longerLength == 0 ? 0.0 : shorterLength / longerLength;

    final excerptAverage =
        (bottomSimilarity * 0.45) +
        (middleSimilarity * 0.35) +
        (topSimilarity * 0.20);

    if (bottomSimilarity >= 0.88 &&
        middleSimilarity >= 0.72 &&
        lengthRatio >= 0.82) {
      return true;
    }

    if (excerptAverage >= 0.82 &&
        fullSimilarity >= 0.72 &&
        lengthRatio >= 0.85) {
      return true;
    }

    return false;
  }

  int _calculateOcrQuality(_OcrTextSnapshot snapshot, int? pageNumber) {
    final compactText = snapshot.fullText.replaceAll(RegExp(r'\s+'), '');
    final totalChars = compactText.length;
    if (totalChars == 0) return 0;

    final hangulCount = RegExp(r'[가-힣]').allMatches(compactText).length;
    final alphaNumericCount = RegExp(
      r'[가-힣A-Za-z0-9]',
    ).allMatches(compactText).length;
    final noiseCount = totalChars - alphaNumericCount;

    final hangulRatio = hangulCount / totalChars;
    final noiseRatio = noiseCount / totalChars;

    return snapshot.textLength +
        (snapshot.lineCount * 18) +
        (pageNumber != null ? 60 : 0) +
        (hangulRatio * 100).round() -
        (noiseRatio * 80).round();
  }

  bool _shouldReplaceCandidate(
    _PageCandidate previous,
    _PageCandidate current,
  ) {
    return current.qualityScore > previous.qualityScore + 25;
  }

  _PageCandidate _betterCandidate(_PageCandidate first, _PageCandidate second) {
    return _shouldReplaceCandidate(first, second) ? second : first;
  }

  bool _looksUncertainComparedToCandidate(
    _PageCandidate previous,
    _PageCandidate current,
  ) {
    final topSimilarity = _calculateSimilarity(
      previous.snapshot.topExcerpt,
      current.snapshot.topExcerpt,
    );
    final middleSimilarity = _calculateSimilarity(
      previous.snapshot.middleExcerpt,
      current.snapshot.middleExcerpt,
    );
    final bottomSimilarity = _calculateSimilarity(
      previous.snapshot.bottomExcerpt,
      current.snapshot.bottomExcerpt,
    );
    final fullSimilarity = _calculateSimilarity(
      previous.snapshot.fullText,
      current.snapshot.fullText,
    );

    final shorterLength = math.min(
      previous.snapshot.textLength,
      current.snapshot.textLength,
    );
    final longerLength = math.max(
      previous.snapshot.textLength,
      current.snapshot.textLength,
    );
    final lengthRatio = longerLength == 0 ? 0.0 : shorterLength / longerLength;

    final pageNumberMatches =
        previous.pageNumber != null &&
        current.pageNumber != null &&
        previous.pageNumber == current.pageNumber;

    final qualityDrop =
        current.qualityScore < (previous.qualityScore * 0.72).round();
    final severeBodyMismatch =
        topSimilarity >= 0.65 &&
        middleSimilarity < 0.45 &&
        bottomSimilarity < 0.45;
    final shortAndNoisy =
        current.snapshot.textLength < 140 &&
        current.snapshot.lineCount < 8 &&
        lengthRatio < 0.78;

    if (pageNumberMatches && (qualityDrop || severeBodyMismatch)) {
      return true;
    }

    if (severeBodyMismatch && (qualityDrop || shortAndNoisy)) {
      return true;
    }

    if (fullSimilarity < 0.55 && qualityDrop && shortAndNoisy) {
      return true;
    }

    return false;
  }

  void _applyCandidatePageNumber(_PageCandidate candidate) {
    if (candidate.pageNumber == null) return;
    AppStateScope.of(
      context,
    ).updateBookCurrentPage(widget.bookId, candidate.pageNumber);
  }

  void _rememberUncertainCandidate(_PageCandidate candidate) {
    final existing = _pendingUncertainCandidate;
    if (existing == null) {
      _pendingUncertainCandidate = candidate;
      return;
    }

    if (_looksLikeDuplicatePage(existing.snapshot, candidate.snapshot)) {
      _pendingUncertainCandidate = _betterCandidate(existing, candidate);
      return;
    }

    if (candidate.qualityScore > existing.qualityScore) {
      _pendingUncertainCandidate = candidate;
    }
  }

  Future<void> _flushPendingCandidateToFile() async {
    final candidate = _pendingPageCandidate;
    if (candidate == null) return;

    final paths = await _getFilePaths();
    final file = File(paths['original']!);
    if (!await file.exists()) {
      await file.create();
    }
    await file.writeAsString('${candidate.text}\n\n', mode: FileMode.append);
    _pendingPageCandidate = null;
    _pendingUncertainCandidate = null;
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
                  SizedBox(
                    width: 78,
                    child: _pendingOcrCount > 0
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orange[700],
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              "OCR $_pendingOcrCount",
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : const SizedBox(),
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
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OcrTextSnapshot {
  const _OcrTextSnapshot({
    required this.fullText,
    required this.topExcerpt,
    required this.middleExcerpt,
    required this.bottomExcerpt,
    required this.lineCount,
    required this.textLength,
  });

  final String fullText;
  final String topExcerpt;
  final String middleExcerpt;
  final String bottomExcerpt;
  final int lineCount;
  final int textLength;
}

class _PageCandidate {
  const _PageCandidate({
    required this.text,
    required this.snapshot,
    required this.pageNumber,
    required this.qualityScore,
  });

  final String text;
  final _OcrTextSnapshot snapshot;
  final int? pageNumber;
  final int qualityScore;
}

/// 자동 촬영 진행 상태(디버그 패널 표시 및 손 게이트용).
enum _CaptureStatus {
  idle, // 대기 중 (촬영 시작 전)
  motion, // 움직임 감지중 / 안정화 대기
  checkingHand, // 안정됨, 손 감지 결과 확인 중
  handOverlap, // 손이 본문과 겹침 → 대기
  capturing, // 깨끗한 프레임 → 촬영·OCR 진행 중
}
