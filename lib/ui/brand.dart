import 'package:flutter/material.dart';

import 'connection_scene.dart';

const acDarkAsset = 'assets/brand/ac-dark.png';
const acLightAsset = 'assets/brand/ac-light.png';
const acBannerAsset = 'assets/brand/ac-banner.png';

/// The original two-way transfer symbol, adapted to the monochrome palette.
class LineMark extends StatelessWidget {
  const LineMark({super.key, this.size = 44, this.onDark = false});
  final double size;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: onDark ? const Color(0xFFF5F4F2) : const Color(0xFF242220),
          borderRadius: BorderRadius.circular(size * .25),
        ),
        child: Center(
          child: Icon(
            Icons.swap_horiz_rounded,
            size: size * .64,
            color: onDark ? const Color(0xFF242220) : Colors.white,
          ),
        ),
      ),
    );
  }
}

class AcBrandPanel extends StatelessWidget {
  const AcBrandPanel({super.key});

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: ColoredBox(
      color: const Color(0xFF201F1D),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 24, 24, 0),
            child: Row(
              children: [
                Icon(Icons.route_outlined, color: Color(0xFFCFCEC6), size: 16),
                SizedBox(width: 9),
                Text(
                  'A LITTLE CLOSER.',
                  style: TextStyle(
                    color: Color(0xFFCFCEC6),
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.7,
                  ),
                ),
              ],
            ),
          ),
          const ConnectionScene(),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 4, 24, 26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your ideas.\nOn the move.',
                  style: TextStyle(
                    color: Color(0xFFF5F4F2),
                    fontSize: 29,
                    height: 1.12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -1,
                  ),
                ),
                SizedBox(height: 13),
                Text(
                  'A temporary room. A connection between your devices. Your files, always yours.',
                  style: TextStyle(
                    color: Color(0xFFC9C7C3),
                    fontSize: 12,
                    height: 1.7,
                  ),
                ),
              ],
            ),
          ),
          Image.asset(
            acBannerAsset,
            width: double.infinity,
            height: 118,
            fit: BoxFit.cover,
            alignment: Alignment.center,
            semanticLabel: 'Active Creators. Create. Innovate. Transform.',
          ),
        ],
      ),
    ),
  );
}
