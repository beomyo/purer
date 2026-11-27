import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import 'package:purer/image_providers/region_provider.dart';
import 'package:purer/image_providers/thumbnail_provider.dart';
import 'package:purer/model/entry/cache.dart';
import 'package:purer/model/entry/entry.dart';
import 'package:purer/model/entry/extensions/props.dart';
import 'package:purer/model/settings/modules/cloud.dart';
import 'package:purer/model/settings/settings.dart';
import 'package:purer/ref/mime_types.dart';
import 'package:purer/services/common/cloud_registry.dart';
import 'package:purer/services/common/decoding.dart';
import 'package:purer/services/common/service_policy.dart';
import 'package:purer/services/common/services.dart';
import 'package:purer/services/log/purer_log.dart';
import 'package:purer/services/media/cloud_client.dart';
import 'package:purer/services/media/cloud_disk_cache.dart';
import 'package:purer/services/media/frame_analysis.dart';
import 'package:purer/services/media/cloud_media_cache.dart';
import 'package:purer/services/media/cloud_traffic.dart';
import 'package:purer/services/media/media_fetch_service.dart';
import 'package:purer/utils/cloud_url.dart';
import 'package:purer_model/purer_model.dart';
import 'package:purer_report/purer_report.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

class CloudImageLoader {
  // hard caps on the decoded dimensions: remote files can be enormous, and
  // decoding several of them at native resolution is what used to OOM
  static const int _maxThumbnailDim = 1024;
  static const int _highThumbnailDim = 2048;
  static const int _maxOriginalThumbnailDim = 3072;
  static const int _minFullImageDim = 1024;
  // the viewer can zoom up to 6x: decoding at barely more than one screen
  // width made text unreadable as soon as the user pinched in
  static const int _maxFullImageDim = 4096;
  static const int _maxHighFullImageDim = 5120;
  static const int _maxOriginalFullImageDim = 4096;

  // a thumbnail and the viewer can ask for the same file at the same time;
  // share the download instead of fetching it twice
  final Map<String, Future<Uint8List>> _inflight = {};
  // one per download in progress, so a folder that was left stops pulling
  // bytes instead of keeping the connection and the bandwidth for minutes
  final Map<String, CloudAbort> _aborts = {};
  Future<Uint8List> bytesFor(String url) {
    final pending = _inflight[url];
    if (pending != null) return pending;
    final abort = CloudAbort();
    _aborts[url] = abort;
    final future = _loadBytes(url, abort);
    _inflight[url] = future;
    return future.whenComplete(() {
      // only clear our own entries: an aborted transfer completes after a new
      // request for the same URL may already have replaced them
      if (identical(_inflight[url], future)) _inflight.remove(url);
      if (identical(_aborts[url], abort)) _aborts.remove(url);
    });
  }

  // drops the downloads belonging to entries the user left. The transfer is
  // aborted at the socket level so the next folder's listing does not queue
  // behind it. A later request for the same URL starts over.
  void abandon(Iterable<String> urls) {
    for (final url in urls) {
      final abort = _aborts.remove(url);
      if (abort == null) continue;
      _inflight.remove(url);
      abort.abort();
    }
  }

  Future<Uint8List> _loadBytes(String url, CloudAbort abort) async {
    final cached = await cloudDiskCache.get(url);
    if (cached != null) return cached;

    final client = cloudRegistry.clientForUrl(url);
    if (client == null) {
      throw const CloudException('没有为该地址配置云服务');
    }
    final bytes = await client.getBytes(url, abort: abort);
    if (bytes.isNotEmpty) {
      await cloudDiskCache.put(url, bytes);
    }
    return bytes;
  }

  // decodes while bounding the longest side to `maxDim` (never upscaling),
  // so memory stays proportional to the tile/screen size instead of the file
  static Future<ui.Codec> decodeBounded(
    Uint8List bytes,
    ImageDecoderCallback decode,
    int maxDim, {
    void Function(int width, int height)? onDimensions,
  }) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(
      buffer,
      getTargetSize: (intrinsicWidth, intrinsicHeight) {
        if (intrinsicWidth > 0 && intrinsicHeight > 0) {
          onDimensions?.call(intrinsicWidth, intrinsicHeight);
        }
        // a non-positive cap means 'keep the native resolution'
        if (maxDim <= 0) return const ui.TargetImageSize();
        final longest = math.max(intrinsicWidth, intrinsicHeight);
        if (longest <= maxDim || longest == 0) {
          return const ui.TargetImageSize();
        }
        final scale = maxDim / longest;
        return ui.TargetImageSize(
          width: math.max(1, (intrinsicWidth * scale).round()),
          height: math.max(1, (intrinsicHeight * scale).round()),
        );
      },
    );
  }

  // largest side to decode a thumbnail at, for a tile of the given extent.
  // 0 means 'no bound' (the `original` quality decodes at native resolution).
  static int thumbnailMaxDim(double extent) {
    final devicePixelRatio = ui.PlatformDispatcher.instance.views.firstOrNull?.devicePixelRatio ?? 1.0;
    final requested = extent > 0 ? (extent * devicePixelRatio).round() : 256;
    return switch (settings.cloudThumbnailQuality) {
      // the file is already downloaded in full: the quality only decides how
      // much of it is decoded, so memory stays proportional to the tile.
      // 'original' decodes exactly the tile's pixels (never upscaled, and never
      // beyond what a screen can show), which is what a mosaic needs
      'original' => requested.clamp(1, _maxOriginalThumbnailDim),
      'high' => requested.clamp(1, _highThumbnailDim),
      _ => requested.clamp(1, _maxThumbnailDim),
    };
  }

  Future<ui.Codec> loadThumbnail(
    ThumbnailProviderKey request,
    ImageDecoderCallback? decode,
    Object? taskKey,
    int? priority,
  ) {
    applyCloudDecodeBudget();
    final extent = request.extent;
    final maxDim = thumbnailMaxDim(extent);
    final key = CloudAwareMediaFetchService.cloudKey(taskKey ?? request);
    return servicePolicy.call(
      () async {
        // a small copy of the image a tile displayed before: decoding it is
        // local and costs no download. It is never allowed to replace the
        // original dimensions recorded for the viewer.
        final small = await _smallThumbnailOf(request.uri, maxDim);
        if (small != null) {
          try {
            return await decodeBounded(small, decoderFor(decode), maxDim);
          } catch (_) {
            await evictCloudThumbnailCopy(request.uri);
          }
        }
        final bytes = await bytesFor(request.uri);
        try {
          return await decodeBounded(
            bytes,
            decoderFor(decode),
            maxDim,
            onDimensions: (width, height) {
              settings.setCloudImageDimensions(request.uri, width, height);
            },
          );
        } catch (_) {
          // a payload that cannot be decoded (truncated, corrupt, or a stale
          // cache entry) must be dropped so the next attempt downloads it again
          await cloudDiskCache.remove(request.uri);
          rethrow;
        }
      },
      priority: priority ?? (extent == 0 ? ServiceCallPriority.getFastThumbnail : ServiceCallPriority.getSizedThumbnail),
      key: key,
    );
  }

  Future<ui.Codec> loadFullImage(
    ImageRequest request,
    ImageDecoderCallback decode,
  ) {
    applyCloudDecodeBudget();
    final view = ui.PlatformDispatcher.instance.views.firstOrNull;
    // decode at roughly the screen size, allowing a little zoom headroom,
    // instead of at the file's native resolution
    final longSide = view == null ? _minFullImageDim : math.max(view.physicalSize.width, view.physicalSize.height).round();
    final maxDim = switch (settings.cloudThumbnailQuality) {
      // 'original' decodes the file as-is, but a hard cap keeps a huge photo
      // (50MP+) from allocating hundreds of MB in one go; the decoded bitmap
      // budget then decides how many of them stay cached
      'original' => _maxOriginalFullImageDim,
      'high' => (longSide * 3.0).round().clamp(_minFullImageDim, _maxHighFullImageDim),
      _ => (longSide * 2.0).round().clamp(_minFullImageDim, _maxFullImageDim),
    };
    return servicePolicy.call(
      () async {
        final bytes = await bytesFor(request.uri);
        try {
          return await decodeBounded(bytes, decode, maxDim);
        } catch (_) {
          // a truncated/corrupt download must not stay cached: the viewer's
          // retry would otherwise decode the same bad bytes forever
          await cloudDiskCache.remove(request.uri);
          rethrow;
        }
      },
      priority: ServiceCallPriority.normal,
      // one request per file and decode size, even when the viewer and a
      // prefetch ask together (a quality change must not reuse the old codec)
      key: '${request.uri}@$maxDim',
    );
  }

  // the framework provides a decoder for sized thumbnails; fall back to
  // `instantiateImageCodec` when it is missing
  static ImageDecoderCallback decoderFor(ImageDecoderCallback? decode) {
    if (decode != null) return decode;
    throw UnreportedStateError('missing decoder for cloud thumbnail');
  }
}

final cloudImageLoader = CloudImageLoader();

// ---- small thumbnail copies ----
//
// A tile only ever displays a bounded decode of a remote original, but the disk
// cache used to keep the full downloaded bytes. For a phone browsing a NAS full
// of 12MP JPEGs that cache holds a few dozen images. Copies of the decoded
// tile-sized images are much smaller, so the same budget serves an order of
// magnitude more pictures and coming back to a folder needs no download.
const String _thumbCopyDataPrefix = 'thumb-copy:';
const String _thumbCopyMetaPrefix = 'thumb-copy-meta:';
// above this the copy is resized down: a larger copy would cost more CPU and
// disk for a tile that is rarely shown that large
const int _thumbCopyMaxDim = 1600;
// at most this many encodes run (serialized) at once, so browsing a large
// folder never queues hundreds of background encodes
const int _thumbCopyMaxPending = 3;

final Map<String, int> _thumbCopyDims = {};
final Set<String> _thumbCopyQueued = {};
int _thumbCopyPending = 0;

String _thumbCopyDataKey(String uri) => '$_thumbCopyDataPrefix$uri';
String _thumbCopyMetaKey(String uri) => '$_thumbCopyMetaPrefix$uri';

Future<int> _thumbCopyDim(String uri) async {
  final cached = _thumbCopyDims[uri];
  if (cached != null) return cached;
  final bytes = await cloudDiskCache.get(_thumbCopyMetaKey(uri));
  final dim = (bytes != null && bytes.length >= 4) ? ByteData.sublistView(bytes).getUint32(0) : 0;
  if (_thumbCopyDims.length > 4000) _thumbCopyDims.clear();
  _thumbCopyDims[uri] = dim;
  return dim;
}

Future<Uint8List?> _smallThumbnailOf(String uri, int maxDim) async {
  if (!settings.cloudThumbnailDiskCacheEnabled) return null;
  // a much smaller copy would look soft: keep the original instead
  final dim = await _thumbCopyDim(uri);
  if (dim <= 0 || dim < maxDim * 0.7) return null;
  final bytes = await cloudDiskCache.get(_thumbCopyDataKey(uri));
  if (bytes == null) {
    // the data file was evicted while its metadata stayed: drop both, otherwise
    // `cacheCloudThumbnailCopy` reads the stale size back from the metadata and
    // decides the copy is still there, so it is never written again
    await evictCloudThumbnailCopy(uri);
  }
  return bytes;
}

// Stores a JPEG copy of a cloud image that was just displayed. Called from the
// thumbnail widget, on the UI isolate, but the encoding itself runs in a
// separate isolate and never blocks a frame.
Future<void> cacheCloudThumbnailCopy(String uri, ui.Image image) async {
  if (!isCloudUri(uri) || !settings.cloudThumbnailDiskCacheEnabled) return;
  final width = image.width;
  final height = image.height;
  final longest = math.max(width, height);
  if (longest < 96) return;
  final targetDim = math.min(longest, _thumbCopyMaxDim);
  final known = await _thumbCopyDim(uri);
  if (known >= targetDim * 0.9) return;
  // a queue is already draining: this picture gets its copy on a later visit
  if (_thumbCopyPending >= _thumbCopyMaxPending) return;
  if (!_thumbCopyQueued.add(uri)) return;
  _thumbCopyPending++;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return;
    final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final scale = longest > _thumbCopyMaxDim ? _thumbCopyMaxDim / longest : 1.0;
    final jpeg = await Isolate.run(() => _encodeThumbnailJpeg(rgba, width, height, scale));
    if (jpeg == null || jpeg.isEmpty) return;
    final encodedDim = (longest * scale).round();
    if ((_thumbCopyDims[uri] ?? 0) >= encodedDim) return;
    await cloudDiskCache.put(_thumbCopyDataKey(uri), jpeg);
    final meta = ByteData(4)..setUint32(0, encodedDim);
    await cloudDiskCache.put(_thumbCopyMetaKey(uri), meta.buffer.asUint8List());
    if (_thumbCopyDims.length > 4000) _thumbCopyDims.clear();
    _thumbCopyDims[uri] = encodedDim;
  } catch (error) {
    purerLog.debug(PurerLogCategory.thumbnail, '缓存缩略图副本失败 ${PurerLog.redactUrl(uri)} error=$error');
  } finally {
    _thumbCopyQueued.remove(uri);
    _thumbCopyPending--;
  }
}

Future<void> evictCloudThumbnailCopy(String uri) async {
  _thumbCopyDims.remove(uri);
  await cloudDiskCache.remove(_thumbCopyDataKey(uri));
  await cloudDiskCache.remove(_thumbCopyMetaKey(uri));
}

// The local cache directory was wiped from the settings page: forget what has
// been written this session, otherwise the in-memory dimensions would keep
// skipping the copy that no longer exists.
void resetCloudThumbnailCaches() {
  _thumbCopyDims.clear();
  _thumbCopyQueued.clear();
  for (final key in _decodedSpriteSheets.keys.toList()) {
    final entry = _decodedSpriteSheets.remove(key)!;
    entry.evicted = true;
    if (entry.refs <= 0 && !entry.disposed) {
      entry.disposed = true;
      entry.image.dispose();
    }
  }
}

// runs in a separate isolate
Uint8List? _encodeThumbnailJpeg(Uint8List rgba, int width, int height, double scale) {
  try {
    var image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    if (scale < 0.98) {
      image = img.copyResize(
        image,
        width: math.max(1, (width * scale).round()),
        height: math.max(1, (height * scale).round()),
        interpolation: img.Interpolation.average,
      );
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: 85));
  } catch (_) {
    return null;
  }
}

// ---- decoded sprite sheets ----
//
// Every video tile used to decode its whole sprite sheet on its own, and again
// each time the mosaic reflowed its rows. The decoded images are now shared and
// kept in a small reference-counted cache, and each one is decoded for the size
// a cell is actually shown at (not a fixed 2048px cap).
class CloudSpriteSheetHandle {
  final ui.Image image;
  final int cols;
  final int rows;
  final void Function() release;

  const new({
    required this.image,
    required this.cols,
    required this.rows,
    required this.release,
  });
}

class _DecodedSpriteSheet {
  final String key;
  final ui.Image image;
  final int cols;
  final int rows;
  int refs = 1;
  bool evicted = false;
  bool disposed = false;

  new({
    required this.key,
    required this.image,
    required this.cols,
    required this.rows,
  });
}

const int _maxDecodedSpriteSheets = 8;
// a sheet is one JPEG holding many cells, so decoded size is what matters, not
// the number of sheets
const int _maxDecodedSpriteBytes = 64 << 20;
final Map<String, _DecodedSpriteSheet> _decodedSpriteSheets = {};
final Map<String, Future<CloudSpriteSheetHandle?>> _spriteSheetLoads = {};

// Decodes (or reuses) the sheet of a video for a cell of about `cellDim` pixels.
// The returned handle must be released once its tile no longer draws it.
// Nearby tile sizes share one decode: the sheet is decoded in steps of 64px
// per cell. Exposed so a resized tile does not reload a sheet it can reuse.
int cloudSpriteCellBucket(int cellDim) => ((cellDim / 64).ceil() * 64).clamp(64, 1024);

Future<CloudSpriteSheetHandle?> acquireCloudSpriteSheet(String uri, {required int cellDim}) async {
  final bucket = cloudSpriteCellBucket(cellDim);
  final key = '$uri|$bucket';
  final existing = _decodedSpriteSheets.remove(key);
  if (existing != null) {
    existing.refs++;
    _decodedSpriteSheets[key] = existing;
    return _spriteSheetHandle(existing);
  }
  final pending = _spriteSheetLoads[key];
  if (pending != null) return pending;
  final future = _loadDecodedSpriteSheet(key, uri, bucket);
  _spriteSheetLoads[key] = future;
  try {
    return await future;
  } finally {
    _spriteSheetLoads.remove(key)?.ignore();
  }
}

Future<CloudSpriteSheetHandle?> _loadDecodedSpriteSheet(String key, String uri, int cellDim) async {
  final loaded = await loadCloudSpriteSheet(uri, cellDim: cellDim);
  if (loaded == null) return null;
  final (image, cols, rows) = loaded;
  final entry = _DecodedSpriteSheet(key: key, image: image, cols: cols, rows: rows);
  _decodedSpriteSheets[key] = entry;
  _trimDecodedSpriteSheets();
  return _spriteSheetHandle(entry);
}

CloudSpriteSheetHandle _spriteSheetHandle(_DecodedSpriteSheet entry) {
  var released = false;
  return CloudSpriteSheetHandle(
    image: entry.image,
    cols: entry.cols,
    rows: entry.rows,
    release: () {
      if (released) return;
      released = true;
      entry.refs--;
      if (entry.refs > 0) return;
      if (entry.evicted) {
        if (!entry.disposed) {
          entry.disposed = true;
          entry.image.dispose();
        }
      } else {
        _trimDecodedSpriteSheets();
      }
    },
  );
}

int _decodedSpriteBytes() {
  var total = 0;
  for (final entry in _decodedSpriteSheets.values) {
    total += entry.image.width * entry.image.height * 4;
  }
  return total;
}

void _trimDecodedSpriteSheets() {
  while (_decodedSpriteSheets.length > _maxDecodedSpriteSheets || _decodedSpriteBytes() > _maxDecodedSpriteBytes) {
    String? victim;
    for (final entry in _decodedSpriteSheets.entries) {
      if (entry.value.refs <= 0) {
        victim = entry.key;
        break;
      }
    }
    // every sheet is still drawn by a tile: allow the temporary overshoot
    if (victim == null) return;
    final entry = _decodedSpriteSheets.remove(victim)!;
    if (!entry.disposed) {
      entry.disposed = true;
      entry.image.dispose();
    }
  }
}

// Drops the decoded copies of a video's sheet (its file was removed or
// replaced), disposing the ones nobody draws any more.
void _forgetDecodedSpriteSheets(String uri) {
  final prefix = '$uri|';
  for (final key in _decodedSpriteSheets.keys.toList()) {
    if (!key.startsWith(prefix)) continue;
    final entry = _decodedSpriteSheets.remove(key)!;
    entry.evicted = true;
    if (entry.refs <= 0 && !entry.disposed) {
      entry.disposed = true;
      entry.image.dispose();
    }
  }
}

// The budget used for the 'no budget' choice, see `applyCloudDecodeBudget`.
//
// It is derived from the device rather than fixed: a quarter of the total RAM,
// kept between 512 MiB and 2 GiB. A small phone then still evicts instead of
// being killed by the system, while a large one keeps far more decoded
// pictures. One gigabyte is used when the total cannot be read.
int? _unlimitedDecodeBudgetCache;

int get _unlimitedDecodeBudgetBytes => _unlimitedDecodeBudgetCache ??= _resolveUnlimitedDecodeBudget();

int _resolveUnlimitedDecodeBudget() {
  const fallback = 1 << 30;
  try {
    final text = File('/proc/meminfo').readAsStringSync();
    final match = RegExp(r'^MemTotal:\s+(\d+)\s+kB', multiLine: true).firstMatch(text);
    final totalBytes = (match == null ? 0 : int.parse(match.group(1)!)) * 1024;
    if (totalBytes <= 0) return fallback;
    return (totalBytes ~/ 4).clamp(512 << 20, 2 << 30);
  } catch (_) {
    return fallback;
  }
}

// Applies the user's decoded bitmap budget to Flutter's global image cache.
// The cache evicts the least recently used images above it, which is what
// keeps the 'high'/'original' qualities from exhausting the heap.
void applyCloudDecodeBudget() {
  // `0` is the user's 'no budget' choice: the cap is a quarter of the device
  // RAM (see `_unlimitedDecodeBudgetBytes`), high enough that the cache stops
  // dropping pictures the user just looked at, while a phone with little memory
  // still evicts before the system kills the process.
  final limitMb = settings.cloudDecodeMemoryLimitMb;
  final bytes = limitMb <= 0 ? _unlimitedDecodeBudgetBytes : limitMb * 1024 * 1024;
  if (imageCache.maximumSizeBytes != bytes) {
    imageCache.maximumSizeBytes = bytes;
  }
}

// URIs whose video frame is being extracted (queued or running), so a tile can
// show a progress indicator instead of an empty placeholder
final ValueNotifier<Set<String>> cloudGeneratingVideoThumbnails = ValueNotifier(const {});
// more than one request for the same video can overlap (a rebuilt tile with a
// different extent, another layout): count them so the first one to finish does
// not clear the spinner while another is still extracting
final Map<String, int> _videoGeneratingCounts = {};

void _setVideoThumbnailGenerating(String uri, bool generating) {
  final before = _videoGeneratingCounts[uri] ?? 0;
  final after = generating ? before + 1 : math.max(0, before - 1);
  if (after <= 0) {
    _videoGeneratingCounts.remove(uri);
  } else {
    _videoGeneratingCounts[uri] = after;
  }
  final wasGenerating = before > 0;
  final isGenerating = after > 0;
  if (wasGenerating == isGenerating) return;
  final next = {...cloudGeneratingVideoThumbnails.value};
  if (isGenerating) {
    next.add(uri);
  } else {
    next.remove(uri);
  }
  cloudGeneratingVideoThumbnails.value = next;
}

// URIs whose sprite sheet is being fetched, so the tile can show a spinner for
// that button while it runs. Only the sheet is downloaded; the animation itself
// just crops its cells on screen (no re-encoding), so there is nothing to build.
final ValueNotifier<Set<String>> cloudGeneratingSpriteAnimations = ValueNotifier(const {});

// bumped when a sprite sheet is dropped or invalidated globally (order change,
// quality change), so every tile re-checks whether it should animate
final ValueNotifier<int> cloudSpriteAnimationsVersion = ValueNotifier(0);
// the URIs whose sheet just finished downloading: only the tiles of those
// videos need to re-check (a global bump made every video tile stat the disk
// once per downloaded sheet, which is quadratic while a folder auto-loads)
final ValueNotifier<Set<String>> cloudSpriteAnimationUpdates = ValueNotifier(const {});

void _setSpriteAnimationGenerating(String uri, bool generating) {
  final before = cloudGeneratingSpriteAnimations.value.contains(uri);
  if (before == generating) return;
  final next = {...cloudGeneratingSpriteAnimations.value};
  if (generating) {
    next.add(uri);
  } else {
    next.remove(uri);
  }
  cloudGeneratingSpriteAnimations.value = next;
}

// The animation needs only the sprite sheet file, so its cache key is the sheet
// URL. The playback speed/order are applied at draw time and do not affect the
// cached bytes, so changing them never forces a re-download.
String _spriteSheetKey(String uri) => '${CloudAwareMediaFetchService._spriteAnimationCachePrefix}$uri';

// Whether a video already has its sprite sheet downloaded, so the tile can
// animate from it instead of showing the static frame.
Future<bool> hasCloudSpriteAnimation(String uri) async {
  if (!isCloudUri(uri)) return false;
  return cloudDiskCache.has(_spriteSheetKey(uri));
}

// Drops the downloaded sprite sheet of a video (e.g. its sheet changed or was
// removed), so the tile falls back to the static frame.
Future<void> evictCloudSpriteAnimation(String uri) async {
  await cloudDiskCache.remove(_spriteSheetKey(uri));
  _forgetDecodedSpriteSheets(uri);
  EntryCache.evict(uri);
  cloudSpriteAnimationsVersion.value++;
}

// drops the cached payload of a cloud entry (the extracted video frame, the
// downloaded sprite sheet and any downloaded image bytes), so the next request
// fetches it again
Future<void> evictCloudThumbnail(String uri, {bool video = false}) async {
  await cloudDiskCache.remove('${CloudAwareMediaFetchService._videoThumbnailCachePrefix}$uri');
  await cloudDiskCache.remove(_spriteSheetKey(uri));
  await cloudDiskCache.remove(uri);
  await evictCloudThumbnailCopy(uri);
  _forgetDecodedSpriteSheets(uri);
  cloudSpriteAnimationsVersion.value++;
  // a forced rebuild must replace the shared copy too, otherwise the next visit
  // would immediately load the stale one again
  if (video) {
    await cloudMediaCache.remove(uri);
  }
}

// Drops the local payload of one entry (extracted frame, sprite sheet and the
// downloaded original bytes) without touching the shared WebDAV mirror. The
// decoded bitmaps are dropped too, so the next resolve decodes the new bytes.
Future<void> evictCloudThumbnailLocal(PurerEntry entry) async {
  final uri = entry.uri;
  await cloudDiskCache.remove('${CloudAwareMediaFetchService._videoThumbnailCachePrefix}$uri');
  await cloudDiskCache.remove(_spriteSheetKey(uri));
  await cloudDiskCache.remove(uri);
  await evictCloudThumbnailCopy(uri);
  _forgetDecodedSpriteSheets(uri);
  EntryCache.evict(uri);
}

// Drops the shared-cache entries of several videos with one mirror listing per
// folder (bulk actions would otherwise cost one PROPFIND per video).
Future<void> evictCloudThumbnailsShared(Iterable<PurerEntry> entries) async {
  final byFolder = <String, List<String>>{};
  for (final entry in entries) {
    if (!entry.isVideo) continue;
    byFolder.putIfAbsent(CloudSettings.cloudParentUrl(entry.uri), () => []).add(CloudMediaCache.nameFor(entry.uri));
  }
  for (final item in byFolder.entries) {
    await cloudMediaCache.removeMany(item.key, item.value);
  }
}

// Local and shared cleanup of several entries (deleted files, or thumbnails
// that are about to be regenerated).
Future<void> evictCloudThumbnails(Iterable<PurerEntry> entries) async {
  final list = entries.toList();
  for (final entry in list) {
    await evictCloudThumbnailLocal(entry);
  }
  await evictCloudThumbnailsShared(list);
  cloudSpriteAnimationsVersion.value++;
}

// Decodes the downloaded sprite sheet of a video, bounded so a huge sheet
// cannot allocate tens of megabytes. The tile draws cells straight from the
// returned image (no per-frame image allocation). The sheet is decoded so one
// cell is about `cellDim` pixels, instead of at a fixed size that was far
// larger than most tiles.
Future<(ui.Image, int, int)?> loadCloudSpriteSheet(String uri, {required int cellDim}) async {
  final service = mediaFetchService;
  if (service is! CloudAwareMediaFetchService) return null;
  final bytes = await service.cachedSpriteSheet(uri);
  if (bytes == null || bytes.isEmpty) return null;
  final layout = await service.cachedSpriteLayout(uri);
  if (layout == null) return null;
  final (cols, rows) = layout;
  if (cols <= 0 || rows <= 0) return null;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longest = math.max(descriptor.width, descriptor.height);
    // a cell must have enough pixels for the tile, so the sheet needs
    // `cellDim` per row/column at least; still bounded so a huge sheet cannot
    // allocate tens of megabytes
    final targetLongest = (cellDim * math.max(cols, rows)).clamp(64, 2048);
    final scale = longest > targetLongest ? targetLongest / longest : 1.0;
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    final frame = await codec.getNextFrame();
    return (frame.image, cols, rows);
  } catch (error) {
    purerLog.warn(PurerLogCategory.thumbnail, '雪碧图解码失败 ${PurerLog.redactUrl(uri)} error=$error');
    return null;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
  }
}

// drops the downloads of entries the user has left (a folder change), so they
// stop competing with the listing of the folder being opened
void abandonCloudImages(Iterable<String> uris) => cloudImageLoader.abandon(uris);

// stores a frame captured while the user was watching the video, so the grid can
// show a thumbnail without asking the server to extract one
Future<void> saveCloudVideoThumbnail(String uri, Uint8List bytes, {int? durationMillis}) async {
  await cloudDiskCache.put('${CloudAwareMediaFetchService._videoThumbnailCachePrefix}$uri', bytes);
  await cloudMediaCache.put(
    uri,
    bytes,
    durationMillis: durationMillis ?? settings.cloudVideoDuration(uri),
    contentType: CloudAwareMediaFetchService._imageContentType(bytes),
  );
}

// drops the queued thumbnail extractions of entries the user has left, so the
// app stops generating for a folder that is no longer on screen
void abandonCloudVideoThumbnails(Iterable<String> uris) {
  final service = mediaFetchService;
  if (service is CloudAwareMediaFetchService) {
    service.abandonVideoThumbnails(uris);
  }
}

// thrown when the user left the folder an extraction belongs to
class _VideoThumbnailAbandoned implements Exception {
  const new();
}

// why an extraction did not produce a usable frame: the scrape page shows the
// reason per video so a failing library can be diagnosed instead of just
// counted
enum CloudVideoThumbnailFailure {
  disabled('自动抽帧已关闭'),
  cooldown('冷却中，稍后自动重试'),
  timeout('服务器响应超时'),
  rateLimited('服务器限流（429）'),
  auth('认证失败（401/403），请检查账号密码'),
  notFound('文件不存在（404）'),
  server('服务器错误（5xx）'),
  noFrame('无法解码视频（格式不支持或服务器不支持定位）'),
  abandoned('已取消'),
  unknown('未知错误');

  final String label;

  new(this.label);
}

class CloudVideoThumbnailResult {
  final Uint8List? bytes;
  // the frame was already available locally or in the shared cache
  final bool cached;
  final CloudVideoThumbnailFailure? failure;
  final String? message;
  final int attempts;
  // position (percent of the duration) of the frame that was kept
  final double? percent;
  final int? durationMillis;
  final int? width;
  final int? height;
  // 'platform' or 'mpv'
  final String? method;

  const new({
    this.bytes,
    this.cached = false,
    this.failure,
    this.message,
    this.attempts = 0,
    this.percent,
    this.durationMillis,
    this.width,
    this.height,
    this.method,
  });

  bool get ok => bytes != null;

  CloudVideoThumbnailResult withProgress({int? durationMillis, int? width, int? height}) {
    return CloudVideoThumbnailResult(
      bytes: bytes,
      cached: cached,
      failure: failure,
      message: message,
      attempts: attempts,
      percent: percent,
      durationMillis: durationMillis ?? this.durationMillis,
      width: width ?? this.width,
      height: height ?? this.height,
      method: method,
    );
  }
}

// What one "animate sprite thumbnails" action achieved for a folder.
class CloudSpriteAnimationSummary {
  final int generated;
  // videos of the folder without a sprite sheet (their thumbnail is untouched)
  final int skipped;
  final int failed;

  const new({this.generated = 0, this.skipped = 0, this.failed = 0});
}

// Decorates the platform media fetch service so that remote URIs
// (WebDAV entries) are served from the network while every other URI
// keeps using the platform implementation unchanged.
class CloudAwareMediaFetchService implements MediaFetchService {
  // the platform stream carries a one byte trailer describing the payload
  // (should match `FORMAT_BYTE_*` on the Android side)
  static const int _formatByteEncoded = 0xCA;
  static const int _formatByteDecoded = 0xFE;
  static const int _rawFrameMaxDim = 1024;
  // smallest extent a frame is extracted at, so a frame cached from a small
  // list tile still looks right in the grid and the mosaic
  static const double _minVideoThumbnailExtent = 256;

  // remote servers can rate limit aggressive clients (AList/OpenList expose such
  // a limit), and one frame extraction costs several round trips, so the budget
  // is generous; extractions are also serialized below so the limit is shared
  // rather than multiplied
  static const _videoThumbnailTimeout = Duration(seconds: 45);
  static const _videoThumbnailCooldown = Duration(seconds: 30);
  // a timeout is usually a slow/rate limited server rather than a file that
  // cannot be thumbnailed: retry it sooner than a decode failure, but not so
  // soon that another streaming read is queued while the platform retriever
  // (which Dart cannot cancel) may still be reading the file
  static const _videoThumbnailTimeoutCooldown = Duration(seconds: 60);
  // an automatic extraction that keeps failing backs off further, up to this
  static const _maxVideoThumbnailCooldown = Duration(minutes: 30);
  // extracted frames live in `cloudDiskCache`, so they survive a restart
  static const _videoThumbnailCachePrefix = 'video-thumb:';
  // looping GIF built from a scraped sprite sheet, kept separately from the
  // static frame so it can be shown instead of it once the user asks for it
  static const _spriteAnimationCachePrefix = 'video-sprite:';
  // how many sprite sheets are converted to animations at once (each runs in
  // its own isolate via `compute`, so this bounds CPU and memory)
  static const int _spriteAnimationConcurrency = 3;
  // the looping animation replays at a fixed rate set by the user (default 2
  // frames/s), independent of the video duration
  static const _durationProbeTimeout = Duration(seconds: 20);
  // at most this many frame extractions run at once. The tile path and the
  // scraper share this budget, on top of the per-folder rate limit, so
  // browsing and scraping never multiply the load on the server.
  static const int _videoExtractionMax = 4;
  int _videoExtractionRunning = 0;
  final Queue<Completer<void>> _videoExtractionWaiters = Queue();
  // shared-cache uploads started by a tile, so a scrape can wait for them
  // before listing the mirror instead of re-extracting the same video
  final Map<String, Future<void>> _frameUploads = {};

  final MediaFetchService _delegate;
  final Map<String, DateTime> _videoThumbCooldown = {};
  // durations already probed in this session, so a grid of tiles does not probe
  // the same video over and over
  final Set<String> _durationProbed = {};
  // long sessions over large libraries must not keep every failed video and
  // every probed duration forever
  static const int _maxCooldownEntries = 4000;
  static const int _maxDurationProbed = 4000;

  // consecutive failures per video: the cooldown doubles on each one, so a
  // video that cannot be thumbnailed is not re-read on every rebuild, folder
  // visit or retry. Without this, a single failing file could keep the
  // connection busy for as long as the folder stayed open.
  final Map<String, int> _videoThumbFailureCount = {};

  void _rememberCooldown(String uri, Duration duration) {
    var failures = (_videoThumbFailureCount[uri] ?? 0) + 1;
    if (_videoThumbFailureCount.length >= _maxCooldownEntries) {
      _videoThumbFailureCount.removeWhere((key, _) => !_videoThumbCooldown.containsKey(key));
      if (_videoThumbFailureCount.length >= _maxCooldownEntries) {
        _videoThumbFailureCount.remove(_videoThumbFailureCount.keys.first);
      }
    }
    _videoThumbFailureCount[uri] = failures;
    var delay = duration;
    for (var i = 1; i < failures && delay < _maxVideoThumbnailCooldown; i++) {
      delay *= 2;
    }
    if (delay > _maxVideoThumbnailCooldown) delay = _maxVideoThumbnailCooldown;
    final now = DateTime.now();
    if (_videoThumbCooldown.length >= _maxCooldownEntries) {
      _videoThumbCooldown.removeWhere((_, until) => !now.isBefore(until));
      if (_videoThumbCooldown.length >= _maxCooldownEntries) {
        _videoThumbCooldown.remove(_videoThumbCooldown.keys.first);
      }
    }
    _videoThumbCooldown[uri] = now.add(delay);
  }

  // a frame was extracted (or the user asked for a fresh one): the video is
  // readable again, so the backoff starts from the base delay next time
  void _clearCooldown(String uri) {
    _videoThumbCooldown.remove(uri);
    _videoThumbFailureCount.remove(uri);
  }

  // extraction rate limit: minimum interval between starts per folder. The
  // rate is read on every acquire so a change applies to the next extraction
  // (and to the scraper). A minimum interval yields a steady N per second
  // instead of a burst of N requests at the start of every second.
  final Map<String, DateTime> _videoThumbnailLastStart = {};

  // generation per entry, bumped when the user leaves the folder it belongs to,
  // so queued extractions of that folder are dropped
  final Map<String, int> _abandonedVideoGeneration = {};

  new(this._delegate);

  @override
  Future<PurerEntry?> getEntry(String uri, String? mimeType, {bool allowUnsized = false}) {
    if (isCloudUri(uri)) return Future.value(null);
    return _delegate.getEntry(uri, mimeType, allowUnsized: allowUnsized);
  }

  @override
  Future<Uint8List> getOriginalBytes(PurerEntry entry) {
    if (isCloudUri(entry.uri)) return cloudImageLoader.bytesFor(entry.uri);
    return _delegate.getOriginalBytes(entry);
  }

  @override
  Future<ui.Codec> getFullImage({
    required bool decoded,
    required ImageRequest request,
    required ImageDecoderCallback decode,
  }) {
    if (isCloudUri(request.uri)) {
      return cloudImageLoader.loadFullImage(request, decode);
    }
    return _delegate.getFullImage(decoded: decoded, request: request, decode: decode);
  }

  @override
  Future<ui.Codec> getRegion({
    required bool decoded,
    required RegionProviderKey request,
    required ImageDecoderCallback decode,
    Object? taskKey,
    int? priority,
  }) {
    // remote entries never use tiling (see `ExtraPurerEntryProps.useTiles`)
    if (isCloudUri(request.uri)) {
      throw UnreportedStateError('region requests are not supported for remote entries uri=${request.uri}');
    }
    return _delegate.getRegion(decoded: decoded, request: request, decode: decode, taskKey: taskKey, priority: priority);
  }

  @override
  Future<ui.Codec> getThumbnail({
    required bool decoded,
    required ThumbnailProviderKey request,
    ImageDecoderCallback? decode,
    Object? taskKey,
    int? priority,
  }) {
    if (isCloudUri(request.uri)) {
      if (MimeTypes.isVideo(request.mimeType)) {
        return _getCloudVideoThumbnail(
          decoded: decoded,
          request: request,
          decode: decode,
          taskKey: taskKey,
          priority: priority,
        );
      }
      return cloudImageLoader.loadThumbnail(request, decode, taskKey, priority);
    }
    return _delegate.getThumbnail(decoded: decoded, request: request, decode: decode, taskKey: taskKey, priority: priority);
  }

  @override
  Future<Uint8List> getThumbnailBytes({
    required bool decoded,
    required ThumbnailProviderKey request,
    String? uriOverride,
    Map<String, String>? httpHeaders,
    double? previewFraction,
    Object? taskKey,
    int? priority,
  }) {
    return _delegate.getThumbnailBytes(
      decoded: decoded,
      request: request,
      uriOverride: uriOverride,
      httpHeaders: httpHeaders,
      previewFraction: previewFraction,
      taskKey: taskKey,
      priority: priority,
    );
  }

  @override
  Future<int?> getVideoDuration(String uri) => _delegate.getVideoDuration(uri);

  // remote videos are extracted as a frame by the platform, which needs the
  // playable URL and the auth headers of the owning server. The extracted frame
  // is cached on disk so that a restart does not fetch it again, and libmpv is
  // used as a fallback for containers the platform cannot decode.

  // abandons the queued extractions of entries the user has left. Nothing is
  // cancelled mid-flight (a platform call cannot be aborted), but the rest of
  // the queue is dropped instead of hitting the server.
  void abandonVideoThumbnails(Iterable<String> uris) {
    for (final uri in uris) {
      _abandonedVideoGeneration[uri] = (_abandonedVideoGeneration[uri] ?? 0) + 1;
    }
    if (_abandonedVideoGeneration.length > 4000) {
      _abandonedVideoGeneration.clear();
    }
  }

  int _generationOf(String uri) => _abandonedVideoGeneration[uri] ?? 0;

  void _throwIfAbandoned(int generation, String uri) {
    if (generation != _generationOf(uri)) {
      throw const _VideoThumbnailAbandoned();
    }
  }

  static String _folderOf(String uri) => CloudSettings.cloudParentUrl(uri);

  // waits until another extraction may start for this folder, then records
  // this one. The minimum interval (1/rate) keeps the server at the configured
  // rate, steadily, instead of releasing a whole second's budget at once.
  Future<void> _acquireVideoThumbnailRate(String uri) async {
    // the same rule for browsing and scraping: the video's own folder
    final folder = _folderOf(uri);
    while (true) {
      final now = DateTime.now();
      final rate = settings.cloudThumbnailRateForFolder(folder);
      final interval = Duration(microseconds: (Duration.microsecondsPerSecond / rate).round());
      final last = _videoThumbnailLastStart[folder];
      if (last == null || now.difference(last) >= interval) {
        _videoThumbnailLastStart[folder] = now;
        if (_videoThumbnailLastStart.length > 2000) {
          _videoThumbnailLastStart.removeWhere((_, started) => now.difference(started) > const Duration(minutes: 1));
        }
        return;
      }
      await Future<void>.delayed(last.add(interval).difference(now));
    }
  }

  // local disk cache first, then the optional shared WebDAV cache. A frame
  // found remotely is copied into the local cache so the next visit is local.
  Future<Uint8List?> _cachedVideoThumbnailBytes(String uri) async {
    final cacheKey = '$_videoThumbnailCachePrefix$uri';
    final local = await cloudDiskCache.get(cacheKey);
    if (local != null) return local;
    final remote = await cloudMediaCache.get(uri);
    if (remote != null) {
      unawaited(cloudDiskCache.put(cacheKey, remote));
      return remote;
    }
    return null;
  }

  // the uniformity analysis is advisory (it only decides whether another
  // position is worth trying): a failure there must never turn an extracted
  // frame into a failed thumbnail
  static Future<FrameAnalysis?> _safeAnalyze(Uint8List bytes, String uri) async {
    try {
      return await analyzeFrame(bytes);
    } catch (error) {
      purerLog.warn(PurerLogCategory.thumbnail, '画面分析失败 ${PurerLog.redactUrl(uri)} error=$error');
      return null;
    }
  }

  static CloudVideoThumbnailFailure _classifyFailure(Object error) {
    if (error is TimeoutException) return CloudVideoThumbnailFailure.timeout;
    if (error is CloudAbortException) return CloudVideoThumbnailFailure.abandoned;
    if (error is CloudException) {
      final status = error.statusCode;
      if (status == 401 || status == 403) return CloudVideoThumbnailFailure.auth;
      if (status == 404) return CloudVideoThumbnailFailure.notFound;
      if (status == 408) return CloudVideoThumbnailFailure.timeout;
      if (status == 429) return CloudVideoThumbnailFailure.rateLimited;
      if (status != null && status >= 500) return CloudVideoThumbnailFailure.server;
      return CloudVideoThumbnailFailure.unknown;
    }
    // `PlatformException` from the native extractor: the container could not be
    // decoded, or the server did not give it the bytes it needed
    return CloudVideoThumbnailFailure.noFrame;
  }

  // The platform answers with a payload carrying a one byte format trailer:
  // usually an encoded JPEG/PNG, but it falls back to raw pixels when the
  // bitmap cannot be compressed (HDR/10 bit frames, unusual color spaces).
  // Raw pixels are not a decodable image, so they are re-encoded to PNG here;
  // the trailer is stripped from encoded payloads too.
  static Future<Uint8List?> _normalizeFramePayload(Uint8List payload, String uri) async {
    if (payload.isEmpty) return null;
    final trailer = payload.last;
    if (trailer == _formatByteEncoded) {
      if (payload.length <= 1) return null;
      // strip the trailer: some decoders reject bytes after the image data
      return Uint8List.sublistView(payload, 0, payload.length - 1);
    }
    if (trailer != _formatByteDecoded) {
      // not a payload in this format: accept it only if it really is an image,
      // otherwise let the caller try libmpv instead of handing garbage to the
      // decoder (which would be reported as an undecodable frame)
      return _looksLikeEncodedImage(payload) ? payload : null;
    }
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await InteropDecoding.rawBytesToDescriptor(payload);
      if (descriptor == null) return null;
      final width = descriptor.width;
      final height = descriptor.height;
      final longest = math.max(width, height);
      final scale = longest > _rawFrameMaxDim ? _rawFrameMaxDim / longest : 1.0;
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (width * scale).round()),
        targetHeight: math.max(1, (height * scale).round()),
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      purerLog.info(PurerLogCategory.thumbnail, '抽帧返回原始像素，已重新编码为 PNG ${PurerLog.redactUrl(uri)}');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (error) {
      purerLog.warn(PurerLogCategory.thumbnail, '原始像素帧无法转换 ${PurerLog.redactUrl(uri)} error=$error');
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
    }
  }

  static bool _looksLikeEncodedImage(Uint8List bytes) {
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true; // JPEG
    if (bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 && bytes[4] == 0x0D && bytes[5] == 0x0A && bytes[6] == 0x1A && bytes[7] == 0x0A) {
      return true; // PNG
    }
    if (bytes.length >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
      return true; // WebP
    }
    if (bytes.length >= 4 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) return true; // GIF
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) return true; // BMP
    return false;
  }

  // first bytes of a payload, for a failure report that says what was actually
  // produced (JPEG starts with ffd8, PNG with 89504e47)
  static String _hexHead(Uint8List bytes) {
    final count = math.min(4, bytes.length);
    return [for (var i = 0; i < count; i++) bytes[i].toRadixString(16).padLeft(2, '0')].join();
  }

  static String _imageContentType(Uint8List bytes) {
    // `put` names the file `.jpg`, but a frame re-encoded from libmpv is a PNG:
    // the server should serve the right type
    if (bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) return 'image/png';
    return 'image/jpeg';
  }

  Future<ui.Codec> _getCloudVideoThumbnail({
    required bool decoded,
    required ThumbnailProviderKey request,
    ImageDecoderCallback? decode,
    Object? taskKey,
    int? priority,
  }) async {
    final uri = request.uri;
    final decoder = CloudImageLoader.decoderFor(decode);
    final maxDim = CloudImageLoader.thumbnailMaxDim(request.extent);
    final cacheKey = '$_videoThumbnailCachePrefix$uri';
    final cached = await _cachedVideoThumbnailBytes(uri);
    if (cached != null) {
      try {
        final codec = await CloudImageLoader.decodeBounded(cached, decoder, maxDim);
        // a cached frame may predate the duration cache: fill it in without
        // holding the tile
        unawaited(_ensureDuration(uri, request.mimeType));
        return codec;
      } catch (_) {
        // drop a corrupt entry so the next attempt extracts a fresh frame
        purerLog.warn(PurerLogCategory.thumbnail, '缓存帧无法解码，重新抽帧 ${PurerLog.redactUrl(uri)}');
        unawaited(cloudDiskCache.remove(cacheKey));
        unawaited(cloudMediaCache.remove(uri));
      }
    }

    // automatic extraction is the expensive, server-hitting part, so it can be
    // turned off; a frame already known (captured while watching, or cached
    // from an earlier extraction) is still served
    if (!settings.cloudVideoThumbnails) {
      throw const CloudException('automatic video thumbnails are disabled');
    }

    final cooldownUntil = _videoThumbCooldown[uri];
    if (cooldownUntil != null && DateTime.now().isBefore(cooldownUntil)) {
      throw const CloudException('video thumbnail temporarily unavailable');
    }

    final generation = _generationOf(uri);
    final started = DateTime.now();
    _setVideoThumbnailGenerating(uri, true);
    try {
      final result = await _extractVideoFrame(
        uri: uri,
        mimeType: request.mimeType,
        // a frame extracted for a small tile is reused by every other layout
        // (the decoded bitmap is never upscaled), so extract at least at the
        // size the scraper uses
        extentDip: math.max(request.extent, _minVideoThumbnailExtent),
        basePercent: settings.cloudVideoThumbnailPercent,
        generation: generation,
        taskKey: taskKey,
        priority: priority,
      );
      if (!result.ok) {
        throw CloudException(result.failure?.label ?? 'failed to extract a video frame');
      }
      final bytes = result.bytes!;
      // the video is readable again: drop the failure backoff for it
      _clearCooldown(uri);
      final codec = await CloudImageLoader.decodeBounded(bytes, decoder, maxDim);
      // only cache a frame that decoded, so a bad entry cannot wedge the tile
      // same persistence as the scraper, so a frame created while browsing
      // is named, cached and uploaded exactly like a scraped one
      final upload = _persistFrame(uri, request.mimeType, result, probeDurationFallback: true);
      _trackFrameUpload(uri, upload);
      unawaited(upload);
      _logVideoThumbnail(uri, started, 'extracted', extra: 'percent=${result.percent?.toStringAsFixed(0)} attempts=${result.attempts} method=${result.method} bytes=${bytes.length}');
      return codec;
    } catch (error) {
      if (error is _VideoThumbnailAbandoned) {
        // the folder was left before this extraction started: not its fault
        _logVideoThumbnail(uri, started, 'abandoned');
        rethrow;
      }
      final failure = _classifyFailure(error);
      // a task paused while the tile scrolled away never completes, so the
      // timeout above fires without the file being at fault: do not back it off
      final isTimeout = error is TimeoutException;
      final pausedDuringWait = isTimeout && taskKey != null && servicePolicy.isPaused(taskKey);
      if (!pausedDuringWait && failure != CloudVideoThumbnailFailure.cooldown) {
        _rememberCooldown(uri, isTimeout ? _videoThumbnailTimeoutCooldown : _videoThumbnailCooldown);
      }
      _logVideoThumbnail(uri, started, 'failed', extra: 'reason=${failure.name} timeout=$isTimeout paused=$pausedDuringWait message=$error');
      rethrow;
    } finally {
      _setVideoThumbnailGenerating(uri, false);
    }
  }

  // Extractions in flight, keyed by video and folder visit.
  //
  // The same video can be requested several times at once (its tile, a tile
  // rebuilt at another extent, and the scraper). Each request used to start its
  // own streaming read of the file, which is what kept the network busy for a
  // long time after one extraction failed. Now they share a single read.
  final Map<String, Future<CloudVideoThumbnailResult>> _inflightExtractions = {};

  // Extracts a frame at the configured position.
  //
  // The platform extractor is used first; when it returns nothing (a container
  // it cannot decode, e.g. some MKV/WebM streams) libmpv is tried, so a video
  // the platform cannot handle is not counted as a failure.
  Future<CloudVideoThumbnailResult> _extractVideoFrame({
    required String uri,
    required String mimeType,
    required double extentDip,
    required double basePercent,
    required int generation,
    Object? taskKey,
    int? priority,
  }) {
    final key = '$uri|$generation';
    final existing = _inflightExtractions[key];
    if (existing != null) return existing;
    final future = _runExtraction(
      uri: uri,
      mimeType: mimeType,
      extentDip: extentDip,
      basePercent: basePercent,
      generation: generation,
      taskKey: taskKey,
      priority: priority,
    );
    _inflightExtractions[key] = future;
    unawaited(
      future
          .whenComplete(() {
            if (identical(_inflightExtractions[key], future)) _inflightExtractions.remove(key);
          })
          .catchError((Object _) => const CloudVideoThumbnailResult(failure: CloudVideoThumbnailFailure.abandoned)),
    );
    return future;
  }

  Future<CloudVideoThumbnailResult> _runExtraction({
    required String uri,
    required String mimeType,
    required double extentDip,
    required double basePercent,
    required int generation,
    Object? taskKey,
    int? priority,
  }) async {
    // visible in the log page's traffic panel: a frame extraction is one of
    // the few tasks whose transfer the app cannot measure, and leaving it out
    // made unexplained network activity look like a leak
    final transfer = cloudTraffic.begin('抽帧', uri);
    await _acquireVideoExtractionSlot();
    try {
      return await _extractVideoFrameUnbounded(
        uri: uri,
        mimeType: mimeType,
        extentDip: extentDip,
        basePercent: basePercent,
        generation: generation,
        taskKey: taskKey,
        priority: priority,
      );
    } finally {
      _releaseVideoExtractionSlot();
      cloudTraffic.finish(transfer);
    }
  }

  Future<void> _acquireVideoExtractionSlot() async {
    if (_videoExtractionRunning < _videoExtractionMax) {
      _videoExtractionRunning++;
      return;
    }
    final completer = Completer<void>();
    _videoExtractionWaiters.add(completer);
    await completer.future;
  }

  void _releaseVideoExtractionSlot() {
    if (_videoExtractionWaiters.isNotEmpty) {
      _videoExtractionWaiters.removeFirst().complete();
    } else if (_videoExtractionRunning > 0) {
      _videoExtractionRunning--;
    }
  }

  Future<CloudVideoThumbnailResult> _extractVideoFrameUnbounded({
    required String uri,
    required String mimeType,
    required double extentDip,
    required double basePercent,
    required int generation,
    Object? taskKey,
    int? priority,
  }) async {
    final source = await cloudRegistry.playbackSource(uri);
    final headers = source.headers.isEmpty ? null : source.headers;
    final request = ThumbnailProviderKey(
      uri: uri,
      mimeType: mimeType,
      pageId: null,
      rotationDegrees: 0,
      isFlipped: false,
      dateModifiedMillis: 0,
      extent: extentDip,
      videoThumbnailMethods: null,
    );

    var attempts = 0;
    CloudVideoThumbnailFailure? lastFailure;
    // a platform call that timed out may still be reading the file on the
    // native side (it cannot be cancelled): see the libmpv fallback below
    var platformTimedOut = false;
    // duration libmpv read while extracting, so the cache file name carries it
    int? mpvDurationMillis;
    String? lastMpvReason;
    String? lastMessage;

    final percent = basePercent.clamp(1.0, 99.0);
    final fraction = percent / 100;
    attempts++;
    _throwIfAbandoned(generation, uri);
    await _acquireVideoThumbnailRate(uri);
    _throwIfAbandoned(generation, uri);

    Uint8List? bytes;
    // Android cannot decode AVI/WMV on most devices; asking it anyway burns
    // the full platform timeout. libmpv reads them, so go there directly.
    final mpvFirst = _prefersLibMpv(mimeType);
    var method = mpvFirst ? 'mpv' : 'platform';
    if (mpvFirst) {
      purerLog.debug(PurerLogCategory.thumbnail, 'AVI/WMV 直接使用 libmpv 抽帧 ${PurerLog.redactUrl(uri)} percent=${percent.toStringAsFixed(0)}');
    } else {
      try {
        bytes = await _delegate
            .getThumbnailBytes(
              decoded: false,
              request: request,
              uriOverride: source.url,
              httpHeaders: headers,
              previewFraction: fraction,
              priority: priority ?? ServiceCallPriority.getVideoThumbnail,
            )
            .timeout(_videoThumbnailTimeout);
        if (bytes.isEmpty) bytes = null;
      } catch (error) {
        if (error is _VideoThumbnailAbandoned) rethrow;
        platformTimedOut = error is TimeoutException;
        lastFailure = _classifyFailure(error);
        lastMessage = '$error';
        purerLog.warn(PurerLogCategory.thumbnail, '平台抽帧失败 ${PurerLog.redactUrl(uri)} attempt=$attempts percent=${percent.toStringAsFixed(0)} reason=${lastFailure.name} error=$error');
      }
    }

    if (bytes != null) {
      // the payload may be raw pixels rather than an encoded image
      final pBytes = bytes;
      bytes = await _normalizeFramePayload(pBytes, uri);
      if (bytes == null) {
        purerLog.warn(
          PurerLogCategory.thumbnail,
          '平台抽帧数据无法解析，改用 libmpv ${PurerLog.redactUrl(uri)} attempt=$attempts bytes=${pBytes.length} trailer=0x${pBytes.last.toRadixString(16)}',
        );
      }
    }

    if (bytes == null) {
      if (platformTimedOut) {
        // `timeout` only abandons the Dart future: the platform retriever
        // (`MediaMetadataRetriever` over HTTP) can still be streaming the
        // video. Starting libmpv now would open a second read of the same
        // file and double the traffic on a server that is already too slow.
        purerLog.warn(PurerLogCategory.thumbnail, '平台抽帧超时，跳过 libmpv 后备 ${PurerLog.redactUrl(uri)}');
        return CloudVideoThumbnailResult(
          failure: lastFailure ?? CloudVideoThumbnailFailure.timeout,
          message: lastMessage,
          attempts: attempts,
        );
      }
      // the platform could not extract a frame from this container: let libmpv try
      _throwIfAbandoned(generation, uri);
      bytes = await _libMpvFrameBytes(
        uri: source.url,
        mimeType: mimeType,
        extentDip: extentDip,
        fraction: fraction,
        headers: headers,
        onDuration: (ms) => mpvDurationMillis = ms,
        onFailure: (reason) => lastMpvReason = reason,
      );
      method = 'mpv';
      if (bytes == null) {
        return CloudVideoThumbnailResult(
          failure: lastFailure ?? CloudVideoThumbnailFailure.noFrame,
          message: lastMessage ?? lastMpvReason,
          attempts: attempts,
        );
      }
    }

    var frameBytes = bytes;
    var analysis = await _safeAnalyze(frameBytes, uri);
    if (analysis == null && method != 'mpv') {
      // the platform payload is not a decodable image (unusual pixel format,
      // truncated transfer, ...): ask libmpv for the same position instead of
      // failing a file the platform could actually read
      purerLog.warn(
        PurerLogCategory.thumbnail,
        '平台帧无法解码，改用 libmpv ${PurerLog.redactUrl(uri)} attempt=$attempts bytes=${frameBytes.length} head=${_hexHead(frameBytes)}',
      );
      final fallback = await _libMpvFrameBytes(
        uri: source.url,
        mimeType: mimeType,
        extentDip: extentDip,
        fraction: fraction,
        headers: headers,
        onDuration: (ms) => mpvDurationMillis = ms,
        onFailure: (reason) => lastMpvReason = reason,
      );
      if (fallback != null) {
        frameBytes = fallback;
        method = 'mpv';
        analysis = await _safeAnalyze(frameBytes, uri);
      }
    }
    if (analysis == null) {
      lastFailure = CloudVideoThumbnailFailure.noFrame;
      lastMessage = '抽出的帧无法解码（${frameBytes.length} 字节，来源 $method，头部 ${_hexHead(frameBytes)}）';
      purerLog.warn(
        PurerLogCategory.thumbnail,
        '抽帧结果无法解码 ${PurerLog.redactUrl(uri)} attempt=$attempts percent=${percent.toStringAsFixed(0)} method=$method bytes=${frameBytes.length} head=${_hexHead(frameBytes)}',
      );
      return CloudVideoThumbnailResult(
        failure: lastFailure,
        message: lastMessage,
        attempts: attempts,
      );
    }
    return CloudVideoThumbnailResult(
      bytes: frameBytes,
      attempts: attempts,
      percent: percent,
      durationMillis: mpvDurationMillis,
      width: analysis.width,
      height: analysis.height,
      method: method,
    );
  }

  static bool _prefersLibMpv(String mimeType) {
    final mime = mimeType.toLowerCase();
    return mime == 'video/x-msvideo' || mime == 'video/avi' || mime == 'video/msvideo' || mime == 'video/vnd.avi' || mime == 'video/x-ms-wmv' || mime == 'video/x-ms-asf' || mime == 'video/x-ms-wm';
  }

  // a frame extracted by libmpv, PNG encoded so the shared cache can store the
  // same bytes the tile decodes
  Future<Uint8List?> _libMpvFrameBytes({
    required String uri,
    required String mimeType,
    required double extentDip,
    required double fraction,
    Map<String, String>? headers,
    void Function(int durationMillis)? onDuration,
    void Function(String reason)? onFailure,
  }) async {
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await videoMetadataFetcher
          .getThumbnailDescriptor(
            uri: uri,
            mimeType: mimeType,
            targetExtentDip: extentDip,
            // a non-empty list is required: with no method the mpv backend
            // looks for nothing and always returns no frame (which used to
            // make every container the platform cannot decode, such as AVI
            // and WMV, fail). `first` is the fallback when seeking fails.
            methods: const [VideoThumbnailMethod.preview, VideoThumbnailMethod.first],
            httpHeaders: headers,
            previewFraction: fraction,
            tempDirectory: await mpvTempDirectory(),
            onDuration: onDuration,
            onFailure: (reason) {
              onFailure?.call(reason);
              purerLog.warn(PurerLogCategory.thumbnail, 'libmpv 未能抽帧 ${PurerLog.redactUrl(uri)} percent=${(fraction * 100).toStringAsFixed(0)} reason=$reason');
            },
          )
          .timeout(_videoThumbnailTimeout);
      if (descriptor == null) {
        purerLog.warn(PurerLogCategory.thumbnail, 'libmpv 未返回画面 ${PurerLog.redactUrl(uri)} percent=${(fraction * 100).toStringAsFixed(0)}');
        return null;
      }
      codec = await descriptor.instantiateCodec(targetWidth: descriptor.width, targetHeight: descriptor.height);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (error) {
      purerLog.warn(PurerLogCategory.thumbnail, 'libmpv 抽帧失败 ${PurerLog.redactUrl(uri)} error=$error');
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
    }
  }

  // stores the extracted frame locally and, when the shared cache is on, in
  // the mirrored WebDAV folder. The duration becomes part of the file name, so
  // the next listing also restores it.
  Future<void> _persistFrame(String uri, String mimeType, CloudVideoThumbnailResult result, {bool probeDurationFallback = false}) async {
    final bytes = result.bytes;
    if (bytes == null) return;
    await cloudDiskCache.put('$_videoThumbnailCachePrefix$uri', bytes);
    var durationMillis = settings.cloudVideoDuration(uri) ?? result.durationMillis;
    // the platform usually knows the duration from the extraction that just
    // ran. Only the libmpv fallback opens the video again, and only when the
    // shared cache needs the duration for the file name: a local-only cache
    // must not re-read a video that is already cached.
    durationMillis ??= await _probeDuration(uri, mimeType, allowMpv: probeDurationFallback && cloudMediaCache.isReady);
    if (durationMillis != null && durationMillis > 0) {
      settings.setCloudVideoDuration(uri, durationMillis);
    }
    await cloudMediaCache.put(uri, bytes, durationMillis: durationMillis, contentType: _imageContentType(bytes));
  }

  // the platform probes the duration while extracting the frame; persist it so
  // the tile can show it, and so it survives a restart. When the platform did
  // not get it (some remote servers answer without a duration), libmpv can read
  // it from the container.
  Future<int?> _probeDuration(String uri, String mimeType, {bool allowMpv = false}) async {
    final already = settings.cloudVideoDuration(uri);
    if (already != null && already > 0) return already;
    // the libmpv fallback is a separate (more expensive) probe: a platform-only
    // attempt must not stop a later scrape from trying it
    final probeKey = allowMpv ? '$uri|mpv' : uri;
    if (_durationProbed.length >= _maxDurationProbed) _durationProbed.clear();
    if (!_durationProbed.add(probeKey)) return null;
    try {
      final source = await cloudRegistry.playbackSource(uri);
      final fromPlatform = await _delegate.getVideoDuration(source.url);
      if (fromPlatform != null && fromPlatform > 0) {
        purerLog.debug(PurerLogCategory.video, '读取时长 ${PurerLog.redactUrl(uri)} ${fromPlatform}ms');
        return fromPlatform;
      }
      if (!allowMpv) return null;
      final metadata = await videoMetadataFetcher.getMetadata(uri: source.url, mimeType: mimeType).timeout(_durationProbeTimeout);
      final seconds = metadata[Keys.duration];
      if (seconds is num && seconds > 0) {
        final millis = (seconds * 1000).round();
        purerLog.debug(PurerLogCategory.video, 'libmpv 读取时长 ${PurerLog.redactUrl(uri)} ${millis}ms');
        return millis;
      }
    } catch (error) {
      purerLog.debug(PurerLogCategory.video, '读取时长失败 ${PurerLog.redactUrl(uri)} error=$error');
    }
    return null;
  }

  // Fills in the duration of a video whose frame came from the cache, without
  // blocking the tile and without repeating the probe for every layout pass.
  Future<void> _ensureDuration(String uri, String mimeType) async {
    if (settings.cloudVideoDuration(uri) != null) return;
    final duration = await _probeDuration(uri, mimeType);
    if (duration != null && duration > 0) settings.setCloudVideoDuration(uri, duration);
  }

  static void _logVideoThumbnail(String uri, DateTime started, String outcome, {String? extra}) {
    final elapsedMs = DateTime.now().difference(started).inMilliseconds;
    purerLog.log(
      outcome == 'failed' ? PurerLogLevel.warn : PurerLogLevel.info,
      PurerLogCategory.thumbnail,
      '抽帧 $outcome ${PurerLog.redactUrl(uri)} ${elapsedMs}ms${extra == null ? '' : ' $extra'}',
    );
  }

  // Ensures a video has a thumbnail that can be shared through the WebDAV
  // cache, without a tile requesting it: used by the background scraper of a
  // folder. A frame already in the local or shared cache counts as done; a
  // missing one is extracted at the same rate limit as on-screen requests.
  //
  // `ignoreCooldown` lets a user-initiated retry really try again: the short
  // cooldown that keeps tiles from hammering a failing video would otherwise
  // answer the retry without reading anything.
  Future<CloudVideoThumbnailResult> scrapeVideoThumbnail(String uri, {required String mimeType, bool ignoreCooldown = false}) async {
    if (!isCloudUri(uri)) {
      return const CloudVideoThumbnailResult(failure: CloudVideoThumbnailFailure.unknown, message: 'not a cloud uri');
    }
    final cached = await _cachedVideoThumbnailBytes(uri);
    if (cached != null) {
      // a frame found locally may predate the shared copy: upload it, so other
      // devices find it (and its duration) in the mirrored cache folder
      final result = CloudVideoThumbnailResult(cached: true, bytes: cached, percent: settings.cloudVideoThumbnailPercent);
      await _persistFrame(uri, mimeType, result, probeDurationFallback: true);
      return result.withProgress(durationMillis: settings.cloudVideoDuration(uri));
    }

    if (ignoreCooldown) {
      // the user asked for this video specifically: start from a clean
      // backoff instead of inheriting the one from the automatic attempts
      _clearCooldown(uri);
    }
    final cooldownUntil = _videoThumbCooldown[uri];
    if (!ignoreCooldown && cooldownUntil != null && DateTime.now().isBefore(cooldownUntil)) {
      return const CloudVideoThumbnailResult(failure: CloudVideoThumbnailFailure.cooldown);
    }

    final generation = _generationOf(uri);
    final started = DateTime.now();
    _setVideoThumbnailGenerating(uri, true);
    try {
      final result = await _extractVideoFrame(
        uri: uri,
        mimeType: mimeType,
        // the scraper only needs a usable frame: a small one keeps the upload
        // and the decode cheap
        extentDip: 256,
        basePercent: settings.cloudVideoThumbnailPercent,
        generation: generation,
        priority: ServiceCallPriority.getVideoThumbnail,
      );
      if (!result.ok) {
        // a tile may have uploaded the frame while the extraction was running,
        // or the shared cache may have been briefly unavailable when the
        // scrape started: an existing frame must never be reported as a failure
        final existing = await _cachedAfterFailure(uri);
        if (existing != null) {
          _logVideoThumbnail(uri, started, 'scrape-found-cached', extra: 'reason=${result.failure?.name}');
          return existing;
        }
        _rememberCooldown(uri, result.failure == CloudVideoThumbnailFailure.timeout ? _videoThumbnailTimeoutCooldown : _videoThumbnailCooldown);
        _logVideoThumbnail(uri, started, 'scrape-failed', extra: 'reason=${result.failure?.name} attempts=${result.attempts}');
        return result;
      }
      // the extractor only returns frames it could decode and analyze, so the
      // frame can be cached and shared as is; the scraper waits for the upload,
      // so the mirrored cache folder only lists frames that are really there
      await _persistFrame(uri, mimeType, result, probeDurationFallback: true);
      _clearCooldown(uri);
      final duration = settings.cloudVideoDuration(uri);
      _logVideoThumbnail(
        uri,
        started,
        'scraped',
        extra: 'percent=${result.percent?.toStringAsFixed(0)} attempts=${result.attempts} method=${result.method} bytes=${result.bytes!.length}',
      );
      return result.withProgress(durationMillis: duration);
    } catch (error) {
      if (error is _VideoThumbnailAbandoned) {
        _logVideoThumbnail(uri, started, 'abandoned');
        return const CloudVideoThumbnailResult(failure: CloudVideoThumbnailFailure.abandoned);
      }
      final failure = _classifyFailure(error);
      final existing = await _cachedAfterFailure(uri);
      if (existing != null) {
        _logVideoThumbnail(uri, started, 'scrape-found-cached', extra: 'reason=${failure.name}');
        return existing;
      }
      _rememberCooldown(uri, failure == CloudVideoThumbnailFailure.timeout ? _videoThumbnailTimeoutCooldown : _videoThumbnailCooldown);
      _logVideoThumbnail(uri, started, 'scrape-failed', extra: 'reason=${failure.name} message=$error');
      return CloudVideoThumbnailResult(failure: failure, message: '$error');
    } finally {
      _setVideoThumbnailGenerating(uri, false);
    }
  }

  void _trackFrameUpload(String uri, Future<void> upload) {
    _frameUploads[uri] = upload;
    unawaited(
      upload
          .whenComplete(() {
            if (identical(_frameUploads[uri], upload)) _frameUploads.remove(uri);
          })
          .catchError((Object _) {}),
    );
  }

  // waits for the shared-cache uploads of a folder started while browsing, so
  // their files are visible when the scrape lists the mirror
  Future<void> waitForFrameUploads(String folderUrl) async {
    final folderKey = CloudSettings.cloudFolderKey(folderUrl);
    final pending = [
      for (final entry in _frameUploads.entries)
        if (CloudSettings.cloudFolderKey(CloudSettings.cloudParentUrl(entry.key)) == folderKey) entry.value,
    ];
    if (pending.isEmpty) return;
    await Future.wait(pending.map((upload) => upload.then<void>((_) {}, onError: (_, _) {})));
  }

  // checks the local and shared caches after an extraction failed, so a frame
  // that appeared meanwhile (another request, a slow upload) is not lost
  Future<CloudVideoThumbnailResult?> _cachedAfterFailure(String uri) async {
    final cached = await _cachedVideoThumbnailBytes(uri);
    if (cached == null) return null;
    final duration = settings.cloudVideoDuration(uri);
    return CloudVideoThumbnailResult(
      bytes: cached,
      cached: true,
      percent: settings.cloudVideoThumbnailPercent,
      durationMillis: duration,
    );
  }

  // Re-extracts a frame even though one is cached, used by the batch action on
  // the videos whose current thumbnail is not representative. The caller has
  // already evicted the cached frame.
  Future<CloudVideoThumbnailResult> regenerateVideoThumbnail(String uri, {required String mimeType}) async {
    if (!isCloudUri(uri)) return const CloudVideoThumbnailResult(failure: CloudVideoThumbnailFailure.unknown);
    final started = DateTime.now();
    _setVideoThumbnailGenerating(uri, true);
    try {
      // the user is asking for another frame: do not let a previous failure's
      // cooldown keep answering with the same old frame
      _clearCooldown(uri);
      final result = await _extractVideoFrame(
        uri: uri,
        mimeType: mimeType,
        extentDip: 256,
        basePercent: settings.cloudVideoThumbnailPercent,
        generation: _generationOf(uri),
        priority: ServiceCallPriority.getVideoThumbnail,
      );
      if (!result.ok) {
        _logVideoThumbnail(uri, started, 'regenerate-failed', extra: 'reason=${result.failure?.name} attempts=${result.attempts}');
        return result;
      }
      await _persistFrame(uri, mimeType, result, probeDurationFallback: true);
      _clearCooldown(uri);
      _logVideoThumbnail(uri, started, 'regenerated', extra: 'percent=${result.percent?.toStringAsFixed(0)} attempts=${result.attempts} method=${result.method}');
      return result;
    } catch (error) {
      final failure = _classifyFailure(error);
      _logVideoThumbnail(uri, started, 'regenerate-failed', extra: 'reason=${failure.name} message=$error');
      return CloudVideoThumbnailResult(failure: failure, message: '$error');
    } finally {
      _setVideoThumbnailGenerating(uri, false);
    }
  }

  // ---- sprite sheet thumbnails ----
  //
  // The desktop scraper can store a sprite sheet for a video (one JPEG holding
  // a `cols x rows` grid of frames). The app animates such a sheet by cropping
  // its cells one after another (no re-encoding, so no quality loss) in place of
  // the single extracted frame. Videos without a sheet keep their thumbnail.

  // the downloaded sprite sheet of a video, if it was fetched before
  Future<Uint8List?> cachedSpriteSheet(String uri) async {
    if (!isCloudUri(uri)) return null;
    return cloudDiskCache.get(_spriteSheetKey(uri));
  }

  // downloads the sprite sheet of a video and caches it, so the tile can animate
  // from it. Returns true when a sheet is now available, false on a real
  // download/decoding failure, and null when the video has no sprite sheet.
  Future<bool?> fetchSpriteSheet(String uri) async {
    if (!isCloudUri(uri)) return false;
    // already downloaded: nothing to do (the animation just needs to be shown)
    if (await cloudDiskCache.has(_spriteSheetKey(uri))) {
      cloudSpriteAnimationUpdates.value = {uri};
      return true;
    }
    final sprite = await cloudMediaCache.spriteFor(uri);
    if (sprite == null) return null;
    final bytes = await cloudMediaCache.spriteBytes(sprite);
    if (bytes == null || bytes.isEmpty) return false;
    await cloudDiskCache.put(_spriteSheetKey(uri), bytes);
    _rememberSpriteLayout(uri, (sprite.cols, sprite.rows));
    // the sheet replaces the static frame on the tile
    EntryCache.evict(uri);
    cloudSpriteAnimationUpdates.value = {uri};
    purerLog.info(PurerLogCategory.thumbnail, '雪碧图已下载并缓存 ${PurerLog.redactUrl(uri)} bytes=${bytes.length} ${sprite.cols}x${sprite.rows}');
    return true;
  }

  // sheets currently being fetched, keyed by uri, so the same video is not
  // downloaded twice when the folder auto-run and the button overlap
  final Map<String, Future<bool?>> _spriteFetches = {};
  // grid layout (cols, rows) of a downloaded sheet, remembered so the animating
  // provider does not have to re-list the folder on every first draw
  final Map<String, (int, int)> _spriteLayouts = {};

  void _rememberSpriteLayout(String uri, (int, int) layout) {
    _spriteLayouts[uri] = layout;
    // bound the memo of a long session over a large library
    while (_spriteLayouts.length > 4000) {
      _spriteLayouts.remove(_spriteLayouts.keys.first);
    }
  }

  Future<(int, int)?> cachedSpriteLayout(String uri) async {
    final cached = _spriteLayouts[uri];
    if (cached != null) return cached;
    final sprite = await cloudMediaCache.spriteFor(uri);
    if (sprite == null) return null;
    final layout = (sprite.cols, sprite.rows);
    _rememberSpriteLayout(uri, layout);
    return layout;
  }

  // Finds the sprite sheet of a folder and downloads it for every video that has
  // one and no cached sheet yet, several at a time. Only the sheets are fetched;
  // the frames themselves are never re-extracted, so this is cheap when the
  // scraper has already done the work. Videos without a sheet stay as they are.
  Future<CloudSpriteAnimationSummary> animateSpriteThumbnailsForFolder(
    String folderUrl,
    List<String> videoUris, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final total = videoUris.length;
    final spriteMap = await cloudMediaCache.spriteIndex(folderUrl);
    if (spriteMap.isEmpty) {
      onProgress?.call(total, total);
      return CloudSpriteAnimationSummary(skipped: total);
    }
    var generated = 0, skipped = 0, failed = 0, done = 0;
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= videoUris.length) return;
        if (isCancelled?.call() ?? false) return;
        final uri = videoUris[i];
        bool? result;
        if (!isCloudUri(uri)) {
          result = null;
        } else {
          final sprite = spriteMap[CloudMediaCache.nameFor(uri)];
          result = sprite == null ? null : await _fetchSprite(uri);
        }
        switch (result) {
          case true:
            generated++;
          case null:
            skipped++;
          case false:
            failed++;
        }
        done++;
        onProgress?.call(done, total);
      }
    }

    final workers = math.min(_spriteAnimationConcurrency, videoUris.length);
    await Future.wait(List.generate(workers, (_) => worker()));
    return CloudSpriteAnimationSummary(generated: generated, skipped: skipped, failed: failed);
  }

  // Fetches one video's sprite sheet on demand (a tile that wants it right now).
  // Returns true on success, false on a real failure, and null when the video
  // has no sprite sheet.
  Future<bool?> animateSpriteThumbnail(String uri) => _fetchSprite(uri);

  Future<bool?> _fetchSprite(String uri) {
    final pending = _spriteFetches[uri];
    if (pending != null) return pending;
    _setSpriteAnimationGenerating(uri, true);
    final future = fetchSpriteSheet(uri);
    _spriteFetches[uri] = future;
    return future.whenComplete(() {
      _setSpriteAnimationGenerating(uri, false);
      if (identical(_spriteFetches[uri], future)) _spriteFetches.remove(uri);
    });
  }

  @override
  Future<void> clearDecoders() => _delegate.clearDecoders();

  @override
  Future<void> clearImageDiskCache() async {
    await _delegate.clearImageDiskCache();
    await cloudDiskCache.clear();
  }

  @override
  Future<void> clearImageMemoryCache() => _delegate.clearImageMemoryCache();

  // The queue key used to collapse every request for a URI onto one entry,
  // which made a large tile share the codec decoded for a small one. The
  // provider key already carries the URI and the extent, so use it as is.
  static Object cloudKey(Object key) => key;

  @override
  bool cancelRegion(Object taskKey) => _delegate.cancelRegion(taskKey);

  @override
  bool cancelThumbnail(Object taskKey) => _delegate.cancelThumbnail(cloudKey(taskKey));

  @override
  bool prioritizeThumbnail(Object taskKey) => _delegate.prioritizeThumbnail(cloudKey(taskKey));

  @override
  Future<T>? resumeLoading<T>(Object taskKey) => _delegate.resumeLoading<T>(cloudKey(taskKey));
}
