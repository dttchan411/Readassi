import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../models/book.dart';

class ClaudeService {
  ClaudeService({http.Client? client}) : _client = client ?? http.Client();

  static const _compileTimeApiKey = String.fromEnvironment('ANTHROPIC_API_KEY');
  static const _compileTimeModel = String.fromEnvironment(
    'ANTHROPIC_MODEL',
    defaultValue: 'claude-sonnet-4-6',
  );
  static const _apiUrl = 'https://api.anthropic.com/v1/messages';
  static const _anthropicVersion = '2023-06-01';

  final http.Client _client;

  String get _apiKey {
    final envKey = dotenv.env['ANTHROPIC_API_KEY'] ?? '';
    return envKey.trim().isNotEmpty ? envKey : _compileTimeApiKey;
  }

  String get _model {
    final envModel = dotenv.env['ANTHROPIC_MODEL'] ?? '';
    return envModel.trim().isNotEmpty ? envModel : _compileTimeModel;
  }

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

  Future<ClaudeCharacterRelationResult?> analyzeCharactersAndRelationships({
    required Book book,
    required String newText,
    required String existingCharacterDb,
  }) async {
    if (!isConfigured || newText.trim().isEmpty) {
      return null;
    }

    final existingCharacters = book.characters
        .map(
          (character) =>
              '- ${character.name} / ${character.role}: ${character.description}',
        )
        .join('\n');
    final existingRelationships = book.relationships
        .map(
          (relationship) =>
              '- ${relationship.source} - ${relationship.target}: '
              '${relationship.label}, ${relationship.description}',
        )
        .join('\n');

    final responseText = await _sendMessage(
      system:
          'You are a Korean literary character-relationship analyst. '
          'Return only valid JSON. Do not wrap in markdown. '
          'Never invent facts that are not supported by the provided text or existing data.',
      userPrompt:
          '''
책 제목: ${book.title}
저자: ${book.author}

[기존 앱 인물]
$existingCharacters

[기존 앱 관계]
$existingRelationships

[기존 내부 인물 DB]
$existingCharacterDb

[새로 스캔된 OCR 텍스트]
$newText

다음 JSON 객체만 반환하세요.
{
  "characters": [
    {
      "name": "실제 등장인물 이름",
      "role": "짧은 역할",
      "description": "한국어 2~3문장 누적 인물 요약"
    }
  ],
  "relationships": [
    {
      "source": "characters에 포함된 실제 인물 이름",
      "target": "characters에 포함된 실제 인물 이름",
      "label": "친구|가족|협력|대립|스승과 제자|의심|보호 등 짧은 관계명",
      "description": "두 인물의 현재 관계를 한국어 1~2문장으로 설명",
      "evidence": "제공된 텍스트나 기존 데이터에서 확인되는 근거 요약",
      "strength": 1,
      "type": "ally|family|conflict|romance|mentor|mystery|neutral"
    }
  ]
}

규칙:
- characters에는 실제 등장인물만 넣으세요. 군중, 사람들, 장소, 단체, 개념, 서술자, 주인공 같은 일반 표현은 제외하세요.
- 기존 인물 데이터가 있으면 새 텍스트와 합쳐 누적 업데이트하세요. 새 텍스트에 없다는 이유만으로 기존 사실을 지우지 마세요.
- relationships는 characters에 포함된 이름만 source/target으로 쓰세요.
- 관계가 확인되면 최소 1개 이상 작성하세요. 단, 근거가 전혀 없으면 빈 배열을 반환하세요.
- strength는 1~5 정수입니다. 잠깐 언급은 1, 반복되고 서사적으로 중요한 관계는 5입니다.
- 관계 설명에는 추측이나 미래 예측을 넣지 마세요.
''',
      maxTokens: 1500,
    );

    if (responseText == null) {
      return null;
    }

    final decoded = _tryDecodeJsonObject(responseText);
    if (decoded == null) {
      return null;
    }

    return ClaudeCharacterRelationResult.fromJson(decoded);
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
        .map(
          (relationship) =>
              '${relationship.source} -> ${relationship.target}: ${relationship.label}',
        )
        .join('\n');

    return _sendMessage(
      system:
          'You are a Korean reading assistant. Answer in natural Korean. '
          'Base your answer only on the provided book information. '
          'If the information is insufficient, say that clearly and answer cautiously.',
      userPrompt:
          '''
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

  /// 책 전체 본문을 Claude에 주고, 인물 관계도를 SVG 한 장으로 받는다.
  /// 성공 시 `<svg ...>...</svg>` 문자열을, 실패 시 null을 반환한다.
  Future<String?> generateRelationshipSvg({
    required Book book,
    required String fullText,
  }) async {
    if (!isConfigured || fullText.trim().isEmpty) {
      return null;
    }

    final characterNames = book.characters
        .map((character) => character.name)
        .where((name) => name.trim().isNotEmpty)
        .join(', ');

    final raw = await _sendMessage(
      system:
          'You generate a clean, readable character-relationship diagram as a '
          'single self-contained SVG. Output ONLY raw SVG markup that starts '
          'with <svg and ends with </svg>. No markdown, no code fences, no '
          'explanation.',
      userPrompt:
          '''
다음은 한국어 책 "${book.title}"의 본문입니다. 등장인물 사이의 관계를 한눈에 볼 수 있는 관계도를 SVG 하나로 그리세요.

[주요 등장인물]
$characterNames

[책 본문]
$fullText

요구사항:
- 출력은 오직 SVG 마크업 하나입니다. <svg ...> ... </svg> 외에는 아무것도 출력하지 마세요.
- 루트 <svg>에 width="800", height="600", viewBox="0 0 800 600"을 지정하세요.
- 각 인물은 노드(원 또는 둥근 사각형 + 이름 텍스트)로, 두 인물의 관계는 둘을 잇는 선으로 그리세요.
- 선 가운데에 짧은 관계명(예: 친구, 동료, 가족, 대립, 연인)을 텍스트로 표시하세요.
- 노드끼리, 그리고 선·텍스트가 서로 겹치지 않게 충분히 간격을 두세요. 비중이 큰 인물은 가운데에, 비중이 낮은 인물은 바깥쪽에 배치하세요.
- 가독성이 가장 중요합니다. 인물은 8명 이하, 관계선은 12개 이하로 핵심만 추리세요.
- 모든 글자는 한국어로, 크기는 13~16 정도로 또렷하게 쓰세요.
- 배경은 연한 베이지(#FDFBF7), 색은 단순하게 쓰세요.
- <filter>, <style>(CSS), 외부 폰트, <image>는 사용하지 마세요. circle, rect, line, path, polygon, text 같은 기본 도형과 fill·stroke 속성만 쓰세요.
''',
      maxTokens: 8000,
    );

    if (raw == null) {
      return null;
    }

    final start = raw.indexOf('<svg');
    final end = raw.lastIndexOf('</svg>');
    if (start == -1 || end == -1 || end <= start) {
      debugPrint(
        '[ClaudeService] SVG 태그를 찾지 못함 — 응답 앞부분: ${_truncate(raw)}',
      );
      return null;
    }
    return raw.substring(start, end + 6);
  }

  String _truncate(String value, [int max = 600]) {
    final trimmed = value.trim();
    return trimmed.length <= max ? trimmed : '${trimmed.substring(0, max)}…';
  }

  Future<String?> _sendMessage({
    required String system,
    required String userPrompt,
    required int maxTokens,
  }) async {
    try {
      final response = await _client.post(
        Uri.parse(_apiUrl),
        headers: {
          'content-type': 'application/json',
          'anthropic-version': _anthropicVersion,
          'x-api-key': _apiKey,
        },
        body: jsonEncode({
          'model': _model,
          'max_tokens': maxTokens,
          'system': system,
          'messages': [
            {'role': 'user', 'content': userPrompt},
          ],
        }),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint(
          '[ClaudeService] HTTP ${response.statusCode} (model=$_model) — '
          '${_truncate(response.body)}',
        );
        return null;
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final content = decoded['content'] as List<dynamic>? ?? const [];
      if (content.isEmpty) {
        debugPrint(
          '[ClaudeService] 빈 content — ${_truncate(response.body)}',
        );
        return null;
      }

      final first = content.first as Map<String, dynamic>;
      return (first['text'] as String?)?.trim();
    } catch (e) {
      debugPrint('[ClaudeService] 예외: $e');
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
        return jsonDecode(text.substring(start, end + 1))
            as Map<String, dynamic>;
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
    this.role = '',
  });

  final String name;
  final String description;
  final String role;

  factory ClaudeCharacterResult.fromJson(Map<String, dynamic> json) {
    return ClaudeCharacterResult(
      name: (json['name'] as String? ?? '').trim(),
      description: (json['description'] as String? ?? '').trim(),
      role: (json['role'] as String? ?? '').trim(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'name': name, 'role': role, 'description': description};
  }
}

class ClaudeRelationshipResult {
  ClaudeRelationshipResult({
    required this.source,
    required this.target,
    required this.label,
    required this.description,
    required this.evidence,
    required this.strength,
    required this.type,
  });

  final String source;
  final String target;
  final String label;
  final String description;
  final String evidence;
  final int strength;
  final String type;

  factory ClaudeRelationshipResult.fromJson(Map<String, dynamic> json) {
    final rawStrength = json['strength'];
    final strength = switch (rawStrength) {
      int value => value,
      double value => value.round(),
      String value => int.tryParse(value) ?? 1,
      _ => 1,
    };

    return ClaudeRelationshipResult(
      source: ((json['source'] as String?) ?? (json['from'] as String?) ?? '')
          .trim(),
      target: ((json['target'] as String?) ?? (json['to'] as String?) ?? '')
          .trim(),
      label: (json['label'] as String? ?? '').trim(),
      description: (json['description'] as String? ?? '').trim(),
      evidence: (json['evidence'] as String? ?? '').trim(),
      strength: strength.clamp(1, 5),
      type: (json['type'] as String? ?? 'neutral').trim(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'source': source,
      'target': target,
      'label': label,
      'description': description,
      'evidence': evidence,
      'strength': strength,
      'type': type,
    };
  }
}

class ClaudeCharacterRelationResult {
  ClaudeCharacterRelationResult({
    required this.characters,
    required this.relationships,
  });

  final List<ClaudeCharacterResult> characters;
  final List<ClaudeRelationshipResult> relationships;

  factory ClaudeCharacterRelationResult.fromJson(Map<String, dynamic> json) {
    return ClaudeCharacterRelationResult(
      characters: (json['characters'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClaudeCharacterResult.fromJson)
          .where((character) => character.name.isNotEmpty)
          .toList(),
      relationships: (json['relationships'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClaudeRelationshipResult.fromJson)
          .where(
            (relationship) =>
                relationship.source.isNotEmpty &&
                relationship.target.isNotEmpty &&
                relationship.label.isNotEmpty,
          )
          .toList(),
    );
  }

  List<Map<String, dynamic>> charactersAsJson() {
    return characters.map((character) => character.toJson()).toList();
  }

  List<Map<String, dynamic>> relationshipsAsJson() {
    return relationships.map((relationship) => relationship.toJson()).toList();
  }
}
