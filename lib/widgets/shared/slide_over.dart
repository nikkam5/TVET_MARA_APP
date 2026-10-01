import 'package:flutter/material.dart';

/// --- Slide-over panel --------------------------------------------------
///
/// A right-hand drawer that animates over the *current* screen instead of
/// pushing a new page on top of it. The shell underneath (the admin
/// dashboard's sticky rail + top navbar) stays mounted and visible behind
/// the translucent scrim, so opening a form never breaks the navigation
/// context the way a full-page `MaterialPageRoute` does.
///
/// Use it for every "create / edit / inspect" flow that used to be a
/// redirect:
///
/// ```dart
/// final saved = await showSlideOver<bool>(
///   context: context,
///   title: 'Add New Staff',
///   subtitle: 'Create a login account and staff record',
///   body: StaffFormBody(departments: departments, isEdit: false),
/// );
/// ```
///
/// On wide screens the panel is a 560–660px column docked to the right
/// edge; on phones it clamps to 96% of the viewport, so it reads as a
/// near-full-screen sheet without ever leaving the dashboard shell.
const Color kSlideOverHairline = Color(0xFFE2E8F0);
const Color kSlideOverInk = Color(0xFF0F172A);
const Color kSlideOverMuted = Color(0xFF64748B);

Future<T?> showSlideOver<T>({
  required BuildContext context,
  required String title,
  String? subtitle,
  required WidgetBuilder body,
  Widget? footer,
  double width = 560,
  bool dismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'Close $title',
    // The scrim is painted inside the transition so it can fade in and out
    // with the panel; the route's own barrier stays transparent (it still
    // absorbs taps for dismissal).
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (dialogContext, _, _) {
      final maxW = MediaQuery.of(dialogContext).size.width * 0.96;
      final panelWidth = width > maxW ? maxW : width;
      return SafeArea(
        child: Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: panelWidth,
              height: double.infinity,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.white,
                border: const Border(
                  left: BorderSide(color: kSlideOverHairline),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.20),
                    blurRadius: 44,
                    offset: const Offset(-14, 0),
                  ),
                ],
              ),
              child: Column(
                children: [
                  _panelHeader(
                    context: dialogContext,
                    title: title,
                    subtitle: subtitle,
                  ),
                  const Divider(height: 1, color: kSlideOverHairline),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                      child: body(dialogContext),
                    ),
                  ),
                  if (footer != null)
                    Container(
                      width: double.infinity,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF8FAFC),
                        border: Border(
                          top: BorderSide(color: kSlideOverHairline),
                        ),
                      ),
                      padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
                      child: footer,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Scrim — tapping it dismisses the panel (route barrier).
            ColoredBox(color: Colors.black.withValues(alpha: 0.42)),
            SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          ],
        ),
      );
    },
  );
}

Widget _panelHeader({
  required BuildContext context,
  required String title,
  String? subtitle,
}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 12, 15),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          margin: const EdgeInsets.only(right: 12, top: 1),
          decoration: BoxDecoration(
            color: const Color(0xFF002060).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(9),
          ),
          child: const Icon(
            Icons.layers_rounded,
            size: 17,
            color: Color(0xFF002060),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17.5,
                  fontWeight: FontWeight.w800,
                  color: kSlideOverInk,
                  letterSpacing: -0.3,
                  height: 1.2,
                ),
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: kSlideOverMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
        IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          tooltip: 'Close',
          icon: const Icon(Icons.close_rounded, size: 21),
          color: kSlideOverMuted,
          hoverColor: const Color(0xFF0F172A).withValues(alpha: 0.06),
          splashRadius: 18,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        ),
      ],
    ),
  );
}
