import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../app_state.dart';
import '../models/book.dart';
import '../widgets/book_cover.dart';
import '../widgets/book_progress_bar.dart';
import 'book_detail_screen.dart';

class SelectBookScreen extends StatefulWidget {
  const SelectBookScreen({super.key});

  @override
  State<SelectBookScreen> createState() => _SelectBookScreenState();
}

class _SelectBookScreenState extends State<SelectBookScreen> {
  String _searchQuery = '';
  SelectBookSortType _sortType = SelectBookSortType.latest;

  // 책 삭제 함수 (AppState + 파일 모두 삭제)
  Future<void> _deleteBook(Book book) async {
    final appState = AppStateScope.of(context);
    appState.deleteBook(book.id); // AppState에서 책 삭제 (기존 메서드가 있어야 함)

    // 파일도 함께 삭제
    try {
      final dir = await getApplicationDocumentsDirectory();
      final bookDir = Directory(p.join(dir.path, 'books'));

      final originalFile = File(p.join(bookDir.path, '${book.id}_original.txt'));
      final detailedFile = File(p.join(bookDir.path, '${book.id}_detailed_summary.txt'));

      if (await originalFile.exists()) await originalFile.delete();
      if (await detailedFile.exists()) await detailedFile.delete();
    } catch (e) {
      debugPrint("파일 삭제 중 오류: $e");
    }

    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final books = _visibleBooks(AppStateScope.of(context).uniqueBooks());

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF7),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            Text(
              '분석 기록',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '이전에 분석한 책을 다시 열고, 요약과 등장인물, 질문 기록을 이어서 볼 수 있습니다.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF7D746C),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            // 검색 + 정렬 UI (기존 그대로)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: '검색어를 입력하세요',
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(color: Color(0xFFE4DDD6)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(color: Color(0xFFE4DDD6)),
                      ),
                    ),
                    onChanged: (value) => setState(() => _searchQuery = value),
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<SelectBookSortType>(
                  onSelected: (value) => setState(() => _sortType = value),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: SelectBookSortType.latest, child: Text('최신순')),
                    PopupMenuItem(value: SelectBookSortType.title, child: Text('제목순')),
                    PopupMenuItem(value: SelectBookSortType.progress, child: Text('진행순')),
                  ],
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: const Color(0xFFE4DDD6)),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(Icons.tune_rounded, size: 18),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            if (books.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: Text('검색 결과가 없습니다.')),
              )
            else
              ...books.map(
                (book) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: Stack(
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(24),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => BookDetailScreen(bookId: book.id),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                BookCover(
                                  imageUrl: book.coverUrl,
                                  width: 56,
                                  height: 82,
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        book.title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(fontWeight: FontWeight.w700),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        book.author,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(color: const Color(0xFF7D746C)),
                                      ),
                                      const SizedBox(height: 12),
                                      BookProgressBar(book: book),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // 우측 상단 X 삭제 버튼
                        Positioned(
                          top: 8,
                          right: 8,
                          child: IconButton(
                            icon: const Icon(Icons.close, color: Colors.redAccent, size: 22),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('책 삭제'),
                                  content: Text('"${book.title}"을(를) 삭제하시겠습니까?\n모든 스캔 기록도 함께 삭제됩니다.'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, false),
                                      child: const Text('취소'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, true),
                                      child: const Text('삭제', style: TextStyle(color: Colors.red)),
                                    ),
                                  ],
                                ),
                              );

                              if (confirm == true) {
                                await _deleteBook(book);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Book> _visibleBooks(List<Book> books) {
    final lowered = _searchQuery.trim().toLowerCase();
    final filtered = lowered.isEmpty
        ? List<Book>.from(books)
        : books
            .where((book) =>
                book.title.toLowerCase().contains(lowered) ||
                book.author.toLowerCase().contains(lowered))
            .toList();

    filtered.sort((a, b) {
      switch (_sortType) {
        case SelectBookSortType.latest:
          return 0;
        case SelectBookSortType.title:
          return a.title.compareTo(b.title);
        case SelectBookSortType.progress:
          return b.progressPercent.compareTo(a.progressPercent);
      }
    });

    return filtered;
  }
}

enum SelectBookSortType { latest, title, progress }