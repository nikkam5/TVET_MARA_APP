import 'package:flutter/material.dart';

/// The admin workspace uses quiet surfaces and a single primary accent.
class AdminUi {
  AdminUi._();

  static const background = Color(0xFFF7F9FC);
  static const ink = Color(0xFF182539);
  static const muted = Color(0xFF718096);
  static const navy = Color(0xFF15345B);
  static const border = Color(0xFFE7ECF3);
  static const lavender = Color(0xFFF2F3FF);
  static const mist = Color(0xFFEFF8F7);
  static const success = Color(0xFF21836B);
  static const warning = Color(0xFFAA7725);

  static BoxDecoration panel({double radius = 16}) => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: border),
    boxShadow: const [
      BoxShadow(color: Color(0x07152B4D), blurRadius: 20, offset: Offset(0, 8)),
    ],
  );

  static ThemeData theme(BuildContext context) {
    final base = Theme.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    return base.copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: navy,
      ).copyWith(primary: navy, surface: Colors.white, onSurface: ink),
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      dividerColor: border,
      splashFactory: InkSparkle.splashFactory,
      cardTheme: CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        labelStyle: const TextStyle(color: muted, fontSize: 14),
        hintStyle: const TextStyle(color: muted, fontSize: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: navy, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: navy,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize: const Size(0, 46),
          shape: shape,
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: navy,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 46),
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: navy,
          side: const BorderSide(color: border),
          minimumSize: const Size(0, 46),
          shape: shape,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dataTableTheme: const DataTableThemeData(
        headingRowColor: WidgetStatePropertyAll(background),
        headingTextStyle: TextStyle(
          color: muted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        dataTextStyle: TextStyle(color: ink, fontSize: 13),
        dividerThickness: 0.5,
      ),
    );
  }
}

class AdminPage extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget body;
  final Widget? action;
  final double maxWidth;
  const AdminPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.body,
    this.action,
    this.maxWidth = 1280,
  });

  @override
  Widget build(BuildContext context) => Theme(
    data: AdminUi.theme(context),
    child: Scaffold(
      backgroundColor: AdminUi.background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        foregroundColor: AdminUi.ink,
        elevation: 0,
        toolbarHeight: 68,
        title: Row(
          children: [
            Image.asset(
              'assets/images/tvetmara_logo.png',
              width: 100,
              height: 34,
              semanticLabel: 'TVET MARA',
            ),
            const SizedBox(width: 20),
            const Expanded(
              child: Text(
                'Admin workspace',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: AdminUi.muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AdminUi.border),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              children: [
                AdminPageHeading(
                  title: title,
                  subtitle: subtitle,
                  action: action,
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class AdminPageHeading extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? action;
  const AdminPageHeading({
    super.key,
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 600;
      final text = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: compact ? 25 : 30,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.8,
              color: AdminUi.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(
              color: AdminUi.muted,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      );
      return Padding(
        padding: EdgeInsets.fromLTRB(20, compact ? 20 : 30, 20, 24),
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  text,
                  if (action != null) ...[
                    const SizedBox(height: 16),
                    Align(alignment: Alignment.centerLeft, child: action!),
                  ],
                ],
              )
            : Row(
                children: [
                  Expanded(child: text),
                  if (action != null) ...[const SizedBox(width: 24), action!],
                ],
              ),
      );
    },
  );
}

class AdminEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const AdminEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AdminUi.navy.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(icon, color: AdminUi.navy, size: 30),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AdminUi.ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AdminUi.muted, height: 1.5),
          ),
        ],
      ),
    ),
  );
}
