import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/book.dart';
import '../widgets/book_cover.dart';
import '../widgets/book_progress_bar.dart';
import 'book_detail_screen.dart';
import 'scan_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({required this.openLibrary, super.key});

  final VoidCallback openLibrary;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _searchQuery = '';
  HomeSortType _sortType = HomeSortType.latest;

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final books = _visibleBooks(appState.uniqueBooks());

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF7),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF0D9),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.auto_stories_rounded,
                          color: Color(0xFF9C5B22),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'ReadAssi',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'AI 독서 보조 애플리케이션',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF7D746C),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                children: [
                  _MenuCard(
                    title: '새로운 책 읽기',
                    description: '새로운 책을 카메라로 스캔하여 기록을 시작합니다.',
                    icon: Icons.add,
                    accent: const Color(0xFFFFF0D9),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ScanScreen(),
                        ),
                      );
                      if (mounted) {
                        setState(() {});
                      }
                    },
                  ),
                  const SizedBox(height: 18),
                  _MenuCard(
                    title: '이어서 읽기',
                    description: '이전에 읽던 책을 선택해 이어서 스캔합니다.',
                    icon: Icons.history_rounded,
                    accent: const Color(0xFFF1ECE7),
                    onTap: widget.openLibrary,
                    muted: true,
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '이어서 읽을 책',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      PopupMenuButton<HomeSortType>(
                        initialValue: _sortType,
                        onSelected: (value) =>
                            setState(() => _sortType = value),
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: HomeSortType.latest,
                            child: Text('최신순'),
                          ),
                          PopupMenuItem(
                            value: HomeSortType.title,
                            child: Text('이름순'),
                          ),
                          PopupMenuItem(
                            value: HomeSortType.progress,
                            child: Text('진행도순'),
                          ),
                        ],
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFE4DDD6)),
                          ),
                          child: const Icon(Icons.tune_rounded, size: 18),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    decoration: InputDecoration(
                      hintText: '책 제목이나 저자 검색',
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
                  const SizedBox(height: 18),
                  if (appState.books.isEmpty)
                    _EmptyState(
                      message: '아직 기록된 책이 없습니다.',
                      buttonLabel: '새로운 책 기록하기',
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ScanScreen(),
                          ),
                        );
                        if (mounted) {
                          setState(() {});
                        }
                      },
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
                                  builder: (_) =>
                                      ScanScreen(existingBookId: book.id),
                                ),
                              );
                              if (mounted) {
                                setState(() {});
                              }
                            },
                            onLongPress: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      BookDetailScreen(bookId: book.id),
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          book.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          book.author,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
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
        case HomeSortType.latest:
          return 0;
        case HomeSortType.title:
          return a.title.compareTo(b.title);
        case HomeSortType.progress:
          return b.progressPercent.compareTo(a.progressPercent);
      }
    });

    return filtered;
  }
}

enum HomeSortType { latest, title, progress }

class _MenuCard extends StatelessWidget {
  const _MenuCard({
    required this.title,
    required this.description,
    required this.icon,
    required this.accent,
    required this.onTap,
    this.muted = false,
  });

  final String title;
  final String description;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      color: muted ? const Color(0xFFFAF8F5) : Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(icon, color: const Color(0xFF855220)),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                description,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF7D746C),
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.message,
    required this.buttonLabel,
    required this.onTap,
  });

  final String message;
  final String buttonLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 36),
        child: Column(
          children: [
            const Icon(
              Icons.menu_book_rounded,
              size: 48,
              color: Color(0xFFC8BFB5),
            ),
            const SizedBox(height: 14),
            Text(message),
            const SizedBox(height: 14),
            FilledButton.tonal(onPressed: onTap, child: Text(buttonLabel)),
          ],
        ),
      ),
    );
  }
}
