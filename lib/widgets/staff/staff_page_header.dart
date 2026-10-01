import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

/// Compact dark header used at the top of Tasks / Attendance / Profile —
/// matches the new mockups: a small "TVET MARA" eyebrow, a bold title,
/// and an optional one-line subtitle. Sits directly in the page body
/// (not a Scaffold.appBar) so it scrolls away with the rest of the
/// content, same as the reference screenshots.
class StaffPageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const StaffPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        20,
        MediaQuery.of(context).padding.top + 22,
        20,
        24,
      ),
      decoration: const BoxDecoration(gradient: AppTheme.heroGradient),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'TVET MARA',
                  style: TextStyle(
                    color: AppTheme.goldLight,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: AppTheme.onDarkSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
