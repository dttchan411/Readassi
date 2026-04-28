import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../app_state.dart';
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

  final String _googleVisionApiKey = dotenv.env['_googleVisionApiKey'] ?? "";
  final String _geminiApiKey = dotenv.env['_geminiApiKey'] ?? "";

  bool _isAutoMode = false;
  _OcrTextSnapshot? _lastAcceptedSnapshot;
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
  Future<_OcrProcessingResult> _enqueueOcr(Uint8List bytes) async {
    final completer = Completer<void>();
    _ocrQueue.add(completer.future);
    setState(() => _pendingOcrCount = _ocrQueue.length);

    try {
      final text = await _getVisionText(bytes);
      final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
      final snapshot = _buildSnapshot(text, lines);

      if (!_isUsefulOcrResult(snapshot)) {
        debugPrint("OCR 결과가 너무 짧거나 불안정해서 저장하지 않습니다.");
        return _OcrProcessingResult.ignored;
      }

      // 동일 페이지 스캔 방지
      if (_lastAcceptedSnapshot != null &&
          _looksLikeDuplicatePage(_lastAcceptedSnapshot!, snapshot)) {
        debugPrint("동일 페이지로 판단되어 저장하지 않습니다.");
        return _OcrProcessingResult.duplicate;
      }

      // 원본 텍스트 파일에 추가
      final paths = await _getFilePaths();
      final file = File(paths['original']!);
      if (!await file.exists()) await file.create();
      await file.writeAsString('$text\n\n', mode: FileMode.append);

      _lastAcceptedSnapshot = snapshot;

      // 페이지 번호 검출
      final pageNumber = PageExtractor.extractPageNumberEnhanced(
        text,
        context,
        widget.bookId,
      );
      if (pageNumber != null) {
        AppStateScope.of(
          context,
        ).updateBookCurrentPage(widget.bookId, pageNumber);
      }
      return _OcrProcessingResult.accepted;
    } catch (e) {
      debugPrint("OCR 처리 중 오류: $e");
      return _OcrProcessingResult.error;
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
        _isProcessingAnalysis)
      return;

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
    });

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("자동 촬영을 멈췄습니다. 분석을 눌러 결과를 반영하세요.")));
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
      return;
    }

    if (_awaitingMotionBeforeNextCapture) return;

    _stableSince ??= now;

    final stableDuration = now.difference(_stableSince!);
    final cooldownFinished =
        _lastCaptureAt == null ||
        now.difference(_lastCaptureAt!) >= _captureCooldownDuration;

    if (cooldownFinished && stableDuration >= _stabilityRequiredDuration) {
      await _captureSinglePage();
    }
  }

  List<int> _buildFrameSignature(CameraImage image) {
    if (image.planes.isEmpty) return const [];
    final bytes = image.planes.first.bytes;
    if (bytes.isEmpty) return const [];

    final step = math.max(1, bytes.length ~/ _lumaSampleCount);
    final signature = <int>[];
    for (int i = 0; i < bytes.length && signature.length < _lumaSampleCount; i += step) {
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

    try {
      if (_ocrQueue.isNotEmpty) await Future.wait(_ocrQueue);

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
      final appState = AppStateScope.of(context);

      // UI용 요약문
      appState.updateBookSummary(widget.bookId, result['ui_summary'] ?? "");

      // UI용 캐릭터 목록
      if (result['ui_characters'] != null) {
        final rawCharacters = result['ui_characters'];
        if (rawCharacters is List) {
          appState.updateBookCharacters(widget.bookId, rawCharacters);
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
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("업데이트 실패: $e")));
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
4. ui_characters: 앱의 인물 탭에 리스트로 보여줄 데이터입니다. 형식: [{"name": "이름", "role": "역할", "description": "설명"}]
5. ui_characters에는 실제 등장인물만 넣으세요. 다음은 넣지 마세요:
   - 군중, 주민들, 학생들, 사람들 같은 집단 표현
   - 화자, 서술자, 주인공, 누군가, 친구 같은 일반 명사
   - 직책이나 관계만 있고 고유하게 식별되지 않는 표현
   - 장소, 단체, 개념, 사물
6. 이름이 분명하지 않으면 억지로 넣지 말고 제외하세요.
7. 한 번만 스쳐 지나가는 일반 호칭보다, 이야기에서 실제 인물로 추적 가능한 대상만 남기세요.

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

enum _OcrProcessingResult {
  accepted,
  duplicate,
  ignored,
  error,
}
