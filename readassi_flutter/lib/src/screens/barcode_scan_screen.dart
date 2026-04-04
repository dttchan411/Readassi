import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../app_state.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  bool _isProcessed = false;

  final String _kakaoApiKey = dotenv.env['_kakaoApiKey'] ?? '';
  final String _googleBooksApiKey = dotenv.env['_googleBooksApiKey'] ?? ''; // ← 기존에 googleVisionApiKey로 잘못 썼던 부분 수정

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("책 바코드 스캔")),
      body: MobileScanner(
        onDetect: (capture) async {
          if (_isProcessed) return;

          final List<Barcode> barcodes = capture.barcodes;
          for (final barcode in barcodes) {
            final String? isbn = barcode.rawValue;
            if (isbn != null && isbn.isNotEmpty) {
              _isProcessed = true;
              await _registerBookByIsbn(isbn);
              break;
            }
          }
        },
      ),
    );
  }

  Future<void> _registerBookByIsbn(String isbn) async {
    final appState = AppStateScope.of(context);

    // 로딩 표시
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final info = await _fetchBookInfoFromIsbn(isbn);

      if (info != null) {
        // ✅ 새로 만든 메서드 사용 (title, author, cover, totalPages 한 번에 등록)
        final newBookId = appState.addBookWithFullInfo(
          title: info['title'] ?? '제목 없음',
          author: info['author'] ?? '작자 미상',
          coverUrl: info['coverUrl'] ?? '',
          summary: '', // 나중에 스캔하면서 채움
          totalPages: info['totalPages'],
        );

        if (mounted) {
          Navigator.pop(context); // 로딩 다이얼로그 닫기
          Navigator.pop(context); // 바코드 스캔 화면 닫기

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ "${info['title']}" 책이 등록되었습니다!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        throw Exception('책 정보를 찾을 수 없습니다.');
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // 로딩 다이얼로그 닫기
        Navigator.pop(context); // 스캔 화면 닫기
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('책 등록 실패: $e')),
        );
      }
    }
  }

  Future<Map<String, dynamic>?> _fetchBookInfoFromIsbn(String isbn) async {
    // 1. 카카오 먼저 시도
    var info = await _searchKakao(isbn);
    if (info != null) return info;

    // 2. 실패하면 구글
    info = await _searchGoogle(isbn);
    return info;
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
          'title': book['title'] ?? '',
          'author': (book['authors'] as List<dynamic>?)?.join(', ') ?? '작자 미상',
          'coverUrl': book['thumbnail'] ?? '',
          'totalPages': null, // 카카오는 페이지 수 안 줌
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
          'title': volumeInfo['title'] ?? '',
          'author': (volumeInfo['authors'] as List<dynamic>?)?.join(', ') ?? '작자 미상',
          'coverUrl': volumeInfo['imageLinks']?['thumbnail'] ?? '',
          'totalPages': volumeInfo['pageCount'],
        };
      }
    } catch (e) {
      debugPrint("Google ISBN 검색 오류: $e");
    }
    return null;
  }
}