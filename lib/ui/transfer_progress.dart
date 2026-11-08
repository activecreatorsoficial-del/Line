import 'package:flutter/material.dart';

import '../core/transfer.dart';
import 'theme.dart';
import 'motion.dart';

class TransferProgress extends StatelessWidget {
  const TransferProgress({
    super.key,
    required this.progress,
    required this.transferred,
    required this.total,
    required this.speed,
    required this.complete,
  });
  final double progress;
  final int transferred;
  final int total;
  final double speed;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: ink,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                complete ? 'DELIVERED & VERIFIED' : 'TRANSFER IN PROGRESS',
                style: const TextStyle(
                  color: Color(0xFFC9C9C0),
                  fontSize: 9,
                  letterSpacing: 1.3,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              MotionSwap(
                identity: complete,
                child: Icon(
                  complete
                      ? Icons.check_circle_rounded
                      : Icons.north_east_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 8,
            children: [
              Text(
                '${(progress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(
                  fontSize: 40,
                  height: 1.1,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -1,
                  color: Colors.white,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                complete
                    ? 'Transfer complete'
                    : 'On the way to the other device',
                style: const TextStyle(color: Color(0xFFCECEC5), fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Semantics(
            label: 'Transfer progress',
            value: '${(progress * 100).toStringAsFixed(0)}%',
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: progress, end: progress),
              duration: MotionScope.enabledOf(context)
                  ? const Duration(milliseconds: 300)
                  : Duration.zero,
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => complete
                  ? CustomPaint(
                      size: const Size(double.infinity, 8),
                      painter: _ProgressPainter(value, 0),
                    )
                  : AmbientMotion(
                      duration: const Duration(seconds: 3),
                      builder: (context, t) => CustomPaint(
                        size: const Size(double.infinity, 8),
                        painter: _ProgressPainter(value, t),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              Text(
                '${formatBytes(transferred)} of ${formatBytes(total)}',
                style: const TextStyle(color: Color(0xFFCECEC5), fontSize: 11),
              ),
              if (!complete)
                Text(
                  '${formatBytes(speed)}/s',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter(this.progress, this.phase);
  final double progress;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(4),
    );
    canvas.drawRRect(track, Paint()..color = const Color(0xFF4B4B45));
    final fill = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width * progress.clamp(0, 1), size.height),
      const Radius.circular(4),
    );
    canvas.save();
    canvas.clipRRect(fill);
    canvas.drawRRect(fill, Paint()..color = const Color(0xFFDEDED4));
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .45)
      ..strokeWidth = 3;
    for (double x = -20 + phase * 20; x < size.width + 20; x += 20) {
      canvas.drawLine(Offset(x, size.height), Offset(x + 8, 0), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ProgressPainter oldDelegate) =>
      progress != oldDelegate.progress || phase != oldDelegate.phase;
}
