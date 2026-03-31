import 'package:flutter/material.dart';

import '../models/book.dart';

class BookProgressBar extends StatelessWidget {
  const BookProgressBar({required this.book, super.key});

  final Book book;

  @override
  Widget build(BuildContext context) {
    return Text(
      '${book.currentPage ?? 0}p',
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}