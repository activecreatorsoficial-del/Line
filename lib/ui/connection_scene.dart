import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion.dart';

/// A decorative explanation, never a claim about the current network state.
class ConnectionScene extends StatelessWidget {
  const ConnectionScene({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: double.infinity,
      height: 174,
      child: AmbientMotion(
        builder: (context, t) => LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            return Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(child: CustomPaint(painter: _RoutePainter(t))),
                Positioned(
                  left: w * .09,
                  top: 60 + math.sin(t * math.pi * 2) * 3,
                  child: _laptop(),
                ),
                Positioned(
                  right: w * .10,
                  top: 45 - math.sin(t * math.pi * 2) * 3,
                  child: _phone(),
                ),
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: const Color(0xFF343431),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF666660)),
                  ),
                  child: const Icon(
                    Icons.swap_horiz_rounded,
                    size: 24,
                    color: Color(0xFFF7F7F3),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _laptop() => Column(
    children: [
      Container(
        width: 66,
        height: 45,
        decoration: BoxDecoration(
          color: const Color(0xFF272725),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFD9D8D2), width: 1.5),
        ),
        child: const Icon(
          Icons.folder_outlined,
          color: Color(0xFFC6C5BE),
          size: 20,
        ),
      ),
      const SizedBox(height: 4),
      Container(
        width: 78,
        height: 3,
        decoration: BoxDecoration(
          color: const Color(0xFFD9D8D2),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    ],
  );

  Widget _phone() => Container(
    width: 35,
    height: 67,
    decoration: BoxDecoration(
      color: const Color(0xFF272725),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFD9D8D2), width: 1.5),
    ),
    child: const Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Padding(
          padding: EdgeInsets.only(top: 6),
          child: SizedBox(
            width: 10,
            child: Divider(height: 1, color: Color(0xFF85857D)),
          ),
        ),
        Icon(
          Icons.insert_drive_file_outlined,
          size: 16,
          color: Color(0xFFC6C5BE),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: SizedBox(
            width: 12,
            child: Divider(height: 1, color: Color(0xFF85857D)),
          ),
        ),
      ],
    ),
  );
}

class _RoutePainter extends CustomPainter {
  _RoutePainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final grid = Paint()..color = const Color(0xFF454540);
    for (double x = 18; x < w; x += 18) {
      for (double y = 12; y < h; y += 18) {
        canvas.drawCircle(Offset(x, y), .65, grid);
      }
    }
    final center = Offset(w / 2, h / 2);
    canvas.drawCircle(
      center,
      58,
      Paint()
        ..color = const Color(0xFF393936)
        ..style = PaintingStyle.stroke,
    );
    canvas.drawCircle(
      center,
      41,
      Paint()
        ..color = const Color(0xFF40403B)
        ..style = PaintingStyle.stroke,
    );
    final stroke = Paint()
      ..color = const Color(0xFF68685F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var direction = 0; direction < 2; direction++) {
      final y = direction == 0 ? h * .39 : h * .61;
      final path = Path()
        ..moveTo(w * .24, y)
        ..cubicTo(w * .42, y - 16, w * .58, y + 16, w * .77, y);
      canvas.drawPath(path, stroke);
      final metric = path.computeMetrics().first;
      for (var i = 0; i < 3; i++) {
        final p = (t * 2 + i / 3) % 1;
        final point = metric
            .getTangentForOffset(metric.length * (direction == 0 ? p : 1 - p))!
            .position;
        canvas.drawCircle(point, 2.4, Paint()..color = const Color(0xFFE8E7DE));
      }
    }
  }

  @override
  bool shouldRepaint(_RoutePainter oldDelegate) => oldDelegate.t != t;
}
