import 'package:flutter/material.dart';

enum ChatRole { user, assistant }

class ChatBubble extends StatelessWidget {
  const ChatBubble({required this.role, required this.content, super.key});

  final ChatRole role;
  final String content;

  @override
  Widget build(BuildContext context) {
    final isUser = role == ChatRole.user;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFFB5651D) : Colors.white,
          borderRadius: BorderRadius.circular(18).copyWith(
            bottomRight: isUser ? const Radius.circular(4) : null,
            bottomLeft: !isUser ? const Radius.circular(4) : null,
          ),
          border: isUser ? null : Border.all(color: const Color(0xFFE4DDD6)),
        ),
        child: Text(
          content,
          style: TextStyle(
            color: isUser ? Colors.white : const Color(0xFF3A332D),
            height: 1.5,
          ),
        ),
      ),
    );
  }
}
