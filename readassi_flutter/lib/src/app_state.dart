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

    String addBookWithFullInfo({
    required String title,
    required String author,
    String coverUrl = '',
    String summary = '',           // ← Google description 넣을 곳
    String? isbn,
    String? publisher,
    String? publishedDate,
    int? totalPages,
  }) {
    final String newId = DateTime.now().millisecondsSinceEpoch.toString();

    final newBook = Book(
      id: newId,
      title: title,
      author: author,
      coverUrl: coverUrl,
      summary: summary,                    
      isbn: isbn,
      publisher: publisher,
      publishedDate: publishedDate,
      characters: [],
      relationships: [],
      keywords: [],
      currentPage: 0,
      totalPages: totalPages ?? 0,
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

  /// 업데이트 버튼에서 요약 + 페이지 번호를 동시에 업데이트
  void updateBookSummary(String bookId, String newSummary) {
    final index = _books.indexWhere((book) => book.id == bookId);
    if (index != -1) {
      final oldBook = _books[index];

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
        isbn: oldBook.isbn,
        publisher: oldBook.publisher,
        publishedDate: oldBook.publishedDate,
      );

      _books[index] = updatedBook;
      _saveBooks();
      notifyListeners();
    }
  }
  /// Kakao/Google에서 가져온 정보로 책 정보 일괄 업데이트
  void updateBookInfo({
    required String bookId,
    required String author,
    int? totalPages,
    String? coverUrl,
  }) {
    final index = _books.indexWhere((book) => book.id == bookId);
    if (index == -1) return;

    final oldBook = _books[index];

    final updatedBook = Book(
      id: oldBook.id,
      title: oldBook.title,
      author: author,
      coverUrl: coverUrl ?? oldBook.coverUrl,
      summary: oldBook.summary,
      characters: oldBook.characters,
      relationships: oldBook.relationships,
      keywords: oldBook.keywords,
      currentPage: oldBook.currentPage,
      totalPages: totalPages ?? oldBook.totalPages,
      progress: oldBook.progress,
    );

    _books[index] = updatedBook;
    _saveBooks();
    notifyListeners();
  }

  void updateBookAuthor(String bookId, String author) {
    final index = _books.indexWhere((book) => book.id == bookId);
    if (index != -1) {
      final oldBook = _books[index];

      final updatedBook = Book(
        id: oldBook.id,
        title: oldBook.title,
        author: author,
        coverUrl: oldBook.coverUrl,
        summary: oldBook.summary,
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
  
  /// 업데이트 버튼을 눌렀을 때 마지막 페이지 번호도 함께 업데이트
  void updateBookCurrentPage(String bookId, int? currentPage) {
    final index = _books.indexWhere((book) => book.id == bookId);
    if (index != -1) {
      final oldBook = _books[index];
      final int newPage = currentPage ?? oldBook.currentPage ?? 0;
      final int totalPages = oldBook.totalPages ?? 0;

      final updatedBook = Book(
        id: oldBook.id,
        title: oldBook.title,
        author: oldBook.author,
        coverUrl: oldBook.coverUrl,
        summary: oldBook.summary,
        characters: oldBook.characters,
        relationships: oldBook.relationships,
        keywords: oldBook.keywords,
        currentPage: newPage,
        totalPages: oldBook.totalPages,
        progress: totalPages > 0 ? (newPage / totalPages * 100).round() : 0,
        isbn: oldBook.isbn,
        publisher: oldBook.publisher,
        publishedDate: oldBook.publishedDate,
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