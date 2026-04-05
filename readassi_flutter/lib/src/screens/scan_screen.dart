import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../app_state.dart';
import 'book_detail_screen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

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
  int _topHitCount = 0;
  int _bottomHitCount = 0;
  String? _lockedLocation;

  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isAnalyzing = false;

  double _minZoomLevel = 1.0;
  double _maxZoomLevel = 1.0;
  double _currentZoomLevel = 1.0;
  double _baseZoomLevel = 1.0;

  final List<Future<void>> _ocrQueue = [];
  int _pendingOcrCount = 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    _initCamera();
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _autoScanTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      _controller = CameraController(cameras.first, ResolutionPreset.medium, enableAudio: false);
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

  Future<String> _getOriginalTextFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    final bookDir = Directory(p.join(dir.path, 'books'));
    await bookDir.create(recursive: true);
    return p.join(bookDir.path, '${widget.bookId}_original.txt');
  }

  Future<void> _enqueueOcr(Uint8List bytes) async {
    final completer = Completer<void>();
    _ocrQueue.add(completer.future);
    setState(() => _pendingOcrCount = _ocrQueue.length);

    try {
      final text = await _getVisionText(bytes);
      final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
      final currentBottom5 = lines.length > 5 ? lines.sublist(lines.length - 5).join("\n") : text;

      if (_referenceText.isNotEmpty) {
        double similarity = _calculateSimilarity(_referenceText, currentBottom5);
        debugPrint("현재 페이지 유사도 검출 결과: $similarity");
        if (similarity >= 0.5) {
          debugPrint("같은 페이지로 판단되어 스킵합니다.");
          return;
        }
      }

      await _appendToOriginalText(text);
      _referenceText = currentBottom5;

      final pageNumber = PageExtractor.extractPageNumberEnhanced(text, context, widget.bookId);
      if (pageNumber != null) {
        AppStateScope.of(context).updateBookCurrentPage(widget.bookId, pageNumber);
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
      Uri.parse('https://vision.googleapis.com/v1/images:annotate?key=$_googleVisionApiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'requests': [
          {
            'image': {'content': base64Image},
            'features': [{'type': 'DOCUMENT_TEXT_DETECTION'}],
            'imageContext': {'languageHints': ['ko']},
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

  Future<void> _appendToOriginalText(String newText) async {
    final file = File(await _getOriginalTextFilePath());
    if (!await file.exists()) await file.create();
    await file.writeAsString('$newText\n\n', mode: FileMode.append);
  }

  Future<void> _takePictureAndProcess() async {
    if (_controller == null || !_controller!.value.isInitialized || _isAnalyzing) return;

    if (!_isAutoMode) {
      setState(() => _isAutoMode = true);
      _autoScanTimer = Timer.periodic(const Duration(seconds: 8), (timer) async {
        if (!_isAnalyzing) await _takePictureAndProcess();
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("자동 촬영을 시작합니다.")));
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

  Future<void> _performUpdate() async {
    if (_isAnalyzing) return;
    if (_isAutoMode) {
      _autoScanTimer?.cancel();
      setState(() => _isAutoMode = false);
    }
    setState(() => _isAnalyzing = true);

    try {
      debugPrint("🔄 업데이트 시작 - OCR 큐 처리 중...");
      if (_ocrQueue.isNotEmpty) {
        await Future.wait(_ocrQueue);
      }

      final filePath = await _getOriginalTextFilePath();
      final fullText = await File(filePath).exists() ? await File(filePath).readAsString() : "";

      debugPrint("📊 스캔된 전체 텍스트 길이: ${fullText.length}자");

      if (fullText.trim().isEmpty) {
        throw Exception("스캔된 텍스트가 없습니다. 먼저 페이지를 촬영해주세요.");
      }

      debugPrint("🔍 Gemini 요약 요청 시작...");
      final newSummary = await _getGeminiUpdateSummary(fullText);
      debugPrint("📨 Gemini 응답 전체: [$newSummary]");
      debugPrint("📨 응답 길이: ${newSummary.length}자");

      if (newSummary.contains("실패") || newSummary.contains("오류")) {
        throw Exception("Gemini 요약 실패: $newSummary");
      }

      final appState = AppStateScope.of(context);
      appState.updateBookSummary(widget.bookId, newSummary);

      final finalPage = PageExtractor.extractPageNumberEnhanced(fullText, context, widget.bookId) ?? 0;
      if (finalPage != 0) {
        appState.updateBookCurrentPage(widget.bookId, finalPage);
        debugPrint("✅ 최종 페이지 업데이트: $finalPage P");
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("✅ $finalPage 페이지까지 요약 완료"), backgroundColor: Colors.green[700]),
        );
      }

      if (mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => BookDetailScreen(bookId: widget.bookId)));
      }
    } catch (e, stack) {
      debugPrint("❌ [업데이트 실패] 에러: $e");
      debugPrint("❌ StackTrace: $stack");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("업데이트 실패: $e")));
      }
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  // Gemini 요약 함수 (scan_screen.dart 안에 다시 포함)
  Future<String> _getGeminiUpdateSummary(String fullText) async {
    final limitedText = fullText.length > 20000
        ? fullText.substring(0, 20000) + "\n...(이후 내용 생략)..."
        : fullText;

    final prompt = """
다음은 책에서 스캔한 전체 내용입니다. 
현재까지 스캔된 페이지 수는 대략 ${fullText.length ~/ 220}페이지 정도입니다.

자연스럽고 읽기 쉽게 핵심 스토리를 약 10줄 내외로 자세히 요약해 주세요.

$limitedText

- "스캔된 내용에 따르면", "요약하자면" 같은 표현은 절대 사용하지 마세요.
- 불릿, 번호, 기호 없이 완전한 문장으로만 작성하세요.
""";

    try {
      final response = await http.post(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$_geminiApiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "contents": [{"parts": [{"text": prompt}]}],
          "safetySettings": [
            {"category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"},
            {"category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"},
            {"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"},
            {"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"},
          ],
          "generationConfig": {
            "temperature": 0.85,
            "maxOutputTokens": 5000,
            "topP": 0.95,
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['candidates']?[0]?['content']?['parts']?[0]?['text']?.trim() ?? "요약 실패";
      }
      return "요약 생성 실패 (HTTP ${response.statusCode})";
    } catch (e) {
      debugPrint("Gemini 오류: $e");
      return "통신 오류: $e";
    }
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
                      icon: const Icon(Icons.arrow_back_ios, size: 22, color: Colors.black87),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(widget.bookTitle, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 12),
                        Text("현재 인식된 페이지: $currentPage P", style: const TextStyle(fontSize: 13.5, color: Colors.orange)),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 78,
                    child: _pendingOcrCount > 0
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: Colors.orange[700], borderRadius: BorderRadius.circular(999)),
                            child: Text("OCR ${_pendingOcrCount}", style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
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