import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../app_state.dart';
import 'scan_screen.dart';

import 'package:flutter_dotenv/flutter_dotenv.dart';

class AddBookScreen extends StatefulWidget {
  const AddBookScreen({super.key});

  @override
  State<AddBookScreen> createState() => _AddBookScreenState();
}

class _AddBookScreenState extends State<AddBookScreen> {
  
  final String _kakaoApiKey = dotenv.env['_kakaoApiKey'] ?? "no key";
  final String _googleBooksApiKey = dotenv.env['_googleVisionApiKey'] ?? "no key";
  
  final TextEditingController _titleController = TextEditingController();
  bool _isLoading = false;

  void _proceedToScan() async {
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

    // 2. ScanScreen으로 바로 이동 (사용자 대기 없이)
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ScanScreen(
          bookId: newBookId,
          bookTitle: title,
        ),
      ),
    );

    // 3. 백그라운드에서 작가·페이지·표지 업데이트
    _fetchAndUpdateBookInfo(newBookId, title);
  }

  Future<void> _fetchAndUpdateBookInfo(String bookId, String title) async {
    final isKorean = RegExp(r'^[가-힣]').hasMatch(title);

    Map<String, dynamic>? info;

    // 한글이면 Kakao 먼저, 아니면 Google 먼저
    if (isKorean) {
      info = await _searchKakao(title);
      if (info == null) info = await _searchGoogle(title);
    } else {
      info = await _searchGoogle(title);
      if (info == null) info = await _searchKakao(title);
    }

    if (info != null) {
      final appState = AppStateScope.of(context);
      appState.updateBookInfo(
        bookId: bookId,
        author: info['author'] ?? '작자 미상',
        totalPages: info['totalPages'],
        coverUrl: info['coverUrl'],
      );
    }
  }

  Future<Map<String, dynamic>?> _searchKakao(String isbn) async {
    try {
      final response = await http.get(
        Uri.parse('https://dapi.kakao.com/v3/search/book.json?query=$isbn&target=isbn'),
        headers: {'Authorization': 'KakaoAK $_kakaoApiKey'},
    );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final documents = data['documents'] as List<dynamic>?;
        if (documents == null || documents.isEmpty) return null;

        final book = documents.first;
        return {
          'author': (book['authors'] as List<dynamic>?)?.join(', ') ?? '작자 미상',
          'totalPages': book['contents'] != null ? null : null, // Kakao는 페이지 수를 주지 않음
          'coverUrl': book['thumbnail'] ?? '',
        };
      }
    } catch (e) {
      debugPrint("Kakao ISBN 검색 오류: $e");
    }
    return null;
  }

  Future<Map<String, dynamic>?> _searchGoogle(String isbn) async {
    try {
      final response = await http.get(
        Uri.parse('https://www.googleapis.com/books/v1/volumes?q=isbn:$isbn&key=$_googleBooksApiKey'),
    );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final items = data['items'] as List<dynamic>?;
        if (items == null || items.isEmpty) return null;

        final volumeInfo = items.first['volumeInfo'] as Map<String, dynamic>;
        return {
          'author': (volumeInfo['authors'] as List<dynamic>?)?.join(', ') ?? '작자 미상',
          'totalPages': volumeInfo['pageCount'],
          'coverUrl': volumeInfo['imageLinks']?['thumbnail'] ?? '',
        };
      }
    } catch (e) {
      debugPrint("Google ISBN 검색 오류: $e");
    }
    return null;
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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