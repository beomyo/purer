import 'dart:math' as math;
import 'dart:typed_data';

import 'package:purer/services/media/frame_analysis.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

// A decodable frame reports its dimensions; invalid bytes are rejected so the
// caller can fall back to libmpv. Both also cover the resource handling: the
// decoded buffer is owned by one place only, disposing it twice throws a
// native peer error.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List pngOf(void Function(img.Image image) paint, {int size = 64}) {
    final image = img.Image(width: size, height: size);
    paint(image);
    return img.encodePng(image);
  }

  test('decodable frame reports its dimensions', () async {
    final bytes = pngOf((image) {
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          image.setPixelRgba(x, y, 12, 12, 12, 255);
        }
      }
    });
    final analysis = await analyzeFrame(bytes);
    expect(analysis, isNotNull);
    expect(analysis!.width, 64);
    expect(analysis.height, 64);
  });

  test('frame with content is accepted like any other', () async {
    final bytes = pngOf((image) {
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final checker = ((x ~/ 4) + (y ~/ 4)) % 2 == 0 ? 240 : 20;
          image.setPixelRgba(x, y, checker, 255 - checker, (x * 4) % 256, 255);
        }
      }
    });
    final analysis = await analyzeFrame(bytes);
    expect(analysis, isNotNull);
    expect(analysis!.width, 64);
  });

  test('invalid bytes do not throw', () async {
    final bytes = Uint8List.fromList(List<int>.generate(32, (i) => math.Random(i).nextInt(256)));
    final analysis = await analyzeFrame(bytes);
    expect(analysis, isNull);
  });
}
