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
    String summary = '', // ← Google description 넣을 곳
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
        description: oldBook.description,
      );

      _books[index] = updatedBook;
      _saveBooks();
      notifyListeners();
    }
  }

  void updateBookCharacters(String bookId, List<dynamic> rawCharacters) {
    final index = _books.indexWhere((book) => book.id == bookId);
    if (index == -1) return;

    final oldBook = _books[index];
    // 기존 인물은 이름으로 "조회"만 한다(같은 인물의 id·이미지·누적 정보를 잇기 위함).
    // 출력 목록은 이번 분석 결과(rawCharacters)만으로 다시 구성한다 — 그래야
    // 분석마다 잠정 이름("죽은 동료 A" 등)이 달라져도 같은 인물이 중복 누적되지 않는다.
    final oldByName = {
      for (final character in oldBook.characters) character.name: character,
    };

    final characters = <Character>[];
    final seenNames = <String>{};
    for (final item in rawCharacters.whereType<Map<String, dynamic>>()) {
      final name = _normalizeCharacterField(item['name']);
      final role = _normalizeCharacterField(item['role']);
      final description = _normalizeCharacterField(item['description']);
      final personality = _normalizeCharacterField(item['personality']);
      final motivation = _normalizeCharacterField(item['motivation']);
      final firstPage = _normalizeFirstPage(item['first_page']);
      final importance = _normalizeImportance(item['importance']);

      if (!_looksLikeRealCharacter(name, role, description)) {
        continue;
      }

      if (!seenNames.add(name)) {
        continue;
      }

      final existing = oldByName[name];
      characters.add(
        Character(
          id: existing?.id ?? '${oldBook.id}_${name.hashCode.abs()}',
          name: name,
          role: _selectCharacterRole(existing?.role, role),
          description: _selectCharacterDescription(
            existing?.description,
            description,
          ),
          imageUrl: existing?.imageUrl ?? '',
          personality: _selectRelationshipText(
            existing?.personality,
            personality,
          ),
          motivation: _selectRelationshipText(existing?.motivation, motivation),
          firstPage: _selectFirstPage(existing?.firstPage, firstPage),
          importance: _selectImportance(existing?.importance, importance),
        ),
      );
    }

    // 이번 분석에서 유효 인물이 하나도 없으면 기존 목록을 유지한다(목록 증발 방지).
    if (characters.isEmpty) {
      return;
    }

    // 주인공 보존 — 이번 결과에 주인공이 없는데 기존엔 있었다면 기존 주인공을 잇는다.
    if (!characters.any((character) => character.name.contains('주인공'))) {
      for (final old in oldBook.characters) {
        if (old.name.contains('주인공') &&
            !characters.any((character) => character.name == old.name)) {
          characters.add(old);
          break;
        }
      }
    }

    // 중요도 내림차순 정렬 — 주인공은 항상 맨 위.
    characters.sort((a, b) {
      final aIsProtagonist = a.name.contains('주인공') ? 1 : 0;
      final bIsProtagonist = b.name.contains('주인공') ? 1 : 0;
      if (aIsProtagonist != bIsProtagonist) {
        return bIsProtagonist - aIsProtagonist;
      }
      return b.importance.compareTo(a.importance);
    });

    final updatedBook = Book(
      id: oldBook.id,
      title: oldBook.title,
      author: oldBook.author,
      coverUrl: oldBook.coverUrl,
      summary: oldBook.summary,
      characters: characters,
      relationships: oldBook.relationships,
      keywords: oldBook.keywords,
      currentPage: oldBook.currentPage,
      totalPages: oldBook.totalPages,
      progress: oldBook.progress,
      isbn: oldBook.isbn,
      publisher: oldBook.publisher,
      publishedDate: oldBook.publishedDate,
      description: oldBook.description,
    );

    _books[index] = updatedBook;
    _saveBooks();
    notifyListeners();
  }

  void updateBookRelationships(String bookId, List<dynamic> rawRelationships) {
    final index = _books.indexWhere((book) => book.id == bookId);
    if (index == -1) return;

    final oldBook = _books[index];
    if (oldBook.characters.length < 2) return;

    final relationshipsByKey = <String, Relationship>{};
    for (final relationship in oldBook.relationships) {
      final key = _relationshipKey(
        relationship.source,
        relationship.target,
        oldBook.characters,
      );
      if (key != null) {
        relationshipsByKey[key] = relationship;
      }
    }

    final seenKeys = <String>{};
    for (final item in rawRelationships.whereType<Map<String, dynamic>>()) {
      final source = _normalizeCharacterField(item['source'] ?? item['from']);
      final target = _normalizeCharacterField(item['target'] ?? item['to']);
      final label = _normalizeCharacterField(item['label']);
      final description = _normalizeCharacterField(item['description']);
      final evidence = _normalizeCharacterField(item['evidence']);
      final type = _normalizeCharacterField(item['type']);
      final strength = _normalizeRelationshipStrength(item['strength']);

      if (source.isEmpty || target.isEmpty || label.isEmpty) {
        continue;
      }

      final sourceCharacter = _resolveCharacterReference(
        source,
        oldBook.characters,
      );
      final targetCharacter = _resolveCharacterReference(
        target,
        oldBook.characters,
      );

      if (sourceCharacter == null || targetCharacter == null) {
        continue;
      }

      if (sourceCharacter.id == targetCharacter.id) {
        continue;
      }

      final key = _relationshipKey(
        sourceCharacter.name,
        targetCharacter.name,
        oldBook.characters,
      );
      if (key == null || !seenKeys.add(key)) {
        continue;
      }

      final existing = relationshipsByKey[key];
      relationshipsByKey[key] = Relationship(
        source: sourceCharacter.name,
        target: targetCharacter.name,
        label: _selectRelationshipText(existing?.label, label),
        description: _selectRelationshipText(
          existing?.description,
          description,
        ),
        evidence: _selectRelationshipText(existing?.evidence, evidence),
        strength: _selectRelationshipStrength(existing?.strength, strength),
        type: type.isEmpty ? existing?.type ?? '' : type,
      );
    }

    final updatedBook = Book(
      id: oldBook.id,
      title: oldBook.title,
      author: oldBook.author,
      coverUrl: oldBook.coverUrl,
      summary: oldBook.summary,
      characters: oldBook.characters,
      relationships: relationshipsByKey.values.toList(),
      keywords: oldBook.keywords,
      currentPage: oldBook.currentPage,
      totalPages: oldBook.totalPages,
      progress: oldBook.progress,
      isbn: oldBook.isbn,
      publisher: oldBook.publisher,
      publishedDate: oldBook.publishedDate,
      description: oldBook.description,
    );

    _books[index] = updatedBook;
    _saveBooks();
    notifyListeners();
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
      isbn: oldBook.isbn,
      publisher: oldBook.publisher,
      publishedDate: oldBook.publishedDate,
      description: oldBook.description,
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
        isbn: oldBook.isbn,
        publisher: oldBook.publisher,
        publishedDate: oldBook.publishedDate,
        description: oldBook.description,
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

  String _normalizeCharacterField(dynamic value) {
    return (value as String? ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _selectCharacterRole(String? existingRole, String incomingRole) {
    final existing = _normalizeCharacterField(existingRole);
    final incoming = _normalizeCharacterField(incomingRole);

    if (_isGenericCharacterRole(incoming)) {
      return existing.isEmpty ? '등장인물' : existing;
    }

    return incoming;
  }

  String _selectCharacterDescription(
    String? existingDescription,
    String incomingDescription,
  ) {
    final existing = _normalizeCharacterField(existingDescription);
    final incoming = _normalizeCharacterField(incomingDescription);

    if (_isEmptyCharacterDescription(incoming)) {
      return _isEmptyCharacterDescription(existing)
          ? '아직 상세 프로필이 없습니다.'
          : existing;
    }

    if (_isEmptyCharacterDescription(existing)) {
      return incoming;
    }

    final existingScore = _characterDescriptionScore(existing);
    final incomingScore = _characterDescriptionScore(incoming);
    return incomingScore >= existingScore + 12 ? incoming : existing;
  }

  bool _isGenericCharacterRole(String role) {
    const genericRoles = {'', '인물', '등장인물', '주요 인물', '주변 인물'};
    return genericRoles.contains(role);
  }

  bool _isEmptyCharacterDescription(String description) {
    return description.isEmpty || description == '아직 상세 프로필이 없습니다.';
  }

  int _characterDescriptionScore(String description) {
    final meaningfulWords = description
        .split(RegExp(r'\s+'))
        .where((word) => word.length > 1)
        .toSet()
        .length;
    const detailKeywords = {
      '관계',
      '갈등',
      '변화',
      '목표',
      '비밀',
      '현재',
      '상황',
      '태도',
      '성격',
      '때문',
      '하지만',
    };
    final detailScore = detailKeywords
        .where((keyword) => description.contains(keyword))
        .length;

    return description.length + meaningfulWords * 2 + detailScore * 10;
  }

  Character? _resolveCharacterReference(
    String value,
    List<Character> characters,
  ) {
    final normalized = _normalizeCharacterField(value);
    if (normalized.isEmpty) return null;

    for (final character in characters) {
      if (character.id == normalized || character.name == normalized) {
        return character;
      }
    }

    return null;
  }

  String? _relationshipKey(
    String source,
    String target,
    List<Character> characters,
  ) {
    final sourceCharacter = _resolveCharacterReference(source, characters);
    final targetCharacter = _resolveCharacterReference(target, characters);
    if (sourceCharacter == null || targetCharacter == null) return null;
    if (sourceCharacter.id == targetCharacter.id) return null;

    final ids = [sourceCharacter.id, targetCharacter.id]..sort();
    return '${ids[0]}__${ids[1]}';
  }

  String _selectRelationshipText(String? existingText, String incomingText) {
    final existing = _normalizeCharacterField(existingText);
    final incoming = _normalizeCharacterField(incomingText);

    if (incoming.isEmpty) return existing;
    if (existing.isEmpty) return incoming;

    return _relationshipTextScore(incoming) >=
            _relationshipTextScore(existing) + 8
        ? incoming
        : existing;
  }

  int _relationshipTextScore(String text) {
    final meaningfulWords = text
        .split(RegExp(r'\s+'))
        .where((word) => word.length > 1)
        .toSet()
        .length;
    const detailKeywords = {
      '관계',
      '신뢰',
      '갈등',
      '의심',
      '협력',
      '대립',
      '가족',
      '친구',
      '동료',
      '비밀',
      '변화',
    };
    final detailScore = detailKeywords
        .where((word) => text.contains(word))
        .length;
    return text.length + meaningfulWords * 2 + detailScore * 8;
  }

  int? _normalizeFirstPage(dynamic value) {
    final page = switch (value) {
      int number => number,
      double number => number.round(),
      String text => int.tryParse(text.trim()),
      _ => null,
    };
    if (page == null || page <= 0) return null;
    return page;
  }

  // 첫 등장 페이지는 분석을 거듭해도 가장 이른 페이지를 유지한다.
  int? _selectFirstPage(int? existing, int? incoming) {
    if (existing == null) return incoming;
    if (incoming == null) return existing;
    return existing < incoming ? existing : incoming;
  }

  int? _normalizeImportance(dynamic value) {
    final importance = switch (value) {
      int number => number,
      double number => number.round(),
      String text => int.tryParse(text.trim()),
      _ => null,
    };
    if (importance == null) return null;
    return importance.clamp(1, 5);
  }

  // 중요도는 분석을 거듭해도 가장 높게 평가된 값을 유지한다. 둘 다 없으면 보통(3).
  int _selectImportance(int? existing, int? incoming) {
    if (existing == null && incoming == null) return 3;
    if (existing == null) return incoming!;
    if (incoming == null) return existing;
    return existing > incoming ? existing : incoming;
  }

  int _normalizeRelationshipStrength(dynamic value) {
    final strength = switch (value) {
      int number => number,
      double number => number.round(),
      String text => int.tryParse(text) ?? 1,
      _ => 1,
    };
    return strength.clamp(1, 5);
  }

  int _selectRelationshipStrength(int? existingStrength, int incomingStrength) {
    return incomingStrength > (existingStrength ?? 1)
        ? incomingStrength
        : existingStrength ?? 1;
  }

  bool _looksLikeRealCharacter(String name, String role, String description) {
    if (name.isEmpty) return false;
    if (name == '이름 미상') return false;
    if (RegExp(r'^\d+$').hasMatch(name)) return false;
    if (name.length > 20) return false;
    if (RegExp(r'[.!?<>[\]{}]').hasMatch(name)) return false;

    const bannedExactNames = {
      '나',
      '너',
      '우리',
      '그',
      '그녀',
      '그들',
      '이들',
      '사람',
      '사람들',
      '인물',
      '등장인물',
      '주인공',
      '화자',
      '서술자',
      '독자',
      '학생',
      '학생들',
      '아이',
      '아이들',
      '어른',
      '어른들',
      '주민',
      '주민들',
      '마을 사람들',
      '군중',
      '모두',
      '누군가',
      '누구',
      '친구들',
      '가족',
      '부모',
      '형제들',
      '자매들',
    };

    if (bannedExactNames.contains(name)) return false;

    const bannedNameKeywords = {
      '일행',
      '무리',
      '사람들',
      '학생들',
      '아이들',
      '주민들',
      '형제들',
      '자매들',
      '선생님들',
      '친구들',
      '직원들',
      '경찰들',
      '병사들',
      '시민들',
    };

    if (bannedNameKeywords.any(name.contains)) return false;

    // 컴퓨터·기계·시스템 등 사물은 등장인물이 아니다.
    const machineKeywords = {
      '컴퓨터',
      '인공지능',
      '로봇',
      '기계',
      '시스템',
      '프로그램',
    };
    if (machineKeywords.any(name.contains)) return false;

    // '화자'·'서술'은 제외하지 않는다 — 1인칭 시점 주인공도 실제 핵심 인물이다.
    const genericRoleKeywords = {
      '단체',
      '집단',
      '배경',
      '군중',
      '마을 사람',
      '주민',
      '학생들',
      '아이들',
    };

    final combinedText = '$role $description';
    if (genericRoleKeywords.any(combinedText.contains) &&
        name.split(' ').length <= 2) {
      return false;
    }

    return true;
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
