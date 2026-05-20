import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../models/book.dart';
import '../services/gemini_service.dart';
import '../widgets/book_cover.dart';
import '../widgets/chat_bubble.dart';
import 'character_profile_screen.dart';

class BookDetailScreen extends StatefulWidget {
  const BookDetailScreen({required this.bookId, super.key});

  final String bookId;

  @override
  State<BookDetailScreen> createState() => _BookDetailScreenState();
}

class _BookDetailScreenState extends State<BookDetailScreen> {
  BookDetailTab _activeTab = BookDetailTab.summary;
  final TextEditingController _controller = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  final GeminiService _geminiService = GeminiService();
  bool _isSending = false;
  final List<_ChatMessage> _messages = [
    const _ChatMessage(
      role: ChatRole.assistant,
      content: '안녕하세요. 스캔·분석된 페이지 본문을 바탕으로 질문에 답하고, '
          '근거가 있는 페이지 번호도 함께 알려드려요.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _loadChatHistory();
  }

  @override
  void dispose() {
    _controller.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final book = AppStateScope.of(context).findBookById(widget.bookId);
    if (book == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('책을 찾을 수 없습니다.')),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF7),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            elevation: 0,
            backgroundColor: const Color(0xFFFDFBF7),
            foregroundColor: const Color(0xFF3A332D),
            title: Text(
              book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Row(
                children: [
                  BookCover(
                    imageUrl: book.coverUrl,
                    width: 54,
                    height: 78,
                    borderRadius: 8,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          book.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: const Color(0xFF7D746C)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
              child: Column(
                children: [
                  SegmentedButton<BookDetailTab>(
                    segments: const [
                      ButtonSegment(
                        value: BookDetailTab.summary,
                        label: Text('요약'),
                        icon: Icon(Icons.info_outline_rounded),
                      ),
                      ButtonSegment(
                        value: BookDetailTab.characters,
                        label: Text('인물'),
                        icon: Icon(Icons.people_alt_outlined),
                      ),
                      ButtonSegment(
                        value: BookDetailTab.map,
                        label: Text('관계'),
                        icon: Icon(Icons.hub_outlined),
                      ),
                      ButtonSegment(
                        value: BookDetailTab.chat,
                        label: Text('질문'),
                        icon: Icon(Icons.chat_bubble_outline_rounded),
                      ),
                    ],
                    selected: {_activeTab},
                    showSelectedIcon: false,
                    onSelectionChanged: (value) {
                      setState(() => _activeTab = value.first);
                    },
                  ),
                  const SizedBox(height: 24),
                  _buildTabContent(context, book),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabContent(BuildContext context, Book book) {
    // 채팅 카드 — 화면 아래 빈 공간을 최대한 채우도록 크게 잡는다.
    // 상단 영역(앱바·표지·탭) 합쳐 ~280px를 빼고 남은 높이를 쓴다.
    final mediaHeight = MediaQuery.of(context).size.height;
    final chatCardHeight = (mediaHeight - 280).clamp(380.0, 1200.0);

    switch (_activeTab) {
      case BookDetailTab.summary:
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '줄거리',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 460,
                  child: SingleChildScrollView(
                    child: Text(
                      book.summary.isEmpty ? '아직 요약이 없습니다.' : book.summary,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyLarge?.copyWith(height: 1.75),
                    ),
                  ),
                ),

                if (book.keywords.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: book.keywords
                        .map((keyword) => Chip(label: Text('#$keyword')))
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
        );
      case BookDetailTab.characters:
        if (book.characters.isEmpty) {
          return const _NoticeCard(message: '아직 기록된 인물 정보가 없습니다.');
        }
        final mainCharacters = book.characters
            .where((character) => character.importance > 1)
            .toList();
        final minorCharacters = book.characters
            .where((character) => character.importance <= 1)
            .toList();
        return Column(
          children: [
            ...mainCharacters.map(
              (character) => _CharacterCard(character: character),
            ),
            if (minorCharacters.isNotEmpty)
              _MinorCharactersSection(characters: minorCharacters),
          ],
        );
      case BookDetailTab.map:
        return _RelationshipSvgView(bookId: widget.bookId);
      case BookDetailTab.chat:
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              height: chatCardHeight,
              child: Column(
                children: [
                  Expanded(
                    child: ListView.separated(
                      controller: _chatScrollController,
                      padding: EdgeInsets.zero,
                      itemCount: _messages.length + (_isSending ? 1 : 0),
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        if (index >= _messages.length) {
                          return const _ThinkingBubble();
                        }
                        final message = _messages[index];
                        return ChatBubble(
                          role: message.role,
                          content: message.content,
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          minLines: 1,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            hintText: '질문을 입력해주세요.',
                            filled: true,
                            fillColor: Color(0xFFF9F6F1),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(18),
                              ),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: _isSending
                            ? null
                            : () => _sendQuestion(book),
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                          padding: const EdgeInsets.all(16),
                        ),
                        child: const Icon(Icons.send_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
    }
  }

  Future<void> _sendQuestion(Book book) async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      return;
    }

    setState(() {
      _isSending = true;
      _messages.add(_ChatMessage(role: ChatRole.user, content: text));
      _controller.clear();
    });
    _scrollChatToBottom();
    await _saveChatHistory();

    final answer = await _geminiService.answerBookQuestion(
      book: book,
      question: text,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _messages.add(
        _ChatMessage(role: ChatRole.assistant, content: answer),
      );
      _isSending = false;
    });
    _scrollChatToBottom();
    await _saveChatHistory();
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.jumpTo(
          _chatScrollController.position.maxScrollExtent,
        );
      }
    });
  }

  Future<File> _chatHistoryFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final booksDir = Directory(p.join(dir.path, 'books'));
    if (!await booksDir.exists()) {
      await booksDir.create(recursive: true);
    }
    return File(p.join(booksDir.path, '${widget.bookId}_chat.json'));
  }

  Future<void> _loadChatHistory() async {
    try {
      final file = await _chatHistoryFile();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final loaded = <_ChatMessage>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final content = item['content'];
        if (content is! String || content.isEmpty) continue;
        loaded.add(
          _ChatMessage(
            role: item['role'] == 'user' ? ChatRole.user : ChatRole.assistant,
            content: content,
          ),
        );
      }
      if (loaded.isEmpty || !mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(loaded);
      });
      _scrollChatToBottom();
    } catch (_) {
      // 대화 기록을 못 읽으면 기본 인사말만 그대로 둔다.
    }
  }

  Future<void> _saveChatHistory() async {
    try {
      final file = await _chatHistoryFile();
      final data = _messages
          .map(
            (message) => {
              'role': message.role == ChatRole.user ? 'user' : 'assistant',
              'content': message.content,
            },
          )
          .toList();
      await file.writeAsString(jsonEncode(data));
    } catch (_) {
      // 저장 실패는 조용히 무시 — 다음 질문 때 다시 시도된다.
    }
  }
}

enum BookDetailTab { summary, characters, map, chat }

class _CharacterCard extends StatelessWidget {
  const _CharacterCard({required this.character});

  final Character character;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CharacterProfileScreen(character: character),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        character.name,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: Color(0xFF9C5B22),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3EFE8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(character.role),
                ),
                const SizedBox(height: 10),
                Text(
                  character.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.5,
                    color: const Color(0xFF6F675F),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MinorCharactersSection extends StatefulWidget {
  const _MinorCharactersSection({required this.characters});

  final List<Character> characters;

  @override
  State<_MinorCharactersSection> createState() =>
      _MinorCharactersSectionState();
}

class _MinorCharactersSectionState extends State<_MinorCharactersSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '기타 인물 ${widget.characters.length}명',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: const Color(0xFF9C5B22),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 14),
          ...widget.characters.map(
            (character) => _CharacterCard(character: character),
          ),
        ],
      ],
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: SizedBox(
        height: 220,
        child: Center(
          child: Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: const Color(0xFF7D746C)),
          ),
        ),
      ),
    );
  }
}

class _RelationshipSvgView extends StatefulWidget {
  const _RelationshipSvgView({required this.bookId});

  final String bookId;

  @override
  State<_RelationshipSvgView> createState() => _RelationshipSvgViewState();
}

class _RelationshipSvgViewState extends State<_RelationshipSvgView> {
  bool _loading = true;
  String? _svg;

  @override
  void initState() {
    super.initState();
    _loadSvg();
  }

  Future<void> _loadSvg() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
        p.join(dir.path, 'books', '${widget.bookId}_relmap.svg'),
      );
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty && mounted) {
          setState(() {
            _svg = content;
            _loading = false;
          });
          return;
        }
      }
    } catch (_) {
      // 관계도를 못 읽으면 안내 문구를 보여준다.
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Card(
        margin: EdgeInsets.zero,
        child: SizedBox(
          height: 220,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final svg = _svg;
    if (svg == null) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                '아직 관계도가 없어요.\n분석 직후라면 관계도를 만드는 중일 수 있으니 '
                '잠시 뒤 다시 불러와 주세요.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF7D746C),
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () {
                  setState(() => _loading = true);
                  _loadSvg();
                },
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('다시 불러오기'),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '인물 관계도',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              '두 손가락으로 확대·이동할 수 있어요.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF7D746C)),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                color: const Color(0xFFFDFBF7),
                height: 460,
                width: double.infinity,
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 6,
                  child: SvgPicture.string(
                    svg,
                    fit: BoxFit.contain,
                    placeholderBuilder: (_) =>
                        const Center(child: CircularProgressIndicator()),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatMessage {
  const _ChatMessage({required this.role, required this.content});

  final ChatRole role;
  final String content;
}

class _ThinkingBubble extends StatefulWidget {
  const _ThinkingBubble();

  @override
  State<_ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<_ThinkingBubble> {
  Timer? _timer;
  int _dotCount = 1;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 450), (_) {
      if (mounted) {
        setState(() => _dotCount = _dotCount % 3 + 1);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(
            18,
          ).copyWith(bottomLeft: const Radius.circular(4)),
          border: Border.all(color: const Color(0xFFE4DDD6)),
        ),
        child: Text(
          '생각 중${'.' * _dotCount}',
          style: const TextStyle(color: Color(0xFF8B8178), height: 1.5),
        ),
      ),
    );
  }
}
