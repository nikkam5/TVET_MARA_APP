import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// One destination in the bottom nav.
class NavTabItem {
  final IconData icon;
  final IconData? activeIcon;
  final String label;

  const NavTabItem({
    required this.icon,
    required this.label,
    this.activeIcon,
  });
}

/// A horizontally-scrollable, animated bottom navigation bar.
///
/// Unlike a fixed [BottomNavigationBar] (which has to squeeze every
/// destination into the screen width), this one lays its tabs out in a
/// single scrollable row — so when more tabs are added later they simply
/// extend off the right edge and the user scrolls the panel left to reach
/// them, instead of every icon shrinking to fit.
///
/// Pure UI: it only reports taps via [onTap] — callers keep whatever
/// navigation logic they already had.
class ScrollableBottomNav extends StatefulWidget {
  final List<NavTabItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  const ScrollableBottomNav({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  State<ScrollableBottomNav> createState() => _ScrollableBottomNavState();
}

class _ScrollableBottomNavState extends State<ScrollableBottomNav> {
  final ScrollController _controller = ScrollController();
  static const double _itemWidth = 78;

  @override
  void didUpdateWidget(covariant ScrollableBottomNav oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _scrollToSelected();
    }
  }

  void _scrollToSelected() {
    if (!_controller.hasClients) return;
    final target = (_itemWidth * widget.currentIndex) -
        (_controller.position.viewportDimension / 2) +
        (_itemWidth / 2);
    _controller.animateTo(
      target.clamp(0.0, _controller.position.maxScrollExtent),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Frosted glass: blur whatever scrolls underneath the nav, then lay a
    // translucent white surface + hairline top border on top so tabs stay
    // legible while the blur is still visible at the edges.
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.82),
        border: const Border(
          top: BorderSide(color: Color(0xFFEAEDF5), width: 1),
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.navy.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 68,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tabs = List<Widget>.generate(widget.items.length, (index) {
                final item = widget.items[index];
                final selected = index == widget.currentIndex;
                return _NavTab(
                  width: _itemWidth,
                  item: item,
                  selected: selected,
                  onTap: () => widget.onTap(index),
                );
              });

              final totalWidth = _itemWidth * widget.items.length;
              final fitsOnScreen = totalWidth <= constraints.maxWidth;

              // Enough room for every tab — center them as a plain row
              // instead of a left-aligned scroll view.
              if (fitsOnScreen) {
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: tabs,
                );
              }

              // Too many tabs to fit — fall back to the original
              // horizontally-scrollable behaviour, with a fading edge on
              // the right to hint there's more to see.
              return Stack(
                children: [
                  ListView(
                    controller: _controller,
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    children: tabs,
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: 18,
                    child: IgnorePointer(
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              Color(0x00FFFFFF),
                              Colors.white,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
      ),
    );
  }
}

class _NavTab extends StatefulWidget {
  final double width;
  final NavTabItem item;
  final bool selected;
  final VoidCallback onTap;

  const _NavTab({
    required this.width,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_NavTab> createState() => _NavTabState();
}

class _NavTabState extends State<_NavTab> with SingleTickerProviderStateMixin {
  double _pressScale = 1.0;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressScale = 0.88),
      onTapCancel: () => setState(() => _pressScale = 1.0),
      onTapUp: (_) => setState(() => _pressScale = 1.0),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressScale,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: SizedBox(
          width: widget.width,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  gradient: selected ? AppTheme.goldGradient : null,
                  color: selected ? null : Colors.transparent,
                  shape: BoxShape.circle,
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: AppTheme.goldDeep.withValues(alpha: 0.4),
                            blurRadius: 16,
                            spreadRadius: 1,
                          ),
                        ]
                      : [],
                ),
                child: Icon(
                  selected ? (widget.item.activeIcon ?? widget.item.icon) : widget.item.icon,
                  color: selected ? AppTheme.navy : AppTheme.textFaint,
                  size: 22,
                ),
              ),
              const SizedBox(height: 4),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 280),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? AppTheme.navy : AppTheme.textFaint,
                ),
                child: Text(
                  widget.item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 2),
              AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                height: 3,
                width: selected ? 16 : 0,
                decoration: BoxDecoration(
                  gradient: AppTheme.goldGradient,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
