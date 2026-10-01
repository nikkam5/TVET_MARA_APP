import 'package:flutter/material.dart';

/// Minimal stand-in for the two Lucide icons this app uses (`printer`,
/// `x`). The `lucide_icons` package can't be used here: its latest release
/// (0.257.0, June 2023) does `class LucideIconData extends IconData`, which
/// no longer compiles — `IconData` became a `final class` in newer Flutter
/// SDKs. Rather than forking a dead package, we draw the two glyphs with
/// CustomPainter: same 24×24 Lucide grid, same 2px round-capped strokes,
/// zero dependencies, and it matches the Material icons used elsewhere
/// closely enough to read as the same family.
class LucideIcon extends StatelessWidget {
  /// Stroke paths on Lucide's 24×24 grid.
  final List<Path> paths;

  const LucideIcon(this.paths, {super.key, this.size = 24, this.color});

  /// Lucide "printer" icon (feather-icons/lucide printer glyph):
  /// polyline 6,9 6,2 18,2 18,9 · path body · line 6,18 → 6,14 ·
  /// line 18,18 → 18,14 · rect x6 y14 w12 h8.
  static final printerPaths = _buildPrinter();
  static List<Path> _buildPrinter() {
    final top = Path()
      ..moveTo(6, 9)
      ..lineTo(6, 2)
      ..lineTo(18, 2)
      ..lineTo(18, 9);
    final body = Path()
      ..moveTo(6, 18)
      ..lineTo(4, 18)
      ..cubicTo(2.89543, 18, 2, 17.1046, 2, 16)
      ..lineTo(2, 11)
      ..cubicTo(2, 9.89543, 2.89543, 9, 4, 9)
      ..lineTo(20, 9)
      ..cubicTo(21.1046, 9, 22, 9.89543, 22, 11)
      ..lineTo(22, 16)
      ..cubicTo(22, 17.1046, 21.1046, 18, 20, 18)
      ..lineTo(18, 18);
    final tray = Path()..addRect(const Rect.fromLTWH(6, 14, 12, 8));
    return [top, body, tray];
  }

  /// Lucide "x" icon: two diagonal lines.
  static final xPaths = [
    Path()
      ..moveTo(18, 6)
      ..lineTo(6, 18),
    Path()
      ..moveTo(6, 6)
      ..lineTo(18, 18),
  ];

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconSize = size ?? IconTheme.of(context).size ?? 24;
    final iconColor = color ?? IconTheme.of(context).color ?? Colors.black;
    return SizedBox(
      width: iconSize,
      height: iconSize,
      child: CustomPaint(painter: _LucidePainter(paths, iconColor)),
    );
  }
}

class _LucidePainter extends CustomPainter {
  final List<Path> paths;
  final Color color;

  _LucidePainter(this.paths, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth =
          2 *
          (size.width / 24) // Lucide uses 2px at 24×24
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);
    for (final path in paths) {
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LucidePainter old) =>
      old.color != color || !identical(old.paths, paths);
}
