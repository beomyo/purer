import 'dart:math';

import 'package:purer/image_providers/full_image_provider.dart';
import 'package:purer/image_providers/region_provider.dart';
import 'package:purer/image_providers/thumbnail_provider.dart';
import 'package:purer/model/entry/cache.dart';
import 'package:purer/model/entry/entry.dart';
import 'package:purer/model/entry/extensions/props.dart';
import 'package:purer/model/settings/settings.dart';
import 'package:purer_utils/purer_utils.dart';
import 'package:collection/collection.dart';
import 'package:flutter/painting.dart';

extension ExtraPurerEntryImages on PurerEntry {
  bool isThumbnailReady({double extent = 0}) => _isReady(_getThumbnailProviderKey(extent));

  ThumbnailProvider getThumbnail({double extent = 0}) {
    return ThumbnailProvider(_getThumbnailProviderKey(extent));
  }

  ThumbnailProviderKey _getThumbnailProviderKey(double extent) {
    final key = ThumbnailProviderKey(
      uri: uri,
      mimeType: mimeType,
      pageId: pageId,
      rotationDegrees: rotationDegrees,
      isFlipped: isFlipped,
      dateModifiedMillis: dateModifiedMillis ?? -1,
      extent: extent.roundToDouble(),
      videoThumbnailMethods: isVideo ? settings.videoThumbnailMethods : null,
    );
    EntryCache.registerKey(key);
    return key;
  }

  RegionProvider getRegion({int sampleSize = 1, double scale = 1, required Rectangle<num> region}) {
    final key = RegionProviderKey(
      uri: uri,
      mimeType: mimeType,
      pageId: pageId,
      sizeBytes: sizeBytes,
      rotationDegrees: rotationDegrees,
      isFlipped: isFlipped,
      sampleSize: sampleSize,
      regionRect: Rectangle(
        (region.left * scale).round(),
        (region.top * scale).round(),
        (region.width * scale).round(),
        (region.height * scale).round(),
      ),
      imageSize: Size((width * scale).toDouble(), (height * scale).toDouble()),
    );
    EntryCache.registerKey(key);
    return RegionProvider(key);
  }

  Rectangle<double> get fullImageRegion => Rectangle<double>(.0, .0, width.toDouble(), height.toDouble());

  FullImage getFullImage() {
    var key = FullImage(
      uri: uri,
      mimeType: mimeType,
      pageId: pageId,
      rotationDegrees: rotationDegrees,
      isFlipped: isFlipped,
      isAnimated: isAnimated,
      sizeBytes: sizeBytes,
    );
    EntryCache.registerKey(key);
    return key;
  }

  bool _isReady(Object providerKey) => imageCache.statusForKey(providerKey).keepAlive;

  List<ThumbnailProvider> get cachedThumbnails => EntryCache.getThumbnailProviderKeys(uri).where(_isReady).map(ThumbnailProvider.new).toList();

  ThumbnailProvider get bestCachedThumbnail => cachedThumbnails.firstOrNull ?? getThumbnail();

  static int sampleSizeForScale({
    required double magnifierScale,
    required double devicePixelRatio,
  }) {
    var sample = 0;
    if (0 < magnifierScale && magnifierScale < 1) {
      sample = highestPowerOf2(1 / (magnifierScale * devicePixelRatio));
    }
    return max<int>(1, sample);
  }
}
