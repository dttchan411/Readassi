class Character {
  const Character({
    required this.id,
    required this.name,
    required this.role,
    required this.description,
    required this.imageUrl,
  });

  final String id;
  final String name;
  final String role;
  final String description;
  final String imageUrl;
}

class Relationship {
  const Relationship({
    required this.source,
    required this.target,
    required this.label,
  });

  final String source;
  final String target;
  final String label;
}

class Book {
  const Book({
    required this.id,
    required this.title,
    required this.author,
    required this.coverUrl,
    required this.summary,
    required this.characters,
    required this.relationships,
    this.keywords = const [],
    this.currentPage,
    this.totalPages,
    this.progress,
  });

  final String id;
  final String title;
  final String author;
  final String coverUrl;
  final String summary;
  final List<String> keywords;
  final List<Character> characters;
  final List<Relationship> relationships;
  final int? currentPage;
  final int? totalPages;
  final int? progress;

  int get progressPercent {
    if (totalPages != null && totalPages! > 0) {
      return (((currentPage ?? 0) / totalPages!) * 100).round();
    }
    return progress ?? 0;
  }
}
