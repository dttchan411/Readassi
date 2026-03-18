import 'package:flutter/widgets.dart';

import 'models/book.dart';
import 'models/mock_books.dart';

class AppState extends ChangeNotifier {
  AppState() : _books = List<Book>.from(mockBooks);

  final List<Book> _books;

  List<Book> get books => List<Book>.unmodifiable(_books);

  void addBook(Book book) {
    _books.insert(0, book);
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
