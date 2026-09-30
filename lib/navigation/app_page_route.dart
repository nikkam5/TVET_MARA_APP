import 'package:flutter/material.dart';

/// Shared motion for the app: a short fade + gentle upward lift feels polished
/// without slowing down frequent admin workflows.
PageRoute<T> appPageRoute<T>(Widget page) => PageRouteBuilder<T>(
  pageBuilder: (_, animation, secondaryAnimation) => page,
  transitionDuration: const Duration(milliseconds: 360),
  reverseTransitionDuration: const Duration(milliseconds: 260),
  transitionsBuilder: (_, animation, secondaryAnimation, child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
    final opacity = Tween<double>(begin: 0, end: 1).animate(curved);
    final slide = Tween<Offset>(
      begin: const Offset(0, 0.025),
      end: Offset.zero,
    ).animate(curved);
    return FadeTransition(
      opacity: opacity,
      child: SlideTransition(position: slide, child: child),
    );
  },
);

Widget motionItem({required Widget child, required int index}) =>
    TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 320 + (index.clamp(0, 8) * 45)),
      curve: Curves.easeOutCubic,
      builder: (_, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - value)),
          child: child,
        ),
      ),
      child: child,
    );
