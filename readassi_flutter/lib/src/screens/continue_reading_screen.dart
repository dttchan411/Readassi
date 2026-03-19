import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/book.dart';
import '../widgets/book_cover.dart';
import '../widgets/book_progress_bar.dart';
import 'scan_screen.dart';

class ContinueReadingScreen extends StatefulWidget {
  const ContinueReadingScreen({super.key});

  @override
  State<ContinueReadingScreen> createState() => _ContinueReadingScreenState();
}

class _ContinueReadingScreenState extends State<ContinueReadingScreen> {
  String _searchQuery = '';
  ContinueReadingSortType _sortType = ContinueReadingSortType.latest;

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final books = _visibleBooks(appState.uniqueBooks());

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFBF7),
        title: const Text('이어 읽을 책'),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          children: [
            Text(
              '이전에 읽던 책을 골라서 바로 다음 스캔 기록으로 이어갑니다.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF7D746C),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: '책 제목이나 저자를 검색하세요',
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
                PopupMenuButton<ContinueReadingSortType>(
                  onSelected: (value) => setState(() => _sortType = value),
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: ContinueReadingSortType.latest,
                      child: Text('최신순'),
                    ),
                    PopupMenuItem(
                      value: ContinueReadingSortType.title,
                      child: Text('제목순'),
                    ),
                    PopupMenuItem(
                      value: ContinueReadingSortType.progress,
                      child: Text('진행순'),
                    ),
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
            if (appState.books.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: Text('아직 이어서 읽을 책이 없습니다.')),
              )
            else if (books.isEmpty)
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
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ScanScreen(existingBookId: book.id),
                          ),
                        );
                        if (mounted) {
                          setState(() {});
                        }
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
                                        ?.copyWith(
                                          color: const Color(0xFF7D746C),
                                        ),
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
              .where(
                (book) =>
                    book.title.toLowerCase().contains(lowered) ||
                    book.author.toLowerCase().contains(lowered),
              )
              .toList();

    filtered.sort((a, b) {
      switch (_sortType) {
        case ContinueReadingSortType.latest:
          return 0;
        case ContinueReadingSortType.title:
          return a.title.compareTo(b.title);
        case ContinueReadingSortType.progress:
          return b.progressPercent.compareTo(a.progressPercent);
      }
    });

    return filtered;
  }
}

enum ContinueReadingSortType { latest, title, progress }
