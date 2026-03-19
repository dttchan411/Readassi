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

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'role': role,
      'description': description,
      'imageUrl': imageUrl,
    };
  }

  factory Character.fromJson(Map<String, dynamic> json) {
    return Character(
      id: json['id'] as String,
      name: json['name'] as String,
      role: json['role'] as String,
      description: json['description'] as String,
      imageUrl: json['imageUrl'] as String,
    );
  }
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

  Map<String, dynamic> toJson() {
    return {'source': source, 'target': target, 'label': label};
  }

  factory Relationship.fromJson(Map<String, dynamic> json) {
    return Relationship(
      source: json['source'] as String,
      target: json['target'] as String,
      label: json['label'] as String,
    );
  }
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

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'coverUrl': coverUrl,
      'summary': summary,
      'keywords': keywords,
      'characters': characters.map((character) => character.toJson()).toList(),
      'relationships': relationships
          .map((relationship) => relationship.toJson())
          .toList(),
      'currentPage': currentPage,
      'totalPages': totalPages,
      'progress': progress,
    };
  }

  factory Book.fromJson(Map<String, dynamic> json) {
    return Book(
      id: json['id'] as String,
      title: json['title'] as String,
      author: json['author'] as String,
      coverUrl: json['coverUrl'] as String,
      summary: json['summary'] as String,
      keywords: (json['keywords'] as List<dynamic>? ?? const [])
          .map((keyword) => keyword as String)
          .toList(),
      characters: (json['characters'] as List<dynamic>? ?? const [])
          .map((character) => Character.fromJson(character as Map<String, dynamic>))
          .toList(),
      relationships: (json['relationships'] as List<dynamic>? ?? const [])
          .map(
            (relationship) =>
                Relationship.fromJson(relationship as Map<String, dynamic>),
          )
          .toList(),
      currentPage: json['currentPage'] as int?,
      totalPages: json['totalPages'] as int?,
      progress: json['progress'] as int?,
    );
  }

  int get progressPercent {
    if (totalPages != null && totalPages! > 0) {
      return (((currentPage ?? 0) / totalPages!) * 100).round();
    }
    return progress ?? 0;
  }
}
