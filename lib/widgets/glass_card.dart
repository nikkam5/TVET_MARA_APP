import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// A true frosted-glass panel: blurs whatever sits behind it
/// (gradients, background art, other cards) via [BackdropFilter], then
/// lays a translucent tinted surface + hairline border on top so content
/// reads clearly while the glass effect stays visible at the edges.
///
/// Use [GlassCard] on light backgrounds (dashboards, list screens) and
/// [GlassCard.onDark] on navy/gradient surfaces (headers, hero banners).
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;
  final bool onDark;
  final VoidCallback? onTap;
  final Color? accentColor;                    // ← NEW FIELD

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 22,
    this.blur = 18,
    this.onTap,
    this.accentColor,                           // ← NEW PARAM
  }) : onDark = false;

  const GlassCard.onDark({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 22,
    this.blur = 18,
    this.onTap,
    this.accentColor,                           // ← NEW PARAM
  }) : onDark = true;

  @override
  Widget build(BuildContext context) {
    var decoration = onDark                                    // ← final → var
        ? AppTheme.glassPanelOnDark(radius: radius)
        : AppTheme.glassPanel(
            radius: radius,
            glow: accentColor ?? AppTheme.navy,                 // ← tint the glow
          );

    // Optional colour-coded left border (e.g. green for "Present",       ← NEW BLOCK
    // orange for "Pending") layered on top of the frosted decoration.
    if (accentColor != null) {
      decoration = decoration.copyWith(
        border: Border(left: BorderSide(color: accentColor!, width: 4)),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: padding,
              decoration: decoration,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A full-bleed decorative glass "orb" — soft blurred colour blobs used
/// behind headers/hero sections to give glassmorphism something to blur
/// against instead of a flat gradient. Purely decorative, ignores input.
class GlassOrb extends StatelessWidget {
  final double size;
  final Color color;
  final double opacity;

  const GlassOrb({
    super.key,
    this.size = 180,
    this.color = AppTheme.gold,
    this.opacity = 0.35,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0.0),
            ],
          ),
        ),
      ),
    );
  }
}
