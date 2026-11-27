import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Fullscreen rectangular zoom overlay that magnifies the local area under the touch point
/// to fill the entire container/screen, allowing the user to pan around the current screen content.
class FullscreenZoomMagnifier extends StatelessWidget {
  final ValueListenable<Offset> positionNotifier;
  final double scale;

  const new({
    super.key,
    required this.positionNotifier,
    this.scale = 2.5,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveScale = scale <= 1.0 ? 1.01 : scale;

    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            final cx = width / 2;
            final cy = height / 2;
            final maxFx = cx * (1.0 - 1.0 / effectiveScale);
            final maxFy = cy * (1.0 - 1.0 / effectiveScale);

            return ValueListenableBuilder<Offset>(
              valueListenable: positionNotifier,
              builder: (context, pos, child) {
                final rawFx = pos.dx - cx;
                final rawFy = pos.dy - cy;
                final clampedFx = rawFx.clamp(-maxFx, maxFx);
                final clampedFy = rawFy.clamp(-maxFy, maxFy);

                return RawMagnifier(
                  size: Size(width, height),
                  magnificationScale: effectiveScale,
                  focalPointOffset: Offset(clampedFx, clampedFy),
                  decoration: const MagnifierDecoration(),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

typedef LoupeMagnifier = FullscreenZoomMagnifier;
