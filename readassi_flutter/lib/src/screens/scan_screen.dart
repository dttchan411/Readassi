import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/book.dart';
import '../widgets/chat_bubble.dart';
import 'book_detail_screen.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({this.existingBookId, super.key});

  final String? existingBookId;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _isScanning = false;
  bool _showTooltip = true;
  bool _hasData = false;
  ScanTab _activeTab = ScanTab.text;

  String _extractedText = '';
  String _summary = '';
  List<String> _keywords = [];
  List<_SimpleCharacter> _characters = [];
  final List<_ChatEntry> _chatMessages = [];
  final TextEditingController _chatController = TextEditingController();
  final List<Timer> _timers = [];

  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() => _showTooltip = false);
      }
    });
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _chatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final existingBook = widget.existingBookId == null
        ? null
        : appState.findBookById(widget.existingBookId!);

    return Scaffold(
      backgroundColor: const Color(0xFF171412),
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFF2A241F),
                    const Color(0xFF171412),
                    Colors.black.withValues(alpha: 0.96),
                  ],
                ),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 120),
                  Expanded(
                    child: Center(
                      child: Container(
                        width: MediaQuery.of(context).size.width * 0.76,
                        constraints: const BoxConstraints(maxWidth: 340),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                            color: _isScanning
                                ? const Color(0xFFFFC47B)
                                : const Color(0xFF5A4F46),
                            width: 2,
                          ),
                          boxShadow: _isScanning
                              ? [
                                  BoxShadow(
                                    color: const Color(
                                      0xFFFFB55D,
                                    ).withValues(alpha: 0.25),
                                    blurRadius: 40,
                                    spreadRadius: 10,
                                  ),
                                ]
                              : null,
                        ),
                        child: AspectRatio(
                          aspectRatio: 3 / 4,
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(26),
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Colors.white.withValues(alpha: 0.05),
                                        Colors.white.withValues(alpha: 0.02),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              if (_isScanning)
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  child: TweenAnimationBuilder<double>(
                                    tween: Tween(begin: -1, end: 1),
                                    duration: const Duration(seconds: 2),
                                    curve: Curves.easeInOut,
                                    builder: (context, value, child) {
                                      return Transform.translate(
                                        offset: Offset(0, value * 260),
                                        child: child,
                                      );
                                    },
                                    child: Container(
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFFC47B),
                                        boxShadow: [
                                          BoxShadow(
                                            color: const Color(
                                              0xFFFFC47B,
                                            ).withValues(alpha: 0.9),
                                            blurRadius: 18,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 220),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      _RoundIconButton(
                        icon: Icons.close_rounded,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      const Spacer(),
                      if (_hasData && !_isScanning)
                        FilledButton.icon(
                          onPressed: () => _saveToLibrary(existingBook),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFD58C40),
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.bookmark_add_outlined),
                          label: const Text('기록 저장'),
                        ),
                    ],
                  ),
                ),
                const Spacer(),
                if (!_hasData && _showTooltip && !_isScanning)
                  Container(
                    margin: const EdgeInsets.only(bottom: 20),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E2925).withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF4C443D)),
                    ),
                    child: const Text(
                      '카메라 영역에 책 페이지를 맞춘 뒤\n아래 버튼으로 스캔을 시작하세요.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFFF3EDE4), height: 1.5),
                    ),
                  ),
                if (_hasData)
                  _ScanPanel(
                    activeTab: _activeTab,
                    isScanning: _isScanning,
                    extractedText: _extractedText,
                    summary: _summary,
                    keywords: _keywords,
                    characters: _characters,
                    chatMessages: _chatMessages,
                    chatController: _chatController,
                    onTabSelected: (tab) => setState(() => _activeTab = tab),
                    onSendMessage: _sendMessage,
                  ),
                Container(
                  width: double.infinity,
                  color: _hasData
                      ? const Color(0xFFFDFBF7)
                      : Colors.transparent,
                  padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
                  child: Column(
                    children: [
                      GestureDetector(
                        onTap: _toggleScan,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 280),
                          width: 88,
                          height: 88,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isScanning
                                ? const Color(0xFFD58C40)
                                : const Color(0xFFF3EFE8),
                            border: Border.all(
                              color: _isScanning
                                  ? const Color(0xFFFFD3A1)
                                  : const Color(0xFF4F443C),
                              width: _isScanning ? 4 : 3,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color:
                                    (_isScanning
                                            ? const Color(0xFFFFB55D)
                                            : Colors.black)
                                        .withValues(alpha: 0.18),
                                blurRadius: 26,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: Center(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 240),
                              width: _isScanning ? 28 : 56,
                              height: _isScanning ? 28 : 56,
                              decoration: BoxDecoration(
                                color: _isScanning
                                    ? Colors.white
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(
                                  _isScanning ? 8 : 28,
                                ),
                                border: Border.all(
                                  color: _isScanning
                                      ? Colors.white
                                      : const Color(0xFF322B26),
                                  width: 3,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        _isScanning ? '인식 중' : (_hasData ? '다시 스캔하기' : '스캔 시작'),
                        style: const TextStyle(
                          color: Color(0xFFBFB2A2),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _toggleScan() {
    setState(() {
      _isScanning = !_isScanning;
      if (_isScanning) {
        _startMockScan();
      } else {
        _ensureResultData();
      }
    });
  }

  void _startMockScan() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();

    setState(() {
      _hasData = true;
      _activeTab = ScanTab.text;
      _extractedText = '';
      _summary = '';
      _keywords = [];
      _characters = [];
      _chatMessages.clear();
    });

    final steps = <({Duration delay, VoidCallback action})>[
      (
        delay: const Duration(seconds: 1),
        action: () => setState(() {
          _extractedText += '손자병법 제1편 시계(始計)... ';
        }),
      ),
      (
        delay: const Duration(seconds: 3),
        action: () => setState(() {
          _extractedText += '병자 국지대사(兵者 國之大事), 사생지지(死生之地), 존망지도(存亡之道), 불가불찰야. ';
        }),
      ),
      (
        delay: const Duration(seconds: 5),
        action: () => setState(() {
          _extractedText +=
              '전쟁은 국가의 중대사이다. 백성의 생사와 국가의 존망이 달린 문제이므로 깊이 살피지 않을 수 없다.';
        }),
      ),
      (
        delay: const Duration(seconds: 6),
        action: () => setState(() {
          _summary =
              '이 구절은 손자병법의 핵심 사상인 신중한 전쟁관을 담고 있습니다. 전쟁이 국가와 백성의 운명을 좌우하는 중대사이므로, 철저한 계산과 준비 없이는 섣불리 움직여선 안 된다는 메시지입니다.';
          _keywords = ['신중함', '전략', '국가의 중대사', '철저한 준비'];
        }),
      ),
      (
        delay: const Duration(seconds: 7),
        action: () => setState(() {
          _characters = const [
            _SimpleCharacter(
              name: '손무 (孫武)',
              description: '춘추시대 오나라의 장군. 싸우지 않고 이기는 것을 최선으로 여긴 전략가입니다.',
            ),
            _SimpleCharacter(
              name: '합려 (闔閭)',
              description: '오나라의 왕. 손무를 기용해 강국으로 도약하려 한 인물입니다.',
            ),
          ];
        }),
      ),
      (
        delay: const Duration(seconds: 8),
        action: () => setState(() {
          _chatMessages.add(
            const _ChatEntry(
              role: ChatRole.assistant,
              content: '손자병법의 시계 편을 읽고 계시군요. 이 부분에서 더 궁금한 점이 있으신가요?',
            ),
          );
        }),
      ),
    ];

    for (final step in steps) {
      _timers.add(
        Timer(step.delay, () {
          if (mounted && _isScanning) {
            step.action();
          }
        }),
      );
    }
  }

  void _ensureResultData() {
    if (!_hasData || _extractedText.isEmpty) {
      return;
    }

    setState(() {
      if (_summary.isEmpty) {
        _summary =
            '이 구절은 손자병법의 핵심 사상인 신중한 전쟁관을 담고 있습니다. 전쟁이 국가와 백성의 운명을 좌우하는 중대사이므로, 철저한 계산과 준비 없이는 섣불리 움직여선 안 된다는 메시지입니다.';
      }
      if (_keywords.isEmpty) {
        _keywords = ['신중함', '전략', '국가의 중대사', '철저한 준비'];
      }
      if (_characters.isEmpty) {
        _characters = const [
          _SimpleCharacter(
            name: '손무 (孫武)',
            description: '춘추시대 오나라의 장군. 싸우지 않고 이기는 것을 최선으로 여긴 전략가입니다.',
          ),
          _SimpleCharacter(
            name: '합려 (闔閭)',
            description: '오나라의 왕. 손무를 기용해 강국으로 도약하려 한 인물입니다.',
          ),
        ];
      }
      if (_chatMessages.isEmpty) {
        _chatMessages.add(
          const _ChatEntry(
            role: ChatRole.assistant,
            content: '손자병법의 시계 편을 읽고 계시군요. 이 부분에서 더 궁금한 점이 있으신가요?',
          ),
        );
      }
    });
  }

  void _sendMessage() {
    final text = _chatController.text.trim();
    if (text.isEmpty) {
      return;
    }

    setState(() {
      _chatMessages.add(_ChatEntry(role: ChatRole.user, content: text));
      _chatMessages.add(
        const _ChatEntry(
          role: ChatRole.assistant,
          content:
              '좋아요. 지금 문맥에서는 전쟁을 시작하기 전에 계산과 명분, 지형과 병력까지 함께 살피라는 뜻으로 읽을 수 있습니다.',
        ),
      );
      _chatController.clear();
    });
  }

  void _saveToLibrary(Book? existingBook) {
    final appState = AppStateScope.of(context);
    final totalPages = existingBook?.totalPages ?? 300;
    final nextPage = existingBook == null
        ? Random().nextInt(90) + 1
        : min(
            (existingBook.currentPage ?? 0) + Random().nextInt(30) + 10,
            totalPages,
          );

    final savedBook = Book(
      id: 'b${DateTime.now().millisecondsSinceEpoch}',
      title: existingBook?.title ?? '손자병법',
      author: existingBook?.author ?? '손무',
      coverUrl:
          existingBook?.coverUrl ??
          'https://images.unsplash.com/photo-1604435062356-a880b007922c?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHxib29rJTIwY292ZXIlMjBteXN0ZXJ5fGVufDF8fHx8MTc3Mzc5NDUwM3ww&ixlib=rb-4.1.0&q=80&w=1080',
      summary: _summary,
      keywords: _keywords,
      characters: _characters
          .map(
            (character) => Character(
              id: character.name,
              name: character.name,
              role: '핵심 인물',
              description: character.description,
              imageUrl:
                  'https://images.unsplash.com/photo-1506794778202-cad84cf45f1d?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=1080',
            ),
          )
          .toList(),
      relationships: existingBook?.relationships ?? const [],
      currentPage: nextPage,
      totalPages: totalPages,
      progress: ((nextPage / totalPages) * 100).round(),
    );

    appState.addBook(savedBook);

    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => BookDetailScreen(bookId: savedBook.id),
      ),
    );
  }
}

enum ScanTab { text, summary, characters, chat }

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}

class _ScanPanel extends StatelessWidget {
  const _ScanPanel({
    required this.activeTab,
    required this.isScanning,
    required this.extractedText,
    required this.summary,
    required this.keywords,
    required this.characters,
    required this.chatMessages,
    required this.chatController,
    required this.onTabSelected,
    required this.onSendMessage,
  });

  final ScanTab activeTab;
  final bool isScanning;
  final String extractedText;
  final String summary;
  final List<String> keywords;
  final List<_SimpleCharacter> characters;
  final List<_ChatEntry> chatMessages;
  final TextEditingController chatController;
  final ValueChanged<ScanTab> onTabSelected;
  final VoidCallback onSendMessage;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: const BoxDecoration(
        color: Color(0xFFFDFBF7),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _ScanTabChip(
                    icon: Icons.menu_book_rounded,
                    label: '텍스트',
                    selected: activeTab == ScanTab.text,
                    onTap: () => onTabSelected(ScanTab.text),
                  ),
                  _ScanTabChip(
                    icon: Icons.auto_awesome_rounded,
                    label: 'AI 요약',
                    selected: activeTab == ScanTab.summary,
                    disabled: isScanning,
                    onTap: () => onTabSelected(ScanTab.summary),
                  ),
                  _ScanTabChip(
                    icon: Icons.people_alt_outlined,
                    label: '인물 정보',
                    selected: activeTab == ScanTab.characters,
                    disabled: isScanning,
                    onTap: () => onTabSelected(ScanTab.characters),
                  ),
                  _ScanTabChip(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: '질문하기',
                    selected: activeTab == ScanTab.chat,
                    disabled: isScanning,
                    onTap: () => onTabSelected(ScanTab.chat),
                  ),
                ],
              ),
            ),
          ),
          if (isScanning)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              color: const Color(0xFFFFF4E7),
              child: const Row(
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text(
                    '텍스트를 인식하고 분석하고 있습니다...',
                    style: TextStyle(
                      color: Color(0xFFA46728),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: Builder(
                builder: (context) {
                  switch (activeTab) {
                    case ScanTab.text:
                      return Text(
                        extractedText.isEmpty
                            ? '텍스트를 인식하고 있습니다...'
                            : extractedText,
                        style: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(height: 1.7),
                      );
                    case ScanTab.summary:
                      if (summary.isEmpty) {
                        return const Text('텍스트가 충분히 쌓이면 AI 요약이 여기에 나타납니다.');
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            summary,
                            style: Theme.of(
                              context,
                            ).textTheme.bodyLarge?.copyWith(height: 1.7),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: keywords
                                .map(
                                  (keyword) => Chip(label: Text('#$keyword')),
                                )
                                .toList(),
                          ),
                        ],
                      );
                    case ScanTab.characters:
                      if (characters.isEmpty) {
                        return const Text('등장인물 정보가 아직 없습니다.');
                      }
                      return Column(
                        children: characters
                            .map(
                              (character) => Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    border: Border.all(
                                      color: const Color(0xFFE4DDD6),
                                    ),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFFFFF4E7),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.person_rounded,
                                          color: Color(0xFFA46728),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              character.name,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              character.description,
                                              style: const TextStyle(
                                                height: 1.5,
                                                color: Color(0xFF6F675F),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      );
                    case ScanTab.chat:
                      return Column(
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(
                              minHeight: 180,
                              maxHeight: 220,
                            ),
                            child: ListView.separated(
                              shrinkWrap: true,
                              itemCount: chatMessages.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                final message = chatMessages[index];
                                return ChatBubble(
                                  role: message.role,
                                  content: message.content,
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: chatController,
                                  decoration: const InputDecoration(
                                    hintText: '궁금한 점을 물어보세요',
                                    filled: true,
                                    fillColor: Colors.white,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.all(
                                        Radius.circular(18),
                                      ),
                                      borderSide: BorderSide(
                                        color: Color(0xFFE4DDD6),
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.all(
                                        Radius.circular(18),
                                      ),
                                      borderSide: BorderSide(
                                        color: Color(0xFFE4DDD6),
                                      ),
                                    ),
                                  ),
                                  onSubmitted: (_) => onSendMessage(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: onSendMessage,
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFFD58C40),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.all(16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                ),
                                child: const Icon(Icons.send_rounded),
                              ),
                            ],
                          ),
                        ],
                      );
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanTabChip extends StatelessWidget {
  const _ScanTabChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.disabled = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textColor = disabled
        ? const Color(0xFFC6BBB0)
        : selected
        ? const Color(0xFF8A4B17)
        : const Color(0xFF6F675F);

    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFFFF0D9) : const Color(0xFFF5F1EA),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: textColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SimpleCharacter {
  const _SimpleCharacter({required this.name, required this.description});

  final String name;
  final String description;
}

class _ChatEntry {
  const _ChatEntry({required this.role, required this.content});

  final ChatRole role;
  final String content;
}
