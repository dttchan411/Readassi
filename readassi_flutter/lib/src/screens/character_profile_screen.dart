import 'package:flutter/material.dart';

import '../models/book.dart';

class CharacterProfileScreen extends StatelessWidget {
  const CharacterProfileScreen({required this.character, super.key});

  final Character character;

  @override
  Widget build(BuildContext context) {
    final personality = character.personality.trim();
    final motivation = character.motivation.trim();

    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFBF7),
        title: Text(character.name),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        children: [
          Center(
            child: Column(
              children: [
                Text(
                  character.name,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF1DE),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    character.role,
                    style: const TextStyle(
                      color: Color(0xFF9C5B22),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (character.firstPage != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    '${character.firstPage}쪽에 처음 등장',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF7D746C),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 28),
          _ProfileCard(
            title: '프로필',
            child: Text(
              character.description.isEmpty
                  ? '아직 등록된 등장인물 설명이 없습니다.'
                  : character.description,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(height: 1.7),
            ),
          ),
          if (personality.isNotEmpty) ...[
            const SizedBox(height: 16),
            _ProfileCard(
              title: '성격',
              child: Text(
                personality,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(height: 1.7),
              ),
            ),
          ],
          if (motivation.isNotEmpty) ...[
            const SizedBox(height: 16),
            _ProfileCard(
              title: '목표·동기',
              child: Text(
                motivation,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(height: 1.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}
