import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../app_state.dart';
import 'scan_screen.dart';

const String _geminiApiKey = 'AIzaSyCNuqLUTLTrRTq1RVzeg71QYJY1C0YD6H0';

class AddBookScreen extends StatefulWidget {
  const AddBookScreen({super.key});

  @override
  State<AddBookScreen> createState() => _AddBookScreenState();
}

class _AddBookScreenState extends State<AddBookScreen> {
  final TextEditingController _titleController = TextEditingController();
  bool _isLoading = false;

  Future<void> _proceedToScan() async {
    final String title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("책 제목을 입력해주세요!")),
      );
      return;
    }

    setState(() => _isLoading = true);

    // 1. 책 먼저 등록
    final appState = AppStateScope.of(context);
    final String newBookId = appState.addBook(title);

    // 2. Gemini에게 작가 물어보기
    final author = await _askAuthorToGemini(title);

    // 3. 작가 업데이트
    appState.updateBookAuthor(newBookId, author);

    setState(() => _isLoading = false);

    // ScanScreen으로 이동
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ScanScreen(
          bookId: newBookId,
          bookTitle: title,
        ),
      ),
    );
  }

  /// Gemini에게 책 제목으로 작가 물어보기
  Future<String> _askAuthorToGemini(String bookTitle) async {
    final prompt = """
다음 책의 정확한 작가(지은이) 이름을 알려줘.

책 제목: "$bookTitle"

- 반드시 실제 작가 이름을 한 명만 정확히 말해
- 모르거나 확실하지 않으면 "작자 미상"이라고만 답변해
- 다른 설명, 문장, 괄호, "작가:" 같은 단어는 절대 넣지 말고 이름만 출력해
""";

    try {
      final response = await http.post(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$_geminiApiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "contents": [{"parts": [{"text": prompt}]}],
          "generationConfig": {"temperature": 0.2, "maxOutputTokens": 100},
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final answer = data['candidates']?[0]?['content']?['parts']?[0]?['text']?.trim();
        if (answer != null && answer.isNotEmpty) {
          return answer;
        }
      }
    } catch (e) {
      debugPrint("Gemini 작가 조회 실패: $e");
    }

    return '작자 미상';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF7),
      appBar: AppBar(
        title: const Text("새 책 등록"),
        backgroundColor: const Color(0xFFFDFBF7),
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.auto_stories_rounded, size: 80, color: Color(0xFFB5651D)),
            const SizedBox(height: 30),
            Text(
              "어떤 책을 읽으실 건가요?",
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF4A4541),
                  ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _titleController,
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white,
                labelText: '책 제목 입력',
                hintText: '예: 클린 코드 (Clean Code)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: Color(0xFFE4DDD6)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: Color(0xFFE4DDD6)),
                ),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _proceedToScan,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFB5651D),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        "책 등록하고 스캔 시작",
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}