import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:purer/model/settings/modules/cloud.dart';
import 'package:purer/model/settings/settings.dart';
import 'package:purer/model/source/cloud/cloud_resource.dart';
import 'package:purer/services/common/cloud_registry.dart';
import 'package:purer/services/log/purer_log.dart';
import 'package:purer/services/media/cloud_client.dart';
import 'package:purer/services/media/webdav_client.dart';
import 'package:purer/utils/cloud_url.dart';
import 'package:flutter/foundation.dart';

// A video frame already stored in the shared cache folder.
//
// The cache mirrors the remote folder structure, e.g. the video
// `/115/f1/vid.mp4` (10 minutes) is stored as
// `<cache folder>/115/f1/00.10.00_vid.mp4.jpg`. The file name carries both the
// video name and its duration, so listing one folder tells which videos are
// done (and how long they are) without requesting any video at all.
class CloudCachedFrame {
  // absolute URL of the stored `.jpg`
  final String url;
  // decoded file name, for logging
  final String name;
  // duration read from the `HH.MM.SS_` prefix of the file name
  final int? durationMillis;

  const new({
    required this.url,
    required this.name,
    this.durationMillis,
  });
}

// A video whose scrape failure is recorded in the mirrored folder, next to the
// frames. The next scrapes skip it instead of reading the video again, until
// the user retries it from the scrape page or a frame appears elsewhere.
//
// A frame always wins over a marker: a stale record never hides a thumbnail.
class CloudFailedVideo {
  // absolute URL of the marker file
  final String url;
  // marker file name
  final String name;
  // `CloudVideoThumbnailFailure.name`, read from the marker file name
  final String? reason;

  const new({
    required this.url,
    required this.name,
    this.reason,
  });
}

// A sprite sheet already stored in the shared cache folder: a single `.jpg`
// holding `cols x rows` frames of the video tiled together, with a `~<cols>x<rows>`
// suffix before the extension (e.g. `00.10.00_vid.mp4~4x4.jpg`). The desktop
// scraper writes these; the app only reads and animates them.
class CloudSprite {
  // absolute URL of the stored `.jpg`
  final String url;
  // decoded file name, for logging
  final String name;
  final int cols;
  final int rows;
  // duration read from the `HH.MM.SS_` prefix of the base name
  final int? durationMillis;

  const new({
    required this.url,
    required this.name,
    required this.cols,
    required this.rows,
    this.durationMillis,
  });
}

// What one listing of a mirrored folder tells: the frames it holds and the
// failures recorded next to them.
class CloudFolderListing {
  final Map<String, CloudCachedFrame> frames;
  final Map<String, CloudFailedVideo> failures;
  final Map<String, CloudSprite> sprites;

  const new({
    this.frames = const {},
    this.failures = const {},
    this.sprites = const {},
  });

  // a listing whose maps are updated in place as frames and markers are
  // written; the const defaults above cannot be mutated
  new mutable()
      : frames = <String, CloudCachedFrame>{},
        failures = <String, CloudFailedVideo>{},
        sprites = <String, CloudSprite>{};

  static const empty = CloudFolderListing();
}

// Optional shared cache, stored in a folder of one of the configured WebDAV
// services.
//
// The chosen folder is the root of a mirror of the remote tree: a source
// folder `/115/f1/` is mirrored to `<cache folder>/115/f1/`, and each video
// `vid.mp4` becomes `[HH.MM.SS_]vid.mp4.jpg`. Listing the mirror folder is a
// single PROPFIND, and it answers which videos are already scraped and how
// long they are, so a later scrape or visit does not request the videos.
class CloudMediaCache {
  static const Duration _listTimeout = Duration(seconds: 20);
  // removing a mirror entry should not keep the caller (a delete action in the
  // browser) waiting for the cache server's own much longer request timeout
  static const Duration _deleteTimeout = Duration(seconds: 20);
  // while the cache server is unreachable, tiles must not each wait for their
  // own timeout: a short back-off turns them into immediate misses
  static const Duration _unavailableBackOff = Duration(seconds: 30);
  // a mirror folder that did not exist is rechecked after this delay, so a
  // folder created by another device becomes visible without an app restart
  static const Duration _missingMirrorRetry = Duration(seconds: 60);
  // bound the memoized mirror listings of a long session
  static const int _maxListings = 500;
  // duration prefix of a cached file name: `00.10.00_` for 10 minutes.
  // exactly two digits per component keeps date-like prefixes
  // (`2023.01.15_...`) from being mistaken for a duration.
  static final RegExp _durationPrefix = RegExp(r'^(\d{2})\.(\d{2})\.(\d{2})_');
  // failure marker: `<video name>.failed` or `<video name>.failed-<reason>`,
  // written next to the frames. Kept out of the frame index (`.jpg` only), so
  // a marker never hides a thumbnail.
  static const String _failureSuffix = '.failed';
  static final RegExp _failureName = RegExp(r'^(.*)\.failed(?:-([A-Za-z]+))?$');
  // sprite sheet marker: `<base>~<cols>x<rows>` before `.jpg`
  static final RegExp _spriteTag = RegExp(r'~(\d{1,2})x(\d{1,2})$');

  final Map<String, CloudFolderListing> _listings = {};
  final Map<String, Future<CloudFolderListing>> _pending = {};
  final Set<String> _ensured = {};
  final Map<String, DateTime> _missingMirrors = {};
  DateTime? _unavailableUntil;

  bool get isReady => settings.cloudThumbnailCacheReady;

  // file name of a resource. Derived from the URL so the writer and the
  // reader (the grid, the scraper) agree without downloading anything.
  static String nameFor(String url) {
    var value = url;
    while (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    final slash = value.lastIndexOf('/');
    final raw = slash < 0 ? value : value.substring(slash + 1);
    return decodeCloudSegment(raw);
  }

  // `HH.MM.SS` (zero padded) used as the cache file name prefix
  static String _durationPrefixOf(int durationMillis) {
    final totalSeconds = (durationMillis / 1000).round();
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}.${minutes.toString().padLeft(2, '0')}.${seconds.toString().padLeft(2, '0')}_';
  }

  // a video name that already starts with `HH.MM.SS_` keeps its own duration:
  // concatenating another one would repeat it
  static bool _hasDurationPrefix(String videoName) => _durationPrefix.hasMatch(videoName);

  static int? _durationOf(String base) {
    final match = _durationPrefix.firstMatch(base);
    if (match == null) return null;
    final hours = int.tryParse(match.group(1)!);
    final minutes = int.tryParse(match.group(2)!);
    final seconds = int.tryParse(match.group(3)!);
    if (hours == null || minutes == null || seconds == null) return null;
    return ((hours * 3600 + minutes * 60 + seconds) * 1000);
  }

  String? _chosenFolder() {
    final folder = settings.cloudThumbnailCacheFolderUrl;
    if (folder == null || folder.isEmpty) return null;
    return folder.endsWith('/') ? folder : '$folder/';
  }

  String? _rootUrl() => _chosenFolder();

  // whether `url` is the cache root or one of its mirrored subfolders. The
  // scraper uses this to avoid walking the mirror it is writing (which would
  // otherwise mirror the cache into itself). Picking the service root as the
  // cache folder does not identify a subtree, so nothing is skipped then.
  bool isCacheFolder(String url) {
    final root = _chosenFolder();
    if (root == null) return false;
    final rootKey = CloudSettings.cloudFolderKey(root);
    final key = CloudSettings.cloudFolderKey(url);
    if (!key.startsWith(rootKey)) return false;
    final server = cloudRegistry.serverForUrl(root);
    if (server != null && CloudSettings.cloudFolderKey(server.url) == rootKey) return false;
    return true;
  }

  WebDavClient? _client() {
    final server = settings.cloudThumbnailCacheServer;
    if (server == null) return null;
    final client = cloudRegistry.clientForServer(server);
    return client is WebDavClient ? client : null;
  }

  // path of a source URL relative to its service root, still percent-encoded.
  // `https://host/dav/115/f1/` on a server rooted at `https://host/dav/` gives
  // `115/f1/`, which is what the cache folder mirrors.
  static String _relativePathOf(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final server = cloudRegistry.serverForUrl(url);
    if (server != null) {
      final basePath = Uri.tryParse(server.url)?.path ?? '';
      if (basePath.isNotEmpty) {
        final base = basePath.endsWith('/') ? basePath : '$basePath/';
        if (path.startsWith(base)) return path.substring(base.length);
      }
    }
    return path.replaceFirst(RegExp(r'^/+'), '');
  }

  // mirror folder URL for a source folder
  String? _dirUrlFor(String sourceFolderUrl) {
    final root = _rootUrl();
    if (root == null) return null;
    final relative = _relativePathOf(sourceFolderUrl);
    if (relative.isEmpty) return root;
    return '$root${relative.endsWith('/') ? relative : '$relative/'}';
  }

  // ---- folder index ----

  // which videos of a source folder already have a frame in the mirror, keyed
  // by file name. One PROPFIND per folder (and per session unless `refresh`),
  // so checking a folder that was scraped before costs a single request.
  Future<Map<String, CloudCachedFrame>> index(String folderUrl, {bool refresh = false}) async {
    return (await listing(folderUrl, refresh: refresh)).frames;
  }

  // The frames and the recorded failures of a source folder, from one
  // PROPFIND. A scrape asks for both at once, so a folder that holds failures
  // still costs a single request.
  Future<CloudFolderListing> listing(String folderUrl, {bool refresh = false}) {
    if (!isReady || folderUrl.isEmpty) return Future.value(CloudFolderListing.empty);
    final key = CloudSettings.cloudFolderKey(folderUrl);
    final cached = _listings[key];
    if (cached != null && !refresh) {
      final missingAt = _missingMirrors[key];
      if (missingAt == null || DateTime.now().difference(missingAt) < _missingMirrorRetry) {
        return Future.value(cached);
      }
    }
    final unavailableUntil = _unavailableUntil;
    if (unavailableUntil != null && DateTime.now().isBefore(unavailableUntil)) {
      return Future.value(cached ?? CloudFolderListing.empty);
    }
    if (!refresh) {
      final pending = _pending[key];
      if (pending != null) return pending;
    }
    final future = _loadListing(folderUrl, key);
    if (!refresh) {
      _pending[key] = future;
      future.whenComplete(() => _pending.remove(key));
    }
    return future;
  }

  Future<CloudFolderListing> _loadListing(String folderUrl, String key) async {
    final client = _client();
    final dir = _dirUrlFor(folderUrl);
    if (client == null || dir == null) return _listings[key] ?? CloudFolderListing.empty;
    try {
      final resources = await client.list(dir).timeout(_listTimeout);
      final listing = CloudFolderListing(
        frames: _indexResources(resources),
        failures: _failureResources(resources),
        sprites: _spriteResources(resources),
      );
      // re-insert so a folder that is listed often is not the first evicted
      _listings.remove(key);
      _listings[key] = listing;
      // a long session over a large library must not keep every mirror listing
      while (_listings.length > _maxListings) {
        _listings.remove(_listings.keys.first);
      }
      _missingMirrors.remove(key);
      _unavailableUntil = null;
      purerLog.info(
        PurerLogCategory.cache,
        '读取缩略图缓存目录 ${PurerLog.redactUrl(dir)} videos=${listing.frames.length} failed=${listing.failures.length}',
      );
      return listing;
    } catch (error) {
      final status = error is CloudException ? error.statusCode : null;
      _noteFailure(error);
      if (status == 404) {
        // the mirror folder has not been created yet: nothing was scraped.
        // Remember when, so it is rechecked after a short delay.
        final empty = CloudFolderListing.mutable();
        _listings.remove(key);
        _listings[key] = empty;
        _missingMirrors[key] = DateTime.now();
        return empty;
      }
      purerLog.warn(PurerLogCategory.cache, '读取缩略图缓存目录失败 ${PurerLog.redactUrl(folderUrl)} error=$error');
      return _listings[key] ?? CloudFolderListing.empty;
    }
  }

  // maps both possible interpretations of a cached file name:
  // - the whole base name is the video name (a video whose own name starts
  //   with `HH.MM.SS_`)
  // - the base name is `<HH.MM.SS>_<video name>` (the usual case)
  // Exact video names win, so a video literally named `00.00.01_a.mp4` is not
  // shadowed by the stripped interpretation of another file.
  static Map<String, CloudCachedFrame> _indexResources(List<CloudResource> resources) {
    final exact = <String, CloudCachedFrame>{};
    final stripped = <String, CloudCachedFrame>{};
    for (final resource in resources) {
      if (resource.isCollection) continue;
      final name = resource.name;
      if (name.length < 5 || !name.toLowerCase().endsWith('.jpg')) continue;
      final base = name.substring(0, name.length - 4);
      if (base.isEmpty) continue;
      // a sprite sheet (with a `~colsxrows` suffix) is not a plain frame: it is
      // indexed separately, so it never shadows the video's real thumbnail
      if (_spriteTag.hasMatch(base)) continue;
      final frame = CloudCachedFrame(url: resource.url, name: name, durationMillis: _durationOf(base));
      exact[base] = frame;
      final match = _durationPrefix.firstMatch(base);
      if (match != null) {
        final videoName = base.substring(match.end);
        if (videoName.isNotEmpty) stripped.putIfAbsent(videoName, () => frame);
      }
    }
    return {...stripped, ...exact};
  }

  // failure markers of a listing, keyed by video name
  static Map<String, CloudFailedVideo> _failureResources(List<CloudResource> resources) {
    final map = <String, CloudFailedVideo>{};
    for (final resource in resources) {
      if (resource.isCollection) continue;
      final match = _failureName.firstMatch(resource.name);
      if (match == null) continue;
      final videoName = match.group(1);
      if (videoName == null || videoName.isEmpty) continue;
      map[videoName] = CloudFailedVideo(
        url: resource.url,
        name: resource.name,
        reason: match.group(2),
      );
    }
    return map;
  }

  // sprite sheets of a listing, keyed by video name. A sprite base name is
  // `<optional duration prefix><video name>~<cols>x<rows>`; both the plain and
  // the stripped interpretation are recorded, like the frame index.
  static Map<String, CloudSprite> _spriteResources(List<CloudResource> resources) {
    final exact = <String, CloudSprite>{};
    final stripped = <String, CloudSprite>{};
    for (final resource in resources) {
      if (resource.isCollection) continue;
      final name = resource.name;
      if (name.length < 6 || !name.toLowerCase().endsWith('.jpg')) continue;
      final base = name.substring(0, name.length - 4);
      final tag = _spriteTag.firstMatch(base);
      if (tag == null) continue;
      final cols = int.tryParse(tag.group(1)!);
      final rows = int.tryParse(tag.group(2)!);
      if (cols == null || rows == null || cols <= 0 || rows <= 0) continue;
      final plain = base.substring(0, tag.start);
      if (plain.isEmpty) continue;
      final sprite = CloudSprite(url: resource.url, name: name, cols: cols, rows: rows, durationMillis: _durationOf(plain));
      exact[plain] = sprite;
      final match = _durationPrefix.firstMatch(plain);
      if (match != null) {
        final videoName = plain.substring(match.end);
        if (videoName.isNotEmpty) stripped.putIfAbsent(videoName, () => sprite);
      }
    }
    return {...stripped, ...exact};
  }

  // ---- frames ----

  // reads a cached frame, or null when the cache is off, unconfigured, or the
  // frame is not there yet. Every failure is a miss, never an error shown to
  // the tile: extraction can always rebuild the frame.
  Future<Uint8List?> get(String uri) async {
    if (!isReady) return null;
    final unavailableUntil = _unavailableUntil;
    if (unavailableUntil != null && DateTime.now().isBefore(unavailableUntil)) return null;
    final client = _client();
    if (client == null) return null;
    final folder = CloudSettings.cloudParentUrl(uri);
    final frames = (await listing(folder)).frames;
    final frame = frames[nameFor(uri)];
    if (frame == null) return null;
    // abort at the socket level on timeout, instead of leaving the transfer
    // running for the client's much longer download timeout
    final abort = CloudAbort();
    final timer = Timer(_listTimeout, abort.abort);
    try {
      final bytes = await client.getBytes(frame.url, abort: abort);
      _unavailableUntil = null;
      if (bytes.isNotEmpty) {
        purerLog.debug(PurerLogCategory.cache, '共用缩略图命中 ${PurerLog.redactUrl(uri)}');
        return bytes;
      }
    } catch (error) {
      _noteFailure(error);
    } finally {
      timer.cancel();
    }
    return null;
  }

  // reads a cached sprite sheet for a video, or null when the cache is off,
  // unconfigured, or no sprite exists. Every failure is a miss, never an error
  // shown to the tile: the regular frame extraction can always rebuild one.
  Future<CloudSprite?> spriteFor(String uri) async {
    if (!isReady) return null;
    final unavailableUntil = _unavailableUntil;
    if (unavailableUntil != null && DateTime.now().isBefore(unavailableUntil)) return null;
    final folder = CloudSettings.cloudParentUrl(uri);
    final sprites = (await listing(folder)).sprites;
    return sprites[nameFor(uri)];
  }

  // sprite sheets of a source folder, keyed by video name; one PROPFIND, so the
  // batch "animate sprite thumbnails" action lists the mirror only once
  Future<Map<String, CloudSprite>> spriteIndex(String folderUrl) async {
    if (!isReady || folderUrl.isEmpty) return const {};
    return (await listing(folderUrl)).sprites;
  }

  // downloads the bytes of a sprite sheet found by `spriteFor`
  Future<Uint8List?> spriteBytes(CloudSprite sprite) async {
    final client = _client();
    if (client == null) return null;
    final abort = CloudAbort();
    final timer = Timer(_listTimeout, abort.abort);
    try {
      final bytes = await client.getBytes(sprite.url, abort: abort);
      _unavailableUntil = null;
      if (bytes.isNotEmpty) return bytes;
    } catch (error) {
      _noteFailure(error);
      purerLog.debug(PurerLogCategory.cache, '读取雪碧图失败 ${PurerLog.redactUrl(sprite.url)} error=$error');
    } finally {
      timer.cancel();
    }
    return null;
  }

  // uploads a freshly extracted frame into its mirrored folder. The duration
  // is part of the file name, so a later listing also restores it.
  Future<bool> put(String uri, Uint8List bytes, {int? durationMillis, String contentType = 'image/jpeg'}) async {
    if (!isReady || bytes.isEmpty) return false;
    final unavailableUntil = _unavailableUntil;
    if (unavailableUntil != null && DateTime.now().isBefore(unavailableUntil)) return false;
    final client = _client();
    final sourceFolder = CloudSettings.cloudParentUrl(uri);
    final dir = _dirUrlFor(sourceFolder);
    if (client == null || dir == null) return false;

    final videoName = nameFor(uri);
    final cacheBase = _cacheBaseName(videoName, durationMillis);
    final fileName = '$cacheBase.jpg';
    // a video name that carries its own duration also supplies it when the
    // caller did not know it
    final effectiveDuration = _durationOf(cacheBase) ?? durationMillis;
    final url = '$dir${Uri.encodeComponent(fileName)}';
    try {
      await _putEnsured(client, url, bytes, contentType: contentType);
      _unavailableUntil = null;
      _rememberUploaded(sourceFolder, videoName, url, fileName, effectiveDuration);
      purerLog.debug(PurerLogCategory.cache, '共用缩略图已上传 ${PurerLog.redactUrl(uri)} bytes=${bytes.length} name=$fileName');
      return true;
    } catch (error) {
      _noteFailure(error);
      purerLog.warn(PurerLogCategory.cache, '共用缩略图上传失败 ${PurerLog.redactUrl(uri)} error=$error');
      return false;
    }
  }

  static String _cacheBaseName(String videoName, int? durationMillis) {
    if (_hasDurationPrefix(videoName)) return videoName;
    if (durationMillis == null || durationMillis <= 0) return videoName;
    return '${_durationPrefixOf(durationMillis)}$videoName';
  }

  // keeps an already loaded index in sync, so tiles opened right after a scrape
  // find the frame without listing the folder again
  void _rememberUploaded(String sourceFolder, String videoName, String url, String fileName, int? durationMillis) {
    final folderKey = CloudSettings.cloudFolderKey(sourceFolder);
    _missingMirrors.remove(folderKey);
    final map = _listings[folderKey]?.frames;
    if (map == null) return;
    final frame = CloudCachedFrame(url: url, name: fileName, durationMillis: durationMillis);
    map[videoName] = frame;
    final match = _durationPrefix.firstMatch(videoName);
    if (match != null) {
      final rest = videoName.substring(match.end);
      if (rest.isNotEmpty) map.putIfAbsent(rest, () => frame);
    }
  }

  void _rememberFailure(String sourceFolder, String videoName, String url, String fileName, String reason) {
    final folderKey = CloudSettings.cloudFolderKey(sourceFolder);
    _missingMirrors.remove(folderKey);
    final map = _listings[folderKey]?.failures;
    if (map == null) return;
    map[videoName] = CloudFailedVideo(url: url, name: fileName, reason: reason);
  }

  void _forgetFailure(String sourceFolder, String videoName) {
    _listings[CloudSettings.cloudFolderKey(sourceFolder)]?.failures.remove(videoName);
  }

  // Drops what the mirror holds for one video: the frame (after a forced
  // rebuild, so the freshly extracted one replaces it instead of being shadowed
  // by the stale remote copy) and its failure marker (after the video itself
  // was deleted).
  Future<void> remove(String uri) async {
    if (!isReady || uri.isEmpty) return;
    final client = _client();
    if (client == null) return;
    final sourceFolder = CloudSettings.cloudParentUrl(uri);
    final videoName = nameFor(uri);
    final listing = await this.listing(sourceFolder, refresh: true);
    final frame = listing.frames[videoName];
    if (frame != null) {
      try {
        await client.delete(frame.url).timeout(_deleteTimeout);
        listing.frames.removeWhere((_, value) => value.url == frame.url);
        purerLog.info(PurerLogCategory.cache, '已删除共用缩略图 ${PurerLog.redactUrl(uri)}');
      } catch (error) {
        purerLog.warn(PurerLogCategory.cache, '删除共用缩略图失败 ${PurerLog.redactUrl(uri)} error=$error');
      }
    }
    final sprite = listing.sprites[videoName];
    if (sprite != null) {
      try {
        await client.delete(sprite.url).timeout(_deleteTimeout);
        listing.sprites.remove(videoName);
        purerLog.info(PurerLogCategory.cache, '已删除共用雪碧图 ${PurerLog.redactUrl(uri)}');
      } catch (error) {
        purerLog.warn(PurerLogCategory.cache, '删除共用雪碧图失败 ${PurerLog.redactUrl(uri)} error=$error');
      }
    }
    final failure = listing.failures[videoName];
    if (failure != null) {
      try {
        await client.delete(failure.url).timeout(_deleteTimeout);
        listing.failures.remove(videoName);
        purerLog.info(PurerLogCategory.scrape, '已删除刮削失败记录 ${PurerLog.redactUrl(uri)}');
      } catch (error) {
        purerLog.warn(PurerLogCategory.scrape, '删除刮削失败记录失败 ${PurerLog.redactUrl(uri)} error=$error');
      }
    }
  }

  // Drops the frames, sprites and failure markers of several videos of one
  // source folder, listing the mirror once (a per-video call would cost one
  // PROPFIND each, which makes bulk actions crawl).
  Future<void> removeMany(String folderUrl, Iterable<String> videoNames) async {
    if (!isReady || folderUrl.isEmpty) return;
    final names = videoNames.toSet();
    if (names.isEmpty) return;
    final client = _client();
    if (client == null) return;
    final listing = await this.listing(folderUrl, refresh: true);
    var removed = 0;
    for (final name in names) {
      final frame = listing.frames[name];
      if (frame != null) {
        try {
          await client.delete(frame.url).timeout(_deleteTimeout);
          listing.frames.removeWhere((_, value) => value.url == frame.url);
          removed++;
        } catch (_) {
          // a miss is fine: this is a best effort cleanup
        }
      }
      final sprite = listing.sprites[name];
      if (sprite != null) {
        try {
          await client.delete(sprite.url).timeout(_deleteTimeout);
          listing.sprites.remove(name);
          removed++;
        } catch (_) {
          // best effort
        }
      }
      final failure = listing.failures[name];
      if (failure != null) {
        try {
          await client.delete(failure.url).timeout(_deleteTimeout);
          listing.failures.remove(name);
          removed++;
        } catch (_) {
          // best effort
        }
      }
    }
    if (removed > 0) {
      purerLog.info(PurerLogCategory.cache, '已删除共用缩略图 ${PurerLog.redactUrl(folderUrl)} count=$removed');
    }
  }

  // ---- moves ----

  // Moves the mirrored frame, sprite sheet and failure marker of videos that
  // were renamed or moved on the source, so the cache never keeps pointing at
  // the old path. `moves` maps the old URL of each video to its URL after the
  // move. One mirror listing per source folder; a cache miss is not an error.
  Future<void> moveEntries(Map<String, String> moves) async {
    if (!isReady || moves.isEmpty) return;
    final client = _client();
    if (client == null) return;
    final byFolder = <String, Map<String, String>>{};
    for (final item in moves.entries) {
      if (item.key.isEmpty || item.value.isEmpty || item.key == item.value) continue;
      byFolder.putIfAbsent(CloudSettings.cloudParentUrl(item.key), () => {})[item.key] = item.value;
    }
    if (byFolder.isEmpty) return;
    final touched = <String>{};
    var moved = 0;
    for (final item in byFolder.entries) {
      final sourceFolder = item.key;
      final listing = await this.listing(sourceFolder, refresh: true);
      for (final move in item.value.entries) {
        final oldName = nameFor(move.key);
        final newName = nameFor(move.value);
        if (oldName.isEmpty || newName.isEmpty || oldName == newName) continue;
        final targetFolder = CloudSettings.cloudParentUrl(move.value);
        final targetDir = _dirUrlFor(targetFolder);
        if (targetDir == null) continue;

        final frame = listing.frames[oldName];
        if (frame != null) {
          final base = _withoutJpg(frame.name);
          final renamed = _renamedBase(base, oldName, newName);
          if (await _moveCacheFile(client, frame.url, targetDir, '$renamed.jpg')) moved++;
        }
        final sprite = listing.sprites[oldName];
        if (sprite != null) {
          final base = _withoutJpg(sprite.name);
          final tag = _spriteTag.firstMatch(base);
          if (tag != null) {
            final renamed = _renamedBase(base.substring(0, tag.start), oldName, newName);
            if (await _moveCacheFile(client, sprite.url, targetDir, '$renamed${base.substring(tag.start)}.jpg')) moved++;
          }
        }
        final failure = listing.failures[oldName];
        if (failure != null) {
          final suffix = failure.name.startsWith(oldName) ? failure.name.substring(oldName.length) : _failureSuffix;
          if (await _moveCacheFile(client, failure.url, targetDir, '$newName$suffix')) moved++;
        }
        touched.add(sourceFolder);
        touched.add(targetFolder);
      }
    }
    _invalidateListings(touched);
    if (moved > 0) {
      purerLog.info(PurerLogCategory.cache, '已移动共用缩略图 count=$moved');
    }
  }

  // Moves (renames) the whole mirrored subtree of a folder, so a folder move
  // does not leave its frames and sprites at the old path. A mirror that does
  // not exist is not an error.
  Future<void> moveFolder(String fromFolderUrl, String toFolderUrl) async {
    if (!isReady || fromFolderUrl.isEmpty || toFolderUrl.isEmpty) return;
    final client = _client();
    final fromDir = _dirUrlFor(fromFolderUrl);
    final toDir = _dirUrlFor(toFolderUrl);
    if (client == null || fromDir == null || toDir == null || fromDir == toDir) return;
    try {
      final parent = _dirUrlFor(CloudSettings.cloudParentUrl(toFolderUrl));
      if (parent != null) await _ensureDirectory(client, parent);
      await client.move(fromDir, toDir, overwrite: true);
      purerLog.info(PurerLogCategory.cache, '已移动共用缩略图文件夹 ${PurerLog.redactUrl(fromDir)} -> ${PurerLog.redactUrl(toDir)}');
    } on CloudException catch (error) {
      // the folder was never scraped: there is nothing to move
      if (error.statusCode != 404) {
        purerLog.warn(PurerLogCategory.cache, '移动共用缩略图文件夹失败 ${PurerLog.redactUrl(fromDir)} error=$error');
      }
    } catch (error) {
      purerLog.warn(PurerLogCategory.cache, '移动共用缩略图文件夹失败 ${PurerLog.redactUrl(fromDir)} error=$error');
    }
    _invalidateSubtree(fromFolderUrl);
    _invalidateSubtree(toFolderUrl);
    _ensured.removeWhere((url) => url.startsWith(fromDir) || url.startsWith(toDir));
  }

  static String _withoutJpg(String name) {
    return name.toLowerCase().endsWith('.jpg') ? name.substring(0, name.length - 4) : name;
  }

  // keeps the duration prefix of a cache file (`HH.MM.SS_`) and replaces the
  // video name it was built from
  static String _renamedBase(String base, String oldName, String newName) {
    if (base == oldName) return newName;
    if (base.endsWith(oldName)) return '${base.substring(0, base.length - oldName.length)}$newName';
    return newName;
  }

  Future<bool> _moveCacheFile(WebDavClient client, String fromUrl, String targetDir, String fileName) async {
    final targetUrl = '$targetDir${Uri.encodeComponent(fileName)}';
    if (targetUrl == fromUrl) return false;
    try {
      await _ensureFolder(client, targetUrl);
      // the cache is derived data: replacing a stale file with the moved one is
      // exactly what a rename/move should do
      await client.move(fromUrl, targetUrl, overwrite: true);
      purerLog.debug(PurerLogCategory.cache, '缓存已移动 ${PurerLog.redactUrl(fromUrl)} -> ${PurerLog.redactUrl(targetUrl)}');
      return true;
    } on CloudException catch (error) {
      // no cached file for this video: nothing to move
      if (error.statusCode != 404) {
        purerLog.warn(PurerLogCategory.cache, '移动缓存文件失败 ${PurerLog.redactUrl(fromUrl)} error=$error');
      }
      return false;
    } catch (error) {
      purerLog.warn(PurerLogCategory.cache, '移动缓存文件失败 ${PurerLog.redactUrl(fromUrl)} error=$error');
      return false;
    }
  }

  void _invalidateListings(Iterable<String> folderUrls) {
    for (final url in folderUrls) {
      final key = CloudSettings.cloudFolderKey(url);
      _listings.remove(key);
      _pending.remove(key);
      _missingMirrors.remove(key);
    }
  }

  // drops every memoized level of a folder subtree (a folder move changes the
  // path of everything below it)
  void _invalidateSubtree(String folderUrl) {
    final key = CloudSettings.cloudFolderKey(folderUrl);
    _listings.removeWhere((k, _) => k.startsWith(key));
    _pending.removeWhere((k, _) => k.startsWith(key));
    _missingMirrors.removeWhere((k, _) => k.startsWith(key));
  }

  // Removes the mirrored subtree of a source folder when that folder (and
  // everything in it) is deleted, so the cache does not keep frames and
  // failure markers of files that no longer exist. The mirror folder follows
  // the source path, so it can be deleted directly without listing it first.
  Future<void> removeFolder(String folderUrl) async {
    if (!isReady || folderUrl.isEmpty) return;
    final client = _client();
    final dir = _dirUrlFor(folderUrl);
    if (client == null || dir == null) return;
    try {
      await client.delete(dir).timeout(_deleteTimeout);
      // forget every memoized listing and folder of that subtree
      final key = CloudSettings.cloudFolderKey(dir);
      _listings.removeWhere((k, _) => k.startsWith(key));
      _pending.removeWhere((k, _) => k.startsWith(key));
      _missingMirrors.removeWhere((k, _) => k.startsWith(key));
      _ensured.removeWhere((url) => url.startsWith(dir));
      purerLog.info(PurerLogCategory.cache, '已删除共用缩略图文件夹 ${PurerLog.redactUrl(dir)}');
    } catch (error) {
      purerLog.warn(PurerLogCategory.cache, '删除共用缩略图文件夹失败 ${PurerLog.redactUrl(dir)} error=$error');
    }
  }

  // ---- recorded failures ----

  // Records that a video failed in a way another attempt would meet again, as
  // a marker next to the frames: `<video name>.failed-<reason>`. A later run
  // lists it together with the frames, so the video is skipped without being
  // read again. Writing again replaces the previous reason.
  Future<bool> recordFailure(String uri, {required String reason, String? detail}) async {
    if (!isReady || uri.isEmpty) return false;
    final unavailableUntil = _unavailableUntil;
    if (unavailableUntil != null && DateTime.now().isBefore(unavailableUntil)) return false;
    final client = _client();
    final sourceFolder = CloudSettings.cloudParentUrl(uri);
    final dir = _dirUrlFor(sourceFolder);
    if (client == null || dir == null) return false;

    final videoName = nameFor(uri);
    final fileName = '$videoName$_failureSuffix-${reason.toLowerCase()}';
    final url = '$dir${Uri.encodeComponent(fileName)}';
    final previous = _listings[CloudSettings.cloudFolderKey(sourceFolder)]?.failures[videoName];
    final content = '${DateTime.now().toUtc().toIso8601String()}\n$reason\n${detail ?? ''}';
    try {
      await _putEnsured(client, url, Uint8List.fromList(utf8.encode(content)), contentType: 'text/plain; charset=utf-8');
      // a marker with another reason would otherwise stay next to the new one
      if (previous != null && previous.url != url) {
        try {
          await client.delete(previous.url);
        } catch (error) {
          purerLog.debug(PurerLogCategory.cache, '删除旧失败标记失败 ${PurerLog.redactUrl(previous.url)} error=$error');
        }
      }
      _unavailableUntil = null;
      _rememberFailure(sourceFolder, videoName, url, fileName, reason);
      purerLog.info(PurerLogCategory.scrape, '记录刮削失败 ${PurerLog.redactUrl(uri)} reason=$reason');
      return true;
    } catch (error) {
      _noteFailure(error);
      purerLog.warn(PurerLogCategory.scrape, '记录刮削失败失败 ${PurerLog.redactUrl(uri)} error=$error');
      return false;
    }
  }

  // Forgets the recorded failure of a video: used when an attempt finally
  // succeeds, and before the user's own per-video retry. The marker is looked
  // up in the folder listing, so a video without one costs no request.
  Future<void> clearFailure(String uri) async {
    if (!isReady || uri.isEmpty) return;
    final client = _client();
    if (client == null) return;
    final sourceFolder = CloudSettings.cloudParentUrl(uri);
    final videoName = nameFor(uri);
    final current = await listing(sourceFolder);
    final known = current.failures[videoName];
    _forgetFailure(sourceFolder, videoName);
    if (known == null) return;
    try {
      await client.delete(known.url);
      purerLog.info(PurerLogCategory.scrape, '清除刮削失败记录 ${PurerLog.redactUrl(uri)}');
    } catch (error) {
      _noteFailure(error);
      purerLog.warn(PurerLogCategory.scrape, '清除刮削失败记录失败 ${PurerLog.redactUrl(uri)} error=$error');
    }
  }

  // ---- setup ----

  // uploads into the mirror, creating the folders leading to it, and retries
  // once when the destination or a parent was removed on the server
  Future<void> _putEnsured(WebDavClient client, String url, Uint8List bytes, {required String contentType}) async {
    await _ensureFolder(client, url);
    try {
      await client.putBytes(url, bytes, contentType: contentType);
    } on CloudException catch (error) {
      // the destination or one of its parents may have been removed on the
      // server: forget every memoized level of this path, create them again,
      // then retry the upload
      final status = error.statusCode;
      if (status != 404 && status != 409) rethrow;
      _ensured.removeWhere(url.startsWith);
      await _ensureFolder(client, url);
      await client.putBytes(url, bytes, contentType: contentType);
    }
  }

  // creates the folders leading to a file
  Future<void> _ensureFolder(WebDavClient client, String fileUrl) {
    return _ensureDirectory(client, fileUrl.substring(0, fileUrl.lastIndexOf('/') + 1));
  }

  // creates a folder and its parents, one level at a time: WebDAV answers 409
  // when the parent of a MKCOL target does not exist (MKCOL does not create
  // intermediate collections)
  Future<void> _ensureDirectory(WebDavClient client, String folder) async {
    if (_ensured.contains(folder)) return;
    final root = _rootUrl();
    if (root == null) return;
    // recreate the chosen cache folder if it was removed on the server, but
    // never try to create the service root itself
    if (!_ensured.contains(root)) {
      final server = cloudRegistry.serverForUrl(root);
      final isServiceRoot = server != null && CloudSettings.cloudFolderKey(server.url) == CloudSettings.cloudFolderKey(root);
      if (!isServiceRoot) {
        await client.makeDirectory(root);
      }
      _ensured.add(root);
    }
    if (folder.startsWith(root) && folder.length > root.length) {
      var base = root;
      for (final segment in folder.substring(root.length).split('/').where((s) => s.isNotEmpty)) {
        base = '$base$segment/';
        if (_ensured.contains(base)) continue;
        await client.makeDirectory(base);
        _ensured.add(base);
      }
    } else {
      await client.makeDirectory(folder);
    }
    _ensured.add(folder);
  }

  void _noteFailure(Object error) {
    final status = error is CloudException ? error.statusCode : null;
    if (status == null || status == 408 || status == 429 || (status >= 500 && status <= 504)) {
      _unavailableUntil = DateTime.now().add(_unavailableBackOff);
    }
  }

  // forgets memorized indexes and setup after a server/folder change
  void reset() {
    _listings.clear();
    _pending.clear();
    _ensured.clear();
    _missingMirrors.clear();
    _unavailableUntil = null;
  }
}

final cloudMediaCache = CloudMediaCache();
