import 'package:flutter/material.dart';

import '../models/book.dart';
import '../widgets/book_cover.dart';

class CharacterProfileScreen extends StatelessWidget {
  const CharacterProfileScreen({
    required this.book,
    required this.character,
    super.key,
  });

  final Book book;
  final Character character;

  @override
  Widget build(BuildContext context) {
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
                _CharacterAvatar(character: character),
                const SizedBox(height: 16),
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
          const SizedBox(height: 16),
          _ProfileCard(
            title: '등장 작품',
            child: Row(
              children: [
                BookCover(
                  imageUrl: book.coverUrl,
                  width: 54,
                  height: 78,
                  borderRadius: 16,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        book.author,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF7D746C),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (book.relationships.isNotEmpty) ...[
            const SizedBox(height: 16),
            _ProfileCard(
              title: '관계 힌트',
              child: Column(
                children: book.relationships
                    .where(
                      (relationship) =>
                          relationship.source == character.id ||
                          relationship.target == character.id,
                    )
                    .map(
                      (relationship) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF9F4EC),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text(
                              relationship.label,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
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

class _CharacterAvatar extends StatelessWidget {
  const _CharacterAvatar({required this.character});

  final Character character;

  @override
  Widget build(BuildContext context) {
    if (character.imageUrl.isNotEmpty) {
      return BookCover(
        imageUrl: character.imageUrl,
        width: 108,
        height: 108,
        borderRadius: 54,
      );
    }

    return Container(
      width: 108,
      height: 108,
      decoration: const BoxDecoration(
        color: Color(0xFFFFF1DE),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        character.name.isEmpty ? '?' : character.name.substring(0, 1),
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          color: const Color(0xFF9C5B22),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
