import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

// Intrinsic dimensions of a frame that was decoded successfully. The frame is
// decoded at a small size only to verify the payload: a frame that cannot be
// decoded must fall back to libmpv instead of being cached as a thumbnail.
class FrameAnalysis {
  final int width;
  final int height;

  const new({
    required this.width,
    required this.height,
  });

  @override
  String toString() => 'FrameAnalysis(${width}x$height)';
}

// Decodes a frame at a small size and reports its intrinsic dimensions.
//
// The descriptor/buffer are owned here (rather than going through
// `instantiateImageCodecWithSize`, which disposes the buffer itself): disposing
// the same native peer twice throws a "native peer has been collected" error.
Future<FrameAnalysis?> analyzeFrame(Uint8List bytes, {int sampleSize = 48}) async {
  if (bytes.isEmpty) return null;
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final intrinsicWidth = descriptor.width;
    final intrinsicHeight = descriptor.height;
    if (intrinsicWidth <= 0 || intrinsicHeight <= 0) return null;

    final longest = math.max(intrinsicWidth, intrinsicHeight);
    final scale = longest <= sampleSize ? 1.0 : sampleSize / longest;
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (intrinsicWidth * scale).round()),
      targetHeight: math.max(1, (intrinsicHeight * scale).round()),
    );
    // mirror dart:ui's own helper: the buffer can be released once the codec
    // exists, but the descriptor must stay alive until the codec is done. It
    // is released in the `finally`, after the codec.
    buffer.dispose();
    buffer = null;

    final frame = await codec.getNextFrame();
    image = frame.image;
    if (image.width <= 0 || image.height <= 0) return null;
    return FrameAnalysis(width: intrinsicWidth, height: intrinsicHeight);
  } catch (error) {
    debugPrint('frame analysis failed: $error');
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    // after the codec: disposing the descriptor earlier can invalidate a codec
    // that has not decoded its frame yet
    descriptor?.dispose();
    buffer?.dispose();
  }
}
