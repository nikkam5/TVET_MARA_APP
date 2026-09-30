import 'package:flutter/material.dart';

/// Shared visual language for the app, balanced on a 60-30-10 split so nothing
/// fights for attention on screen:
///
///  - 60% Dominant base — clean white / near-white surfaces (`bgTop`,
///    `bgBottom`) with soft slate text, for comfortable everyday reading.
///  - 30% Secondary structure — MARA's deep corporate navy (`navy`), used
///    for top headers, primary tabs, and structural container accents to
///    carry the institutional identity without covering the whole screen.
///  - 10% Accent — a muted, WCAG-friendly MARA red (`maraRed`), reserved
///    strictly for high-priority states: critical CTAs ("Punch Out"),
///    active/urgent status (Absent, late, pending, errors). It is
///    deliberately toned down from the bright brand-guideline red so it
///    reads as "pay attention" rather than causing eye strain when it
///    shows up throughout the day.
///
/// Gold is layered on top as a warm highlight — the active bottom-nav tab,
/// icon-chip gradients, header trim lines, and card/button glows — so the
/// UI reads less flatly blue while red stays reserved for critical states.
/// Only styling constants live here — no widgets with behavior.
class AppTheme {
  AppTheme._();

  // --- 60%: dominant base -----------------------------------------------
  static const Color bgTop = Color(0xFFFFFFFF);
  static const Color bgBottom = Color(0xFFF8F9FA);

  // Text — soft slate/off-black ink, easier on the eye than pure black.
  static const Color textPrimary = Color(0xFF1C2333);
  static const Color textSecondary = Color(0xFF5B6478);
  static const Color textFaint = Color(0xFF99A2B5);

  // --- 30%: secondary structure (MARA navy) ------------------------------
  // Matches the navy already used throughout the app's buttons, active
  // states, and borders (Color(0xFF002060), labelled "MARA Navy Blue" at
  // the login screen) so the header gradient lines up with everything
  // else instead of introducing a second, slightly-off shade of blue.
  static const Color navy = Color(0xFF002060); // MARA corporate navy
  static const Color navyDeep = Color(0xFF00123D);
  static const Color maraBlue = Color(0xFF0A4EA1); // lighter tint for gradients

  // --- 10%: accent (muted MARA red — critical/CTA states only) ----------
  // Softened from the bright brand-guideline red (#D9392C) so it reads as
  // a deliberate warning/CTA color rather than a jarring, high-saturation
  // red when it appears throughout the day.
  static const Color maraRed = Color(0xFFC0392B);
  static const Color maraRedDeep = Color(0xFF8E2A20);
  static const Color maraRedSoft = Color(0xFFE8A79E); // tints/backgrounds

  // Gold — occasional premium flourish only (badges, underline accents),
  // pulled from the emblem's padi/gear trim.
  static const Color gold = Color(0xFFC9992C);
  static const Color goldLight = Color(0xFFF0C868);
  static const Color goldDeep = Color(0xFF9A7420);

  // Kept as aliases so older call sites (AppTheme.violet, AppTheme.teal,
  // ...) still compile. `violet` now maps to the muted accent red — use it
  // (or `maraRed` directly) only for genuinely critical/CTA states.
  static const Color violet = maraRed;
  static const Color violetDeep = maraRedDeep;
  static const Color teal = maraBlue;

  // Colors meant to sit on top of a dark (navy) surface — the header
  // gradient, filled buttons, badges.
  static const Color onDark = Colors.white;
  static const Color onDarkSecondary = Color(0xFFD7E0F5);

  static const LinearGradient pageGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [bgTop, bgBottom],
  );

  // Structural navy header — top bars, the dashboard's quick-action
  // banner, and other "primary tab" chrome. Three stops instead of two
  // for more visible depth, still calm (navy, not red) so it doesn't
  // strain the eyes across everyday use.
  static const LinearGradient headerGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [maraBlue, navy, navyDeep],
    stops: [0.0, 0.6, 1.0],
  );

  // Decorative badge/highlight gradient — navy into gold, kept out of the
  // red accent family entirely since these spots (announcement icons,
  // headline numerals) aren't critical/CTA states.
  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [navy, gold],
  );

  // All-blue variant of the badge gradient — same navy family, no gold.
  // Used where a spot should stay strictly on-brand-blue (e.g. the
  // News & Announcements icon chips) without pulling in the gold accent.
  static const LinearGradient announcementGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [maraBlue, navy, navyDeep],
    stops: [0.0, 0.6, 1.0],
  );

  // A dedicated gold gradient for premium highlight moments (active-tab
  // underline, etc.) — used sparingly.
  static const LinearGradient goldGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [goldLight, gold, goldDeep],
    stops: [0.0, 0.55, 1.0],
  );

  // Blue-into-gold gradient for icon chips/badges — brings more of the
  // brand's gold into everyday surfaces (grid icons, quick-action chips)
  // without touching the red accent's reserved-for-critical role.
  static const LinearGradient iconChipGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [maraBlue, navy, gold],
    stops: [0.0, 0.55, 1.0],
  );

  // The 10%-accent gradient — muted red — reserved for critical CTAs like
  // "Swipe to Punch Out" or a late/urgent punch-in state.
  static const LinearGradient criticalGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [maraRed, maraRedDeep],
  );

  /// Card look on a white page: a soft, near-white panel with a fine
  /// border and a gentle colour-tinted shadow, so cards read as floating
  /// just above the background instead of flat.
  static BoxDecoration glassCard({
    double radius = 18,
    Color glow = maraBlue,
    double glowOpacity = 0.12,
  }) {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: const Color(0xFFEAEDF5)),
      boxShadow: [
        BoxShadow(
          color: glow.withValues(alpha: glowOpacity),
          blurRadius: 24,
          spreadRadius: 1,
          offset: const Offset(0, 10),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  // --- Glassmorphism -------------------------------------------------
  // A true frosted-glass look (paired with BackdropFilter blur in
  // GlassCard/GlassSurface — see widgets/glass_card.dart): a translucent
  // tinted fill, a hairline light border to catch the "edge" light hitting
  // glass would have, and a soft outer glow instead of a flat shadow.

  /// Frosted panel on a *light* page (dashboards, lists): near-white,
  /// semi-transparent, needs a BackdropFilter blur behind it to read as
  /// glass rather than just a translucent card.
  static BoxDecoration glassPanel({
    double radius = 22,
    Color tint = Colors.white,
    double tintOpacity = 0.55,
    Color glow = navy,
    double glowOpacity = 0.10,
  }) {
    return BoxDecoration(
      color: tint.withValues(alpha: tintOpacity),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1.2),
      boxShadow: [
        BoxShadow(
          color: glow.withValues(alpha: glowOpacity),
          blurRadius: 30,
          spreadRadius: -4,
          offset: const Offset(0, 14),
        ),
      ],
    );
  }

  /// Frosted panel on a *dark* surface (navy header, gradient banners):
  /// a light, low-opacity fill with a brighter hairline border, plus a
  /// gold-tinted glow so it still reads as premium rather than muddy.
  static BoxDecoration glassPanelOnDark({
    double radius = 22,
    double tintOpacity = 0.12,
    Color borderTint = Colors.white,
    double borderOpacity = 0.28,
  }) {
    return BoxDecoration(
      color: Colors.white.withValues(alpha: tintOpacity),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: borderTint.withValues(alpha: borderOpacity), width: 1.2),
      boxShadow: [
        BoxShadow(
          color: gold.withValues(alpha: 0.10),
          blurRadius: 24,
          spreadRadius: -6,
          offset: const Offset(0, 10),
        ),
      ],
    );
  }
}
