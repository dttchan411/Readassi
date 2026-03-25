import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';

import '../app_state.dart';

const String _googleVisionApiKey = '';
const String _geminiApiKey = '';

class ScanScreen extends StatefulWidget {
  final String bookId;
  final String bookTitle;

  const ScanScreen({super.key, required this.bookId, required this.bookTitle});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isAnalyzing = false;

  String? _displaySummary;

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
      _controller = CameraController(cameras.first, ResolutionPreset.high, enableAudio: false);
      await _controller!.initialize();
      if (!mounted) return;
      setState(() => _isCameraInitialized = true);
    } catch (e) {
      debugPrint("카메라 에러: $e");
    }
  }

  Future<String> _getOriginalTextFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    final bookDir = Directory(p.join(dir.path, 'books'));
    await bookDir.create(recursive: true);
    return p.join(bookDir.path, '${widget.bookId}_original.txt');
  }

  Future<void> _appendToOriginalText(String newText) async {
    final file = File(await _getOriginalTextFilePath());
    if (!await file.exists()) await file.create();
    await file.writeAsString('$newText\n\n', mode: FileMode.append);
  }

  Future<String> _getVisionText(Uint8List bytes) async {
    final base64Image = base64Encode(bytes);
    final response = await http.post(
      Uri.parse('https://vision.googleapis.com/v1/images:annotate?key=$_googleVisionApiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'requests': [{
          'image': {'content': base64Image},
          'features': [{'type': 'DOCUMENT_TEXT_DETECTION'}],
          'imageContext': {'languageHints': ['ko']}
        }]
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['responses']?[0]?['fullTextAnnotation']?['text'] ?? "인식 실패";
    }
    return "텍스트 추출 실패";
  }

  Future<void> _takePictureAndProcess() async {
    if (_controller == null || !_controller!.value.isInitialized || _isAnalyzing) return;

    setState(() => _isAnalyzing = true);

    try {
      final photo = await _controller!.takePicture();
      final bytes = await File(photo.path).readAsBytes();
      final text = await _getVisionText(bytes);
      await _appendToOriginalText(text);
    } catch (e) {
      debugPrint("촬영 오류: $e");
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  Future<void> _performUpdate() async {
    setState(() => _isAnalyzing = true);

    try {
      final filePath = await _getOriginalTextFilePath();
      final fullText = await File(filePath).exists() 
          ? await File(filePath).readAsString() 
          : "";

      if (fullText.trim().isEmpty) throw Exception("스캔된 텍스트가 없습니다.");

      final displaySummary = await _getGeminiUpdateSummary(fullText);

      if (mounted) {
        setState(() => _displaySummary = displaySummary);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("업데이트 실패: $e")));
      }
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  Future<String> _getGeminiUpdateSummary(String fullText) async {
    final limitedText = fullText.length > 8000 
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
          "generationConfig": {"temperature": 0.85, "maxOutputTokens": 3000, "topP": 0.95},
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['candidates']?[0]?['content']?['parts']?[0]?['text']?.trim() ?? "요약 실패";
      }
      return "요약 생성 실패";
    } catch (e) {
      debugPrint("Gemini 오류: $e");
      return "통신 오류";
    }
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
      ),
      body: Stack(
        children: [
          if (_displaySummary == null)
            CameraPreview(_controller!),

          if (_displaySummary != null)
            _buildResultView(),

          if (_isAnalyzing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 20),
                    Text("AI 분석 중...", style: TextStyle(color: Colors.white, fontSize: 18)),
                  ],
                ),
              ),
            ),
        ],
      ),

      // ==================== 하단 버튼 영역 (UI 개선) ====================
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
                  onPressed: _displaySummary == null ? _takePictureAndProcess : null,
                  icon: const Icon(Icons.camera_alt, size: 24),
                  label: const Text("페이지 촬영", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFB5651D),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _performUpdate,
                  icon: const Icon(Icons.summarize_outlined, size: 24),
                  label: const Text("업데이트", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: const BorderSide(color: Color(0xFFB5651D)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildCard("✨ 업데이트된 스토리 요약", _displaySummary!, Colors.orange[50]!),
          const SizedBox(height: 50),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: () => setState(() => _displaySummary = null),
              child: const Text("다시 촬영 시작하기"),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(String title, String content, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Divider(),
          Text(content),
        ],
      ),
    );
  }
}