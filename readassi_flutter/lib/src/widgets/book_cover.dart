import 'package:flutter/material.dart';

class BookCover extends StatelessWidget {
  const BookCover({
    required this.imageUrl,
    required this.width,
    required this.height,
    this.borderRadius = 14,
    super.key,
  });

  final String imageUrl;
  final double width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Image.network(
        imageUrl,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            width: width,
            height: height,
            color: const Color(0xFFE8E0D8),
            alignment: Alignment.center,
            child: const Icon(
              Icons.menu_book_rounded,
              color: Color(0xFFA59789),
            ),
          );
        },
      ),
    );
  }
}
