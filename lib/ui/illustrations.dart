import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';

class FileStack extends StatefulWidget {
  const FileStack({super.key});
  @override
  State<FileStack> createState() => _FileStackState();
}

class _FileStackState extends State<FileStack> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox(
        width: 176,
        height: 120,
        child: AmbientMotion(
          duration: const Duration(seconds: 10),
          builder: (context, t) => TweenAnimationBuilder<double>(
            tween: Tween(end: _hovered ? 1 : 0, begin: 0),
            duration: MotionScope.enabledOf(context)
                ? const Duration(milliseconds: 420)
                : Duration.zero,
            curve: Curves.easeOutCubic,
            builder: (context, hover, _) {
              final wave = math.sin(t * math.pi * 2);
              return Stack(
                alignment: Alignment.center,
                children: [
                  Transform.translate(
                    offset: Offset(-35 - hover * 7, 8 + wave * 2),
                    child: Transform.rotate(
                      angle: -.18 - hover * .07,
                      child: _paper(
                        Icons.image_outlined,
                        const Color(0xFFE7E5DF),
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(35 + hover * 7, 8 - wave * 2),
                    child: Transform.rotate(
                      angle: .18 + hover * .07,
                      child: _paper(
                        Icons.description_outlined,
                        const Color(0xFFF0EFEB),
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(0, -4 - wave * 3 - hover * 4),
                    child: _paper(Icons.play_arrow_rounded, Colors.white),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _paper(IconData icon, Color background) => Container(
    width: 62,
    height: 78,
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFD8D6D0)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0D000000),
          offset: Offset(0, 6),
          blurRadius: 12,
        ),
      ],
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 26, color: ink),
        const SizedBox(height: 10),
        Container(
          width: 22,
          height: 3,
          decoration: BoxDecoration(
            color: ink.withValues(alpha: .18),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 5),
        Container(
          width: 15,
          height: 3,
          decoration: BoxDecoration(
            color: ink.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    ),
  );
}
