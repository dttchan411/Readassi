import 'package:flutter/material.dart';
import '../app_state.dart';
import 'scan_screen.dart';

class AddBookScreen extends StatefulWidget {
  const AddBookScreen({super.key});

  @override
  State<AddBookScreen> createState() => _AddBookScreenState();
}

class _AddBookScreenState extends State<AddBookScreen> {
  final TextEditingController _titleController = TextEditingController();

  void _proceedToScan() {
    final String title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("책 제목을 입력해주세요!")),
      );
      return;
    }

    // AppState를 통해 새 책을 생성하고 발급된 ID를 변수에 담습니다.
    final appState = AppStateScope.of(context);
    final String newBookId = appState.addBook(title);

    // ScanScreen의 새로운 생성자 규격(bookId, bookTitle)에 맞춰서 이동합니다.
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
                onPressed: _proceedToScan,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFB5651D),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
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