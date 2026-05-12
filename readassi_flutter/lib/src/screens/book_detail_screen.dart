import 'dart:math' as math;

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
        if (book.characters.length < 2 || book.relationships.isEmpty) {
          return const _NoticeCard(message: '관계 지도를 그리기에는 인물 정보가 아직 부족합니다.');
        }
        return _RelationshipMapView(book: book);
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

class _RelationshipMapView extends StatelessWidget {
  const _RelationshipMapView({required this.book});

  static const _maxVisibleRelationships = 12;
  static const _maxVisibleCharacters = 8;

  final Book book;

  @override
  Widget build(BuildContext context) {
    final graph = _RelationshipGraphData.fromBook(
      book,
      maxRelationships: _maxVisibleRelationships,
      maxCharacters: _maxVisibleCharacters,
    );

    if (graph.relationships.isEmpty) {
      return const _NoticeCard(message: '표시할 수 있는 인물 관계가 아직 없습니다.');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final height = width < 420 ? 430.0 : 470.0;
                final positions = graph.buildPositions(Size(width, height));

                return SizedBox(
                  height: height,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _RelationshipGraphPainter(
                            relationships: graph.relationships,
                            positions: positions,
                          ),
                        ),
                      ),
                      for (final character in graph.characters)
                        _GraphNode(
                          character: character,
                          position: positions[character.id]!,
                          isHub: character.id == graph.hub.id,
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
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '주요 관계',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        ...graph.relationships.map(
          (relationship) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _RelationshipSummaryTile(edge: relationship),
          ),
        ),
      ],
    );
  }
}

class _RelationshipGraphData {
  const _RelationshipGraphData({
    required this.characters,
    required this.relationships,
    required this.hub,
  });

  final List<Character> characters;
  final List<_ResolvedRelationship> relationships;
  final Character hub;

  factory _RelationshipGraphData.fromBook(
    Book book, {
    required int maxRelationships,
    required int maxCharacters,
  }) {
    final resolved =
        book.relationships
            .map(
              (relationship) =>
                  _ResolvedRelationship.tryCreate(book, relationship),
            )
            .whereType<_ResolvedRelationship>()
            .toList()
          ..sort(
            (a, b) =>
                b.relationship.strength.compareTo(a.relationship.strength),
          );

    final degree = <String, int>{};
    for (final edge in resolved) {
      degree[edge.source.id] =
          (degree[edge.source.id] ?? 0) + edge.relationship.strength;
      degree[edge.target.id] =
          (degree[edge.target.id] ?? 0) + edge.relationship.strength;
    }

    final rankedCharacters =
        book.characters
            .where((character) => degree.containsKey(character.id))
            .toList()
          ..sort((a, b) => (degree[b.id] ?? 0).compareTo(degree[a.id] ?? 0));

    final visibleCharacters = rankedCharacters.take(maxCharacters).toList();
    final visibleIds = visibleCharacters
        .map((character) => character.id)
        .toSet();
    final visibleRelationships = resolved
        .where(
          (edge) =>
              visibleIds.contains(edge.source.id) &&
              visibleIds.contains(edge.target.id),
        )
        .take(maxRelationships)
        .toList();

    final hub = visibleCharacters.isEmpty
        ? book.characters.first
        : visibleCharacters.first;
    return _RelationshipGraphData(
      characters: visibleCharacters.isEmpty ? [hub] : visibleCharacters,
      relationships: visibleRelationships,
      hub: hub,
    );
  }

  Map<String, Offset> buildPositions(Size size) {
    final positions = <String, Offset>{};
    final center = Offset(size.width / 2, size.height * 0.46);
    positions[hub.id] = center;

    final outerCharacters = characters
        .where((character) => character.id != hub.id)
        .toList();
    if (outerCharacters.isEmpty) return positions;

    final horizontalRadius = math.max(96.0, size.width * 0.36).toDouble();
    final verticalRadius = size.height * 0.32;
    final startAngle = -math.pi / 2;

    for (var index = 0; index < outerCharacters.length; index++) {
      final angle = startAngle + (math.pi * 2 * index / outerCharacters.length);
      final x = center.dx + math.cos(angle) * horizontalRadius;
      final y = center.dy + math.sin(angle) * verticalRadius;
      positions[outerCharacters[index].id] = Offset(
        x.clamp(58.0, size.width - 58.0).toDouble(),
        y.clamp(62.0, size.height - 58.0).toDouble(),
      );
    }

    return positions;
  }
}

class _ResolvedRelationship {
  const _ResolvedRelationship({
    required this.relationship,
    required this.source,
    required this.target,
  });

  final Relationship relationship;
  final Character source;
  final Character target;

  static _ResolvedRelationship? tryCreate(
    Book book,
    Relationship relationship,
  ) {
    final source = _findCharacter(book, relationship.source);
    final target = _findCharacter(book, relationship.target);
    if (source == null || target == null || source.id == target.id) {
      return null;
    }

    return _ResolvedRelationship(
      relationship: relationship,
      source: source,
      target: target,
    );
  }

  static Character? _findCharacter(Book book, String value) {
    for (final character in book.characters) {
      if (character.id == value || character.name == value) {
        return character;
      }
    }
    return null;
  }
}

class _GraphNode extends StatelessWidget {
  const _GraphNode({
    required this.character,
    required this.position,
    required this.isHub,
    required this.onTap,
  });

  final Character character;
  final Offset position;
  final bool isHub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final size = isHub ? 112.0 : 92.0;
    final avatarSize = isHub ? 68.0 : 56.0;

    return Positioned(
      left: position.dx - size / 2,
      top: position.dy - size / 2,
      width: size,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isHub ? const Color(0xFF9C5B22) : const Color(0xFFE6DED5),
              width: isHub ? 1.6 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.07),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              BookCover(
                imageUrl: character.imageUrl,
                width: avatarSize,
                height: avatarSize,
                borderRadius: avatarSize / 2,
              ),
              const SizedBox(height: 7),
              Text(
                character.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isHub ? 13 : 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                character.role,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: Color(0xFF7D746C)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RelationshipGraphPainter extends CustomPainter {
  const _RelationshipGraphPainter({
    required this.relationships,
    required this.positions,
  });

  final List<_ResolvedRelationship> relationships;
  final Map<String, Offset> positions;

  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in relationships) {
      final source = positions[edge.source.id];
      final target = positions[edge.target.id];
      if (source == null || target == null) continue;

      final color = _relationshipColor(edge.relationship.type);
      final paint = Paint()
        ..color = color.withValues(alpha: 0.56)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.4 + edge.relationship.strength.clamp(1, 5) * 0.45;

      canvas.drawLine(source, target, paint);
      _drawEdgeLabel(canvas, source, target, edge.relationship.label, color);
    }
  }

  void _drawEdgeLabel(
    Canvas canvas,
    Offset source,
    Offset target,
    String label,
    Color color,
  ) {
    if (label.isEmpty) return;

    final midpoint = Offset(
      (source.dx + target.dx) / 2,
      (source.dy + target.dy) / 2,
    );
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
      maxLines: 1,
      ellipsis: '...',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 86);

    final rect = Rect.fromCenter(
      center: midpoint,
      width: painter.width + 18,
      height: painter.height + 8,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
    canvas.drawRRect(rrect, Paint()..color = const Color(0xFFFFFCF7));
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = color.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke,
    );
    painter.paint(
      canvas,
      Offset(rect.left + 9, rect.top + (rect.height - painter.height) / 2),
    );
  }

  Color _relationshipColor(String type) {
    return switch (type) {
      'ally' => const Color(0xFF397367),
      'family' => const Color(0xFF8A5A9E),
      'conflict' => const Color(0xFFB4493D),
      'romance' => const Color(0xFFC05A7A),
      'mentor' => const Color(0xFF8B6F2F),
      'mystery' => const Color(0xFF4D6899),
      _ => const Color(0xFF8E7866),
    };
  }

  @override
  bool shouldRepaint(covariant _RelationshipGraphPainter oldDelegate) {
    return oldDelegate.relationships != relationships ||
        oldDelegate.positions != positions;
  }
}

class _RelationshipSummaryTile extends StatelessWidget {
  const _RelationshipSummaryTile({required this.edge});

  final _ResolvedRelationship edge;

  @override
  Widget build(BuildContext context) {
    final relationship = edge.relationship;
    final description = relationship.description.isEmpty
        ? '아직 자세한 관계 설명이 없습니다.'
        : relationship.description;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${edge.source.name} · ${edge.target.name}',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _StrengthPills(strength: relationship.strength),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(relationship.label),
                ),
                if (relationship.type.isNotEmpty)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(_relationshipTypeLabel(relationship.type)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.55,
                color: const Color(0xFF6F675F),
              ),
            ),
            if (relationship.evidence.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '근거: ${relationship.evidence}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  height: 1.45,
                  color: const Color(0xFF8B8178),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _relationshipTypeLabel(String type) {
    return switch (type) {
      'ally' => '협력',
      'family' => '가족',
      'conflict' => '대립',
      'romance' => '감정',
      'mentor' => '사제',
      'mystery' => '미스터리',
      _ => '관계',
    };
  }
}

class _StrengthPills extends StatelessWidget {
  const _StrengthPills({required this.strength});

  final int strength;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (index) {
        final active = index < strength.clamp(1, 5);
        return Container(
          width: 6,
          height: 16,
          margin: EdgeInsets.only(left: index == 0 ? 0 : 3),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF9C5B22) : const Color(0xFFE7DED4),
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
    );
  }
}

class _ChatMessage {
  const _ChatMessage({required this.role, required this.content});

  final ChatRole role;
  final String content;
}
