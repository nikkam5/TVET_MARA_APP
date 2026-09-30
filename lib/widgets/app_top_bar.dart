import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// A restyled top bar used across every tab/page: gradient background,
/// a consistently-placed back control at the top-left, and an optional
/// trailing action (e.g. the hamburger menu). Purely presentational —
/// callers pass in whatever [onBack] behavior they already had.
class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final VoidCallback? onBack;
  final Widget? trailing;
  final IconData backIcon;
  final bool showLogos;

  // Taller than the default 56px toolbar so the logos have room to be
  // bigger and legible, similar to the official MARA portal header.
  static const double _barHeight = 76;

  const AppTopBar({
    super.key,
    required this.title,
    this.onBack,
    this.trailing,
    this.backIcon = Icons.arrow_back_rounded,
    this.showLogos = true,
  });

  @override
  Size get preferredSize => const Size.fromHeight(_barHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      elevation: 0,
      backgroundColor: Colors.transparent,
      centerTitle: false,
      toolbarHeight: _barHeight,
      // White header, matching the logos' own white background — no more
      // navy gradient and no gold trim underneath.
      flexibleSpace: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
        ),
      ),
      titleSpacing: 0,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showLogos) ...[
            // MARA emblem — round mark, fits a circular chip.
            const _LogoBadge(
              assetPath: 'assets/images/mara_logo.png',
              size: 56,
            ),
            const SizedBox(width: 8),
            // TVETMARA wordmark — wide logo, needs a pill not a circle
            // or the text gets crushed.
            const _WordmarkBadge(assetPath: 'assets/images/tvetmara_logo.png'),
            const SizedBox(width: 12),
          ],
          Flexible(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.navy,
                fontWeight: FontWeight.bold,
                fontSize: 17,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
      leading: _BackButton(icon: backIcon, onTap: onBack),
      actions: trailing == null ? null : [trailing!, const SizedBox(width: 4)],
    );
  }
}

/// Small circular logo chip — for round marks/emblems (e.g. the MARA
/// gear-and-book crest). Sits directly on the (now white) header, so no
/// background fill of its own — just enough padding to keep the crest
/// from touching the title text. Falls back to a placeholder icon if the
/// image asset hasn't been added yet, so the app still builds and runs
/// before the real logo files are dropped into assets/images/.
class _LogoBadge extends StatelessWidget {
  final String assetPath;
  final double size;

  const _LogoBadge({required this.assetPath, this.size = 34});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: size,
      width: size,
      child: Image.asset(
        assetPath,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => const Icon(
          Icons.school_rounded,
          color: AppTheme.navy,
          size: 22,
        ),
      ),
    );
  }
}

/// Wide slot for horizontal wordmark logos (e.g. the TVETMARA lockup)
/// that would get squashed inside a circular badge. Sits directly on the
/// white header, no separate background. Falls back to a placeholder if
/// the asset hasn't been added yet.
class _WordmarkBadge extends StatelessWidget {
  final String assetPath;

  const _WordmarkBadge({required this.assetPath});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      width: 130,
      child: Image.asset(
        assetPath,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => const Icon(
          Icons.business_rounded,
          color: AppTheme.navy,
          size: 18,
        ),
      ),
    );
  }
}

class _BackButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _BackButton({required this.icon, required this.onTap});

  @override
  State<_BackButton> createState() => _BackButtonState();
}

class _BackButtonState extends State<_BackButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTapDown: (_) => setState(() => _scale = 0.85),
        onTapCancel: () => setState(() => _scale = 1.0),
        onTapUp: (_) => setState(() => _scale = 1.0),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          child: Container(
            margin: const EdgeInsets.only(left: 12),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.navy.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(widget.icon, color: AppTheme.navy, size: 20),
          ),
        ),
      ),
    );
  }
}
