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

  void addBook(Book book) {
    _books.insert(0, book);
    _saveBooks();
    notifyListeners();
  }

  Book? findBookById(String id) {
    for (final book in _books) {
      if (book.id == id) {
        return book;
      }
    }
    return null;
  }

  List<Book> uniqueBooks() {
    final seenTitles = <String>{};
    final unique = <Book>[];
    for (final book in _books) {
      if (seenTitles.add(book.title)) {
        unique.add(book);
      }
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
        // 저장된 데이터가 깨진 경우에는 기본 목업 데이터로 다시 시작합니다.
        _books
          ..clear()
          ..addAll(mockBooks);
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
