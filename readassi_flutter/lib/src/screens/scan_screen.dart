import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';

import '../app_state.dart';
import 'book_detail_screen.dart';

import 'package:flutter_dotenv/flutter_dotenv.dart';

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

  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isAnalyzing = false;

  // 줌 관련 변수
  double _minZoomLevel = 1.0;
  double _maxZoomLevel = 1.0;
  double _currentZoomLevel = 1.0;
  double _baseZoomLevel = 1.0; // 핀치 제스처 시작 시점의 배율

  // OCR 백그라운드 큐
  final List<Future<void>> _ocrQueue = [];
  int _pendingOcrCount = 0;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

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

      // 기기의 지원 줌 범위 가져오기
      _minZoomLevel = await _controller!.getMinZoomLevel();
      _maxZoomLevel = await _controller!.getMaxZoomLevel();

      if (!mounted) return;
      setState(() => _isCameraInitialized = true);
    } catch (e) {
      debugPrint("카메라 에러: $e");
    }
  }

  // 배율 업데이트 함수
  Future<void> _updateZoom(double zoom) async {
    if (_controller == null) return;
    // 지원 범위를 벗어나지 않게 고정
    final double clampedZoom = zoom.clamp(_minZoomLevel, _maxZoomLevel);
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
      await _appendToOriginalText(text);

      final pageNumber = _extractPageNumber(text);
      if (pageNumber != null) {
        final appState = AppStateScope.of(context);
        appState.updateBookCurrentPage(widget.bookId, pageNumber);
        debugPrint("📄 페이지 감지됨 → $pageNumber 페이지로 업데이트");
      }
    } catch (e) {
      debugPrint("OCR 처리 실패: $e");
    } finally {
      completer.complete();
      _ocrQueue.removeAt(0);
      if (mounted) {
        setState(() => _pendingOcrCount = _ocrQueue.length);
      }
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

  Future<void> _appendToOriginalText(String newText) async {
    final file = File(await _getOriginalTextFilePath());
    if (!await file.exists()) await file.create();
    await file.writeAsString('$newText\n\n', mode: FileMode.append);
  }

  Future<void> _takePictureAndProcess() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isAnalyzing) return;

    setState(() => _isAnalyzing = true);

    try {
      final photo = await _controller!.takePicture();
      final bytes = await File(photo.path).readAsBytes();

      _enqueueOcr(bytes);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("페이지 저장 완료!")),
        );
      }
    } catch (e) {
      debugPrint("촬영 오류: $e");
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  Future<void> _performUpdate() async {
    if (_isAnalyzing) return;
    setState(() => _isAnalyzing = true);

    try {
      if (_ocrQueue.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("OCR 처리 중... 잠시만 기다려주세요")),
        );
        await Future.wait(_ocrQueue);
      }

      final filePath = await _getOriginalTextFilePath();
      final fullText =
          await File(filePath).exists() ? await File(filePath).readAsString() : "";

      if (fullText.trim().isEmpty) {
        throw Exception("스캔된 텍스트가 없습니다.");
      }

      final newSummary = await _getGeminiUpdateSummary(fullText);

      if (newSummary.contains("실패") || newSummary.contains("오류")) {
        throw Exception("요약 생성에 실패했습니다.");
      }

      final appState = AppStateScope.of(context);
      appState.updateBookSummary(widget.bookId, newSummary);

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => BookDetailScreen(bookId: widget.bookId),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("업데이트 실패: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  Future<String> _getGeminiUpdateSummary(String fullText) async {
    final limitedText =
        fullText.length > 8000
            ? fullText.substring(0, 8000) + "\n...(생략)..."
            : fullText;

    final prompt = """
다음은 책에서 스캔한 전체 내용입니다. 자연스럽고 읽기 쉽게 핵심 스토리를 3~4줄로 요약해 주세요.

$limitedText

- "스캔된 내용에 따르면" 같은 표현은 사용하지 마세요.
- 불릿, 번호, 기호 없이 완전한 문장으로만 작성하세요.
- 책의 흐름과 중요한 사건을 자연스럽게 포함해 주세요.
""";

    try {
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
          "safetySettings": [
            {"category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"},
            {"category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"},
            {
              "category": "HARM_CATEGORY_SEXUALLY_EXPLICIT",
              "threshold": "BLOCK_NONE",
            },
            {
              "category": "HARM_CATEGORY_DANGEROUS_CONTENT",
              "threshold": "BLOCK_NONE",
            },
          ],
          "generationConfig": {
            "temperature": 0.85,
            "maxOutputTokens": 3000,
            "topP": 0.95,
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['candidates']?[0]?['content']?['parts']?[0]?['text']
                ?.trim() ??
            "요약 실패";
      }
      return "요약 생성 실패";
    } catch (e) {
      debugPrint("Gemini 오류: $e");
      return "통신 오류";
    }
  }

  int? _extractPageNumber(String fullText) {
    if (fullText.trim().isEmpty) return null;

    final lines = fullText.split('\n');
    final lastLines =
        lines.length > 8 ? lines.sublist(lines.length - 8) : lines;

    int? bestPage;

    for (final line in lastLines) {
      final matches = RegExp(r'\b(\d{1,3})\b').allMatches(line);

      for (final m in matches) {
        final num = int.tryParse(m.group(1)!);
        if (num != null && num >= 1 && num <= 999) {
          if (bestPage == null || num > bestPage) {
            bestPage = num;
          }
        }
      }
    }
    return bestPage;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCameraInitialized || _controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF7),
      appBar: AppBar(
        title: Text(widget.bookTitle),
        backgroundColor: const Color(0xFFFDFBF7),
        elevation: 0,
        actions: [
          if (_pendingOcrCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange[700],
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    "OCR 대기 ${_pendingOcrCount}장",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          // 핀치 투 줌을 위한 제스처 감지기
          GestureDetector(
            onScaleStart: (details) {
              _baseZoomLevel = _currentZoomLevel;
            },
            onScaleUpdate: (details) {
              // 핀치 확대/축소 로직 적용
              _updateZoom(_baseZoomLevel * details.scale);
            },
            child: SizedBox.expand(child: CameraPreview(_controller!)),
          ),

          // 배율 전환 버튼 (1x, 2x, 3x)
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildZoomButton("1x", 1.0),
                const SizedBox(width: 12),
                _buildZoomButton("2x", 2.0),
                const SizedBox(width: 12),
                _buildZoomButton("3x", 3.0),
              ],
            ),
          ),

          if (_isAnalyzing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 20),
                    Text(
                      "AI 분석 중...",
                      style: TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          decoration: const BoxDecoration(
            color: Color(0xFFFDFBF7),
            border: Border(top: BorderSide(color: Color(0xFFE4DDD6), width: 1)),
          ),
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isAnalyzing ? null : _takePictureAndProcess,
                  icon: const Icon(Icons.camera_alt, size: 24),
                  label: const Text(
                    "페이지 촬영",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFB5651D),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isAnalyzing ? null : _performUpdate,
                  icon: const Icon(Icons.summarize_outlined, size: 24),
                  label: const Text(
                    "업데이트",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: const BorderSide(color: Color(0xFFB5651D)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 줌 프리셋 버튼 빌더
  Widget _buildZoomButton(String label, double zoom) {
    // 반올림하여 현재 선택된 배율 표시 여부 결정
    final isSelected = _currentZoomLevel.round() == zoom.round();
    return GestureDetector(
      onTap: () => _updateZoom(zoom),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFB5651D) : Colors.black54,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white24, width: 1),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}