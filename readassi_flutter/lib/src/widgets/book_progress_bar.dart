import 'package:flutter/material.dart';

import '../models/book.dart';

class BookProgressBar extends StatelessWidget {
  const BookProgressBar({required this.book, super.key});

  final Book book;

  @override
  Widget build(BuildContext context) {
    final percent = book.progressPercent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: percent / 100,
            minHeight: 6,
            backgroundColor: const Color(0xFFEAE3DA),
            color: const Color(0xFFB5651D),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          book.totalPages == null
              ? '$percent%'
              : '${book.currentPage ?? 0}p / ${book.totalPages}p ($percent%)',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
