import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/book.dart';
import 'models/mock_books.dart';

class AppState extends ChangeNotifier {
  AppState() : _books = List<Book>.from(mockBooks) {
    _loadBooks();
  }

  static const _booksStorageKey = 'saved_books_v1';
  final List<Book> _books;
  bool _isLoaded = false;

  List<Book> get books => List<Book>.unmodifiable(_books);
  bool get isLoaded => _isLoaded;

  String addBook(String title) {
    final String newId = DateTime.now().millisecondsSinceEpoch.toString();
    
    final newBook = Book(
      id: newId,
      title: title,
      author: '작자 미상',
      coverUrl: '',
      summary: '',
      characters: [],
      relationships: [],
      keywords: [],
      currentPage: 0,
      totalPages: 0,
      progress: 0,
    );

    _books.insert(0, newBook);
    _saveBooks();
    notifyListeners();
    
    return newId; 
  }

  void deleteBook(String bookId) {
    final index = _books.indexWhere((book) => book.id == bookId);
    if (index != -1) {
      _books.removeAt(index);
      _saveBooks();
      notifyListeners();
    }
  }

  /// ⭐ 새로 추가된 메서드
  /// 업데이트 버튼을 누르면 Gemini가 만든 요약을 여기서 책 데이터에 직접 저장합니다.
  void updateBookSummary(String bookId, String newSummary) {
    final index = _books.indexWhere((book) => book.id == bookId);
    if (index != -1) {
      final oldBook = _books[index];

      // Book 모델의 모든 필드를 그대로 복사하면서 summary만 새 값으로 교체
      final updatedBook = Book(
        id: oldBook.id,
        title: oldBook.title,
        author: oldBook.author,
        coverUrl: oldBook.coverUrl,
        summary: newSummary,
        characters: oldBook.characters,
        relationships: oldBook.relationships,
        keywords: oldBook.keywords,
        currentPage: oldBook.currentPage,
        totalPages: oldBook.totalPages,
        progress: oldBook.progress,
      );

      _books[index] = updatedBook;
      _saveBooks();
      notifyListeners();
    }
  }

  Book? findBookById(String id) {
    for (final book in _books) {
      if (book.id == id) return book;
    }
    return null;
  }

  List<Book> uniqueBooks() {
    final seenTitles = <String>{};
    final unique = <Book>[];
    for (final book in _books) {
      if (seenTitles.add(book.title)) unique.add(book);
    }
    return unique;
  }

  Future<void> _loadBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final rawBooks = prefs.getString(_booksStorageKey);

    if (rawBooks != null && rawBooks.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawBooks) as List<dynamic>;
        _books
          ..clear()
          ..addAll(
            decoded.map((item) => Book.fromJson(item as Map<String, dynamic>)),
          );
      } catch (_) {
        _books..clear()..addAll(mockBooks);
      }
    }

    _isLoaded = true;
    notifyListeners();
  }

  Future<void> _saveBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_books.map((book) => book.toJson()).toList());
    await prefs.setString(_booksStorageKey, encoded);
  }
}

class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    required super.notifier,
    required super.child,
    super.key,
  });

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope not found in widget tree.');
    return scope!.notifier!;
  }
}