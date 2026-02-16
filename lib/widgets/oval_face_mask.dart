import 'package:flutter/material.dart';

/// A full-screen overlay that draws a dark scrim with an oval cut-out
/// in the centre, sized / positioned to frame a human face.
///
/// During the colour-challenge phase the area *outside* the oval is
/// tinted with [challengeColor] instead of the default dark scrim.
class OvalFaceMask extends StatelessWidget {
  /// Colour of the border drawn around the oval.
  final Color borderColor;

  /// Optional tint applied to the scrim area during the colour challenge.
  /// When `null` the default dark scrim is used.
  final Color? challengeColor;

  /// Callback that delivers the oval [Rect] in global coordinates once
  /// layout is known.  Used by [LivenessService] to check face overlap.
  final ValueChanged<Rect>? onOvalRect;

  const OvalFaceMask({
    super.key,
    this.borderColor = Colors.white,
    this.challengeColor,
    this.onOvalRect,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);

        // Oval dimensions — roughly face-shaped.
        final ovalWidth = size.width * 0.65;
        final ovalHeight = size.height * 0.42;
        final ovalRect = Rect.fromCenter(
          center: Offset(size.width / 2, size.height * 0.40),
          width: ovalWidth,
          height: ovalHeight,
        );

        // Report the oval rect back to the parent.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onOvalRect?.call(ovalRect);
        });

        return CustomPaint(
          size: size,
          painter: _OvalMaskPainter(
            ovalRect: ovalRect,
            borderColor: borderColor,
            challengeColor: challengeColor,
          ),
        );
      },
    );
  }
}

class _OvalMaskPainter extends CustomPainter {
  final Rect ovalRect;
  final Color borderColor;
  final Color? challengeColor;

  _OvalMaskPainter({
    required this.ovalRect,
    required this.borderColor,
    this.challengeColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fullRect = Offset.zero & size;

    // 1. Scrim path with oval hole punched out.
    final scrimPath = Path()
      ..addRect(fullRect)
      ..addOval(ovalRect)
      ..fillType = PathFillType.evenOdd;

    final scrimColor =
        challengeColor?.withAlpha(180) ?? Colors.white.withAlpha(220);

    canvas.drawPath(scrimPath, Paint()..color = scrimColor);

    // 2. Oval border.
    canvas.drawOval(
      ovalRect,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0,
    );

    // 3. Subtle inner glow ring for premium feel.
    canvas.drawOval(
      ovalRect.deflate(4),
      Paint()
        ..color = borderColor.withAlpha(60)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _OvalMaskPainter oldDelegate) =>
      borderColor != oldDelegate.borderColor ||
      challengeColor != oldDelegate.challengeColor ||
      ovalRect != oldDelegate.ovalRect;
}
