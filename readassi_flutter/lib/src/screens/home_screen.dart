import 'package:flutter/material.dart';

import 'continue_reading_screen.dart';
import 'add_book_screen.dart'; // [수정] 스캔 대신 제목 입력 화면 임포트

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF7),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF0D9),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.auto_stories_rounded,
                          color: Color(0xFF9C5B22),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'ReadAssi',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'AI 독서 보조 애플리케이션',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF7D746C),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                children: [
                  _MenuCard(
                    title: '새로 책 읽기',
                    description: '새로운 책을 등록하고 카메라로 스캔을 시작합니다.', // 설명 살짝 수정
                    icon: Icons.add,
                    accent: const Color(0xFFFFF0D9),
                    onTap: () async {
                      // [핵심 수정] 바로 ScanScreen으로 가지 않고 AddBookScreen으로 보냅니다.
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const AddBookScreen(),
                        ),
                      );
                      if (mounted) {
                        setState(() {});
                      }
                    },
                  ),
                  const SizedBox(height: 18),
                  _MenuCard(
                    title: '이어 읽기',
                    description: '이전에 읽던 책을 선택해서 다음 기록을 이어갑니다.',
                    icon: Icons.history_rounded,
                    accent: const Color(0xFFF1ECE7),
                    muted: true,
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ContinueReadingScreen(),
                        ),
                      );
                      if (mounted) {
                        setState(() {});
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// _MenuCard 클래스는 기존과 동일하므로 유지하시면 됩니다.
class _MenuCard extends StatelessWidget {
  const _MenuCard({
    required this.title,
    required this.description,
    required this.icon,
    required this.accent,
    required this.onTap,
    this.muted = false,
  });

  final String title;
  final String description;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)), // 테두리 둥글게 추가
      color: muted ? const Color(0xFFFAF8F5) : Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(icon, color: const Color(0xFF855220)),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                description,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF7D746C),
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}