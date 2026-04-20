import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/book.dart';
import '../services/claude_service.dart';
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
  final ClaudeService _claudeService = ClaudeService();
  bool _isSending = false;
  final List<_ChatMessage> _messages = [
    const _ChatMessage(
      role: ChatRole.assistant,
      content: '안녕하세요. 이 책의 요약과 등장인물, 관계를 바탕으로 질문하실 수 있어요.',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
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
            expandedHeight: 340,
            backgroundColor: const Color(0xFFFDFBF7),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(book.coverUrl, fit: BoxFit.cover),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.2),
                          Colors.black.withValues(alpha: 0.75),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 28,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.title,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          book.author,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: Colors.white.withValues(alpha: 0.85),
                              ),
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
    final chatCardHeight = (MediaQuery.of(context).size.height * 0.26).clamp(
      220.0,
      280.0,
    );

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
        return Column(
          children: book.characters
              .map(
                (character) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => CharacterProfileScreen(
                              book: book,
                              character: character,
                            ),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            BookCover(
                              imageUrl: character.imageUrl,
                              width: 64,
                              height: 64,
                              borderRadius: 18,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    character.name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
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
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          height: 1.5,
                                          color: const Color(0xFF6F675F),
                                        ),
                                  ),
                                  const SizedBox(height: 10),
                                  const Text(
                                    '프로필 보기',
                                    style: TextStyle(
                                      color: Color(0xFF9C5B22),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        );
      case BookDetailTab.map:
        if (book.characters.length < 3 || book.relationships.length < 3) {
          return const _NoticeCard(message: '관계 지도를 그리기에는 인물 정보가 아직 부족합니다.');
        }
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              height: 320,
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: CustomPaint(painter: _RelationshipLinesPainter()),
                  ),
                  _Node(
                    alignment: const Alignment(0, -0.85),
                    name: book.characters[0].name,
                    imageUrl: book.characters[0].imageUrl,
                  ),
                  _Node(
                    alignment: const Alignment(-0.8, 0.78),
                    name: book.characters[1].name,
                    imageUrl: book.characters[1].imageUrl,
                  ),
                  _Node(
                    alignment: const Alignment(0.8, 0.78),
                    name: book.characters[2].name,
                    imageUrl: book.characters[2].imageUrl,
                  ),
                  _EdgeLabel(
                    alignment: const Alignment(-0.42, -0.02),
                    text: book.relationships[0].label,
                  ),
                  _EdgeLabel(
                    alignment: const Alignment(0.42, -0.02),
                    text: book.relationships[1].label,
                  ),
                  _EdgeLabel(
                    alignment: const Alignment(0, 0.67),
                    text: book.relationships[2].label,
                  ),
                ],
              ),
            ),
          ),
        );
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
                      padding: EdgeInsets.zero,
                      itemCount: _messages.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
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
                            : () => _sendMessageWithClaude(book),
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

  Future<void> _sendMessageWithClaude(Book book) async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      return;
    }

    setState(() {
      _isSending = true;
      _messages.add(_ChatMessage(role: ChatRole.user, content: text));
      _controller.clear();
    });

    final answer = await _claudeService.answerBookQuestion(
      book: book,
      question: text,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _messages.add(
        _ChatMessage(
          role: ChatRole.assistant,
          content:
              answer ??
              'Claude API가 아직 연결되지 않았거나 응답을 받지 못했습니다. API를 연결하면 더 자연스러운 답변을 받을 수 있어요.',
        ),
      );
      _isSending = false;
    });
  }
}

enum BookDetailTab { summary, characters, map, chat }

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

class _Node extends StatelessWidget {
  const _Node({
    required this.alignment,
    required this.name,
    required this.imageUrl,
  });

  final Alignment alignment;
  final String name;
  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BookCover(
            imageUrl: imageUrl,
            width: 72,
            height: 72,
            borderRadius: 36,
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE4DDD6)),
            ),
            child: Text(
              name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _EdgeLabel extends StatelessWidget {
  const _EdgeLabel({required this.alignment, required this.text});

  final Alignment alignment;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7EC),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFF1DEC0)),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Color(0xFF9C5B22),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _RelationshipLinesPainter extends CustomPainter {
  const _RelationshipLinesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFD8D0C7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final top = Offset(size.width / 2, 62);
    final left = Offset(82, size.height - 80);
    final right = Offset(size.width - 82, size.height - 80);

    canvas.drawLine(top, left, paint);
    canvas.drawLine(top, right, paint);
    canvas.drawLine(left, right, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ChatMessage {
  const _ChatMessage({required this.role, required this.content});

  final ChatRole role;
  final String content;
}

class _MetaInfo extends StatelessWidget {
  const _MetaInfo({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: const Color(0xFF7D746C)),
        ),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
