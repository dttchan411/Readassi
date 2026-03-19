import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/book.dart';

class ClaudeService {
  ClaudeService({http.Client? client}) : _client = client ?? http.Client();

  static const _apiKey = String.fromEnvironment('ANTHROPIC_API_KEY');
  static const _model = String.fromEnvironment(
    'ANTHROPIC_MODEL',
    defaultValue: 'claude-sonnet-4-20250514',
  );
  static const _apiUrl = 'https://api.anthropic.com/v1/messages';
  static const _anthropicVersion = '2023-06-01';

  final http.Client _client;

  bool get isConfigured => _apiKey.trim().isNotEmpty;

  Future<ClaudeAnalysisResult?> analyzeScanText(String text) async {
    if (!isConfigured || text.trim().isEmpty) {
      return null;
    }

    final responseText = await _sendMessage(
      system:
          'You analyze OCR text from a Korean reading assistant app. '
          'Return only valid JSON with keys summary, keywords, characters. '
          'summary must be a short Korean summary string. '
          'keywords must be an array of 2 to 5 short Korean strings. '
          'characters must be an array of objects with name and description. '
          'If character names are unclear, return an empty array for characters.',
      userPrompt:
          'OCR text:\n$text\n\nReturn JSON only. Do not wrap in markdown.',
      maxTokens: 700,
    );

    if (responseText == null) {
      return null;
    }

    final decoded = _tryDecodeJsonObject(responseText);
    if (decoded == null) {
      return null;
    }

    return ClaudeAnalysisResult.fromJson(decoded);
  }

  Future<String?> answerBookQuestion({
    required Book book,
    required String question,
  }) async {
    if (!isConfigured || question.trim().isEmpty) {
      return null;
    }

    final characterSummary = book.characters
        .map((character) => '${character.name}: ${character.description}')
        .join('\n');
    final relationshipSummary = book.relationships
        .map((relationship) => '${relationship.source} -> ${relationship.target}: ${relationship.label}')
        .join('\n');

    return _sendMessage(
      system:
          'You are a Korean reading assistant. Answer in natural Korean. '
          'Base your answer only on the provided book information. '
          'If the information is insufficient, say that clearly and answer cautiously.',
      userPrompt: '''
책 제목: ${book.title}
저자: ${book.author}
요약: ${book.summary}
키워드: ${book.keywords.join(', ')}
등장인물:
$characterSummary

관계:
$relationshipSummary

질문:
$question
''',
      maxTokens: 500,
    );
  }

  Future<String?> _sendMessage({
    required String system,
    required String userPrompt,
    required int maxTokens,
  }) async {
    try {
      final response = await _client.post(
        Uri.parse(_apiUrl),
        headers: const {
          'content-type': 'application/json',
          'anthropic-version': _anthropicVersion,
          'x-api-key': _apiKey,
        },
        body: jsonEncode({
          'model': _model,
          'max_tokens': maxTokens,
          'system': system,
          'messages': [
            {
              'role': 'user',
              'content': userPrompt,
            },
          ],
        }),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final content = decoded['content'] as List<dynamic>? ?? const [];
      if (content.isEmpty) {
        return null;
      }

      final first = content.first as Map<String, dynamic>;
      return (first['text'] as String?)?.trim();
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _tryDecodeJsonObject(String text) {
    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start == -1 || end == -1 || end <= start) {
        return null;
      }

      try {
        return jsonDecode(text.substring(start, end + 1)) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }
  }
}

class ClaudeAnalysisResult {
  ClaudeAnalysisResult({
    required this.summary,
    required this.keywords,
    required this.characters,
  });

  final String summary;
  final List<String> keywords;
  final List<ClaudeCharacterResult> characters;

  factory ClaudeAnalysisResult.fromJson(Map<String, dynamic> json) {
    return ClaudeAnalysisResult(
      summary: (json['summary'] as String? ?? '').trim(),
      keywords: (json['keywords'] as List<dynamic>? ?? const [])
          .map((item) => item as String)
          .where((item) => item.trim().isNotEmpty)
          .toList(),
      characters: (json['characters'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClaudeCharacterResult.fromJson)
          .toList(),
    );
  }
}

class ClaudeCharacterResult {
  ClaudeCharacterResult({
    required this.name,
    required this.description,
  });

  final String name;
  final String description;

  factory ClaudeCharacterResult.fromJson(Map<String, dynamic> json) {
    return ClaudeCharacterResult(
      name: (json['name'] as String? ?? '').trim(),
      description: (json['description'] as String? ?? '').trim(),
    );
  }
}
