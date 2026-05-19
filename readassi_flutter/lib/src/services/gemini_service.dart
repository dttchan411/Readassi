import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';

/// 페이지 인용 Q&A — 영구 페이지 본문 저장소(`<bookId>_pagetext.json`)를 읽어,
/// 질문에 대해 근거 페이지 번호까지 들어 Gemini로 답한다.
class GeminiService {
  GeminiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _model = 'gemini-2.5-flash';
  static const _endpoint =
      'https://generativelanguage.googleapis.com/v1beta/models';

  String get _apiKey => dotenv.env['_geminiApiKey'] ?? '';
  bool get isConfigured => _apiKey.trim().isNotEmpty;

  /// 질문에 대해 항상 사용자에게 보여줄 한국어 문자열을 돌려준다
  /// (오류·미설정·본문 없음도 안내 문구로 반환).
  Future<String> answerBookQuestion({
    required Book book,
    required String question,
  }) async {
    if (!isConfigured) {
      return 'Gemini API 키가 설정되어 있지 않아 답변할 수 없습니다.';
    }

    final pageText = await _loadPageText(book.id);
    if (pageText.isEmpty) {
      return '아직 보관된 페이지 본문이 없어요. 페이지를 스캔하고 분석을 한 번 '
          '실행하면, 그다음부터 책 내용을 페이지까지 짚어 답해드릴 수 있어요.';
    }

    final prompt =
        '''
당신은 한국어 독서 보조 도우미입니다. 사용자의 질문에 대해 아래 '페이지별 본문'에서
근거를 찾아 답하세요.

규칙:
- 반드시 제공된 페이지별 본문에 근거해서만 답하세요. 본문에 없는 내용은 지어내지 마세요.
- 답을 찾으면 근거가 되는 페이지 번호를 함께 알려주세요. 예: "37페이지에 나와요."
- 본문에서 찾을 수 없으면 솔직하게 모른다고 말하세요.
- 자연스러운 한국어로 2~4문장 이내로 간결하게 답하세요.
- 본문은 OCR로 추출되어 오타·잡음이 있을 수 있으니 감안해서 읽으세요.

책 제목: ${book.title}
저자: ${book.author}

[페이지별 본문]
${_buildPageBlock(pageText)}

[질문]
$question
''';

    try {
      final response = await _client.post(
        Uri.parse('$_endpoint/$_model:generateContent?key=$_apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': prompt},
              ],
            },
          ],
          'generationConfig': {'temperature': 0.3},
        }),
      );
      if (response.statusCode != 200) {
        return '답변을 가져오지 못했습니다. 잠시 후 다시 시도해주세요.';
      }
      final decoded = jsonDecode(response.body);
      final text =
          decoded['candidates']?[0]?['content']?['parts']?[0]?['text']
              as String?;
      if (text == null || text.trim().isEmpty) {
        return '답변을 가져오지 못했습니다. 잠시 후 다시 시도해주세요.';
      }
      return text.trim();
    } catch (_) {
      return '답변 중 오류가 발생했습니다. 네트워크 상태를 확인해주세요.';
    }
  }

  // 영구 페이지 본문 저장소를 읽어 {페이지번호: 본문} 맵으로 돌려준다.
  Future<Map<int, String>> _loadPageText(String bookId) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
        p.join(dir.path, 'books', '${bookId}_pagetext.json'),
      );
      if (!await file.exists()) return {};
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <int, String>{};
      decoded.forEach((key, value) {
        final pageNumber = int.tryParse(key.toString());
        if (pageNumber != null && value is String && value.trim().isNotEmpty) {
          result[pageNumber] = value;
        }
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  // 페이지 번호 순으로 정렬해 '=== N쪽 ===' 구분자와 함께 한 덩어리로 만든다.
  String _buildPageBlock(Map<int, String> pageText) {
    final pages = pageText.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final pageNumber in pages) {
      buffer.writeln('=== $pageNumber쪽 ===');
      buffer.writeln(pageText[pageNumber]!.trim());
      buffer.writeln();
    }
    return buffer.toString();
  }
}
