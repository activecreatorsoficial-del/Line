import 'package:flutter/material.dart';

import 'brand.dart';
import 'motion.dart';

const ink = Color(0xFF20201E);
const muted = Color(0xFF65625E);
const accent = Color(0xFF292725);
const softSurface = Color(0xFFF0EFEC);
const canvas = Color(0xFFF7F7F4);
const line = Color(0xFFE2E2DC);
const sidebarHighlight = Color(0xFFF5F4F1);
const sidebar = Color(0xFF201F1D);
const sidebarMuted = Color(0xFFBFBCB7);

ThemeData lineTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    surface: Colors.white,
    primary: accent,
    onPrimary: Colors.white,
    onSurface: ink,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: canvas,
    fontFamily: 'Inter',
    focusColor: accent.withValues(alpha: .16),
    hoverColor: accent.withValues(alpha: .06),
    splashFactory: InkRipple.splashFactory,
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? ink : Colors.white,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? Colors.white : muted,
        ),
        side: const WidgetStatePropertyAll(BorderSide(color: line)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: 'Inter',
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontSize: 16, height: 1.55, color: ink),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: ink),
      bodySmall: TextStyle(fontSize: 12, height: 1.5, color: muted),
      titleLarge: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        letterSpacing: -.5,
        color: ink,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 54),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        side: const BorderSide(color: line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: canvas,
      contentPadding: const EdgeInsets.all(18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: accent, width: 2),
      ),
    ),
    dividerTheme: const DividerThemeData(color: line, thickness: 1),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: ink,
        hoverColor: ink.withValues(alpha: .07),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: softSurface,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

class LineLogo extends StatelessWidget {
  const LineLogo({super.key, this.small = false, this.onDark = false});
  final bool small;
  final bool onDark;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      MotionHover(
        child: LineMark(size: small ? 39 : 44, onDark: onDark),
      ),
      const SizedBox(width: 11),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'line',
            style: TextStyle(
              fontSize: small ? 28 : 33,
              fontWeight: FontWeight.w600,
              letterSpacing: -1.5,
              height: 1,
              color: onDark ? Colors.white : ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'ACTIVE CREATORS',
            style: TextStyle(
              fontSize: 6.5,
              letterSpacing: .95,
              fontWeight: FontWeight.w500,
              color: onDark ? sidebarMuted : muted,
            ),
          ),
        ],
      ),
      if (!small) ...[
        const SizedBox(width: 7),
        Text(
          'BETA',
          style: TextStyle(
            fontSize: 9,
            letterSpacing: 1,
            color: onDark ? sidebarMuted : muted,
          ),
        ),
      ],
    ],
  );
}
