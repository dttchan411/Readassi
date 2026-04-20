import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

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
  final String _googleVisionApiKey = dotenv.env['_googleVisionApiKey'] ?? "";
  final String _geminiApiKey = dotenv.env['_geminiApiKey'] ?? "";

  Timer? _autoScanTimer;
  bool _isAutoMode = false;
  String _referenceText = "";

  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isAnalyzing = false;

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
    _autoScanTimer?.cancel();
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
      final currentBottom5 = lines.length > 5
          ? lines.sublist(lines.length - 5).join("\n")
          : text;

      // 동일 페이지 스캔 방지
      if (_referenceText.isNotEmpty) {
        double similarity = _calculateSimilarity(
          _referenceText,
          currentBottom5,
        );
        if (similarity >= 0.5) return;
      }

      // 원본 텍스트 파일에 추가
      final paths = await _getFilePaths();
      final file = File(paths['original']!);
      if (!await file.exists()) await file.create();
      await file.writeAsString('$text\n\n', mode: FileMode.append);

      _referenceText = currentBottom5;

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

  Future<void> _takePictureAndProcess() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isAnalyzing)
      return;

    if (!_isAutoMode) {
      setState(() => _isAutoMode = true);
      _autoScanTimer = Timer.periodic(const Duration(seconds: 8), (
        timer,
      ) async {
        if (!_isAnalyzing) await _takePictureAndProcess();
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("자동 촬영을 시작합니다.")));
    }

    setState(() => _isAnalyzing = true);
    try {
      final photo = await _controller!.takePicture();
      final bytes = await File(photo.path).readAsBytes();
      _enqueueOcr(bytes);
    } catch (e) {
      debugPrint("촬영 오류: $e");
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  // --- 데이터 통합 업데이트 로직 (핵심) ---
  Future<void> _performUpdate() async {
    if (_isAnalyzing) return;
    if (_isAutoMode) {
      _autoScanTimer?.cancel();
      setState(() => _isAutoMode = false);
    }
    setState(() => _isAnalyzing = true);

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
      if (mounted) setState(() => _isAnalyzing = false);
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
                isAnalyzing: _isAnalyzing,
                onUpdatePressed: _performUpdate,
                onCapturePressed: _takePictureAndProcess,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
