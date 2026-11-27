import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:purer/model/settings/settings.dart';
import 'package:purer/services/common/services.dart';
import 'package:flutter/foundation.dart';

// simple LRU disk cache for downloaded cloud payloads (WebDAV / SMB),
// keyed by URL via a stable FNV-1a hash
class CloudDiskCache {
  // the budget is a user setting; it is read on every check so a change (and a
  // trim) applies at once. A budget of 0 means unlimited: nothing is evicted
  // until the user changes the setting or clears the cache.
  bool get _unlimited => settings.cloudDiskCacheSizeMb <= 0;
  int get _maxBytes => _unlimited ? 0 : settings.cloudDiskCacheSizeMb << 20;
  // trim below the limit so the directory is not rescanned on every write
  int get _evictTargetBytes => (_maxBytes * 0.8).round();
  bool get _overBudget => !_unlimited && (_totalBytes ?? 0) > _maxBytes;
  // 64 bit FNV-1a: with a 32 bit key a library of a few thousand files has a
  // measurable chance of two URLs colliding, and a collision serves one file's
  // bytes for another (which then never decodes)
  static const int _fnvOffset = 0xcbf29ce484222325;
  static const int _fnvPrime = 0x100000001b3;

  Directory? _dir;
  // rough total of the cached files, so a write does not have to list and stat
  // the whole directory (which used to happen once per downloaded image)
  int? _totalBytes;
  // the scan in progress, shared by every caller that needs the total
  Future<void>? _scanFuture;

  Future<Directory> _cacheDir() async {
    final existing = _dir;
    if (existing != null) return existing;
    final root = await storageService.getExternalCacheDirectory();
    final dir = Directory('$root/cloud');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  static String _key(String url) {
    var hash = _fnvOffset;
    for (final codeUnit in url.codeUnits) {
      hash ^= codeUnit;
      // multiplication wraps at 64 bits, which is what FNV wants
      hash *= _fnvPrime;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  Future<File> _fileFor(String url) async {
    final dir = await _cacheDir();
    return File('${dir.path}/${_key(url)}');
  }

  // total size on disk, for the settings page. Scans the directory once when
  // the running total is not known yet.
  Future<int> usageBytes() async {
    final known = _totalBytes;
    if (known != null) return known;
    await _ensureTotal();
    return _totalBytes ?? 0;
  }

  // Recomputes the total in the background. `put` used to await this scan
  // before the first thumbnail could decode, which made the first image of a
  // session wait for a full directory walk.
  Future<void> _ensureTotal() {
    if (_totalBytes != null) return Future.value();
    final pending = _scanFuture;
    if (pending != null) return pending;
    final future = _refreshTotal();
    _scanFuture = future;
    return future;
  }

  Future<void> _refreshTotal() async {
    try {
      final total = await _scanTotal(await _cacheDir());
      _totalBytes = total;
      if (_overBudget) await _evict();
    } catch (error) {
      debugPrint('cloud cache scan failed error=$error');
    } finally {
      _scanFuture = null;
    }
  }

  Future<int> _scanTotal(Directory dir) async {
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      try {
        total += (await entity.stat()).size;
      } catch (_) {
        // a file removed while scanning
      }
    }
    return total;
  }

  // cheap existence check: a tile only needs to know whether an entry is there
  // (e.g. a sprite animation), not its bytes
  Future<bool> has(String url) async {
    try {
      final file = await _fileFor(url);
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List?> get(String url) async {
    try {
      final file = await _fileFor(url);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      // touch for LRU, but not on every read: a stat is much cheaper than a
      // metadata write, and an hour of resolution is plenty for eviction order
      try {
        final modified = (await file.stat()).modified;
        if (DateTime.now().difference(modified) > const Duration(hours: 1)) {
          await file.setLastModified(DateTime.now());
        }
      } catch (_) {
        // best effort
      }
      return bytes;
    } catch (error) {
      debugPrint('cloud cache read failed for $url error=$error');
      return null;
    }
  }

  Future<void> put(String url, Uint8List bytes) async {
    try {
      final file = await _fileFor(url);
      final needsScan = _totalBytes == null;
      final stat = await file.stat();
      final previous = stat.type == FileSystemEntityType.notFound ? 0 : stat.size;
      // this is a cache: losing the last writes on a crash only costs a
      // re-download, while flushing would force an fsync for every tile
      await file.writeAsBytes(bytes, flush: false);
      // account incrementally first, then correct the total in the background
      // if the real size of the directory is still unknown
      _totalBytes = (_totalBytes ?? 0) - previous + bytes.length;
      if (_overBudget) {
        await _evict();
      } else if (needsScan) {
        unawaited(_ensureTotal());
      }
    } catch (error) {
      debugPrint('cloud cache write failed for $url error=$error');
    }
  }

  Future<void> remove(String url) async {
    try {
      final file = await _fileFor(url);
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return;
      await file.delete();
      final total = _totalBytes;
      if (total != null) {
        _totalBytes = math.max(0, total - stat.size);
      }
    } catch (error) {
      debugPrint('cloud cache remove failed for $url error=$error');
    }
  }

  Future<void> _evict() async {
    // no budget: the scan is still useful for `usageBytes`, but nothing is
    // removed
    if (_unlimited) return;
    try {
      final dir = await _cacheDir();
      final entries = <(File, FileStat)>[];
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          entries.add((entity, stat));
          total += stat.size;
        } catch (_) {
          // removed while scanning
        }
      }
      _totalBytes = total;
      if (total <= _maxBytes) return;
      entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (file, stat) in entries) {
        if (total <= _evictTargetBytes) break;
        try {
          await file.delete();
          total -= stat.size;
        } catch (_) {
          // already gone
        }
      }
      _totalBytes = total;
    } catch (error) {
      debugPrint('cloud cache eviction failed error=$error');
    }
  }

  // applies a lowered budget right away (from the settings page)
  Future<void> trim() async {
    if (_unlimited) return;
    await _ensureTotal();
    if (_overBudget) await _evict();
  }

  Future<void> clear() async {
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _dir = null;
      _totalBytes = 0;
    } catch (error) {
      debugPrint('cloud cache clear failed error=$error');
    }
  }
}

final cloudDiskCache = CloudDiskCache();
