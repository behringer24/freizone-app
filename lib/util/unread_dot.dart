// Small filled circle used as an unread-message indicator -- place it
// via Positioned inside a Stack over an avatar (chat_list_screen.dart's
// conversation rows, account_shell_screen.dart's account switcher).
import 'package:flutter/material.dart';

class UnreadDot extends StatelessWidget {
  const UnreadDot({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: Colors.red,
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).scaffoldBackgroundColor,
          width: 2,
        ),
      ),
    );
  }
}
