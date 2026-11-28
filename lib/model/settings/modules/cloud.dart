import 'dart:async';
import 'dart:math' as math;

import 'package:purer/model/source/cloud/cloud_server.dart';
import 'package:purer_model/purer_model.dart';

// per folder viewing progress. A folder holding mostly images tracks how many
// of its thumbnails have been loaded, a folder holding mostly subfolders tracks
// how many of those have been opened. Only direct children are considered,
// one level deep, so the numbers stay cheap to maintain.
class CloudFolderStats {
  int totalImages = 0;
  int totalFolders = 0;
  int visitedFolders = 0;
  // the folder was seen in full at some point. Kept separately from the hash
  // set, which is bounded (and cleared for the oldest folders when the total
  // budget is exceeded) and therefore cannot prove completion on its own.
  bool complete = false;
  // 32 bit hashes of the image URLs whose thumbnails have been loaded
  final Set<int> loaded = {};
}

mixin CloudSettings on SettingsAccess {
  static const int _maxFolderStats = 2000;
  // a folder with more distinct images than this is rare; the old 6000 cap was
  // common enough that such folders could never be reported as complete
  static const int _maxLoadedPerFolder = 20000;
  // a hard bound on the total progress data: the whole map is stored as one
  // string list in SharedPreferences, so it must not grow with the library
  static const int _maxTotalLoadedHashes = 200000;

  // auto browse limits, shared by the getters, the browsers' option sheets and
  // the custom value dialogs, so an accepted input never reads back as another
  // value
  static const double autoScrollSpeedMin = 0.05;
  static const double autoScrollSpeedMax = 300.0;
  // column bounds of the grid and the mosaic, shared by the option sheet, its
  // custom value dialog and the browser's pinch zoom, so a gesture can never
  // land outside what the steppers accept
  static const double minCloudColumns = 1;
  static const double maxCloudColumns = 16;
  static const double viewerPageFlipIntervalMin = 0.2;
  static const double viewerPageFlipIntervalMax = 600.0;
  static const double mosaicPageFlipIntervalMin = 0.5;
  static const double mosaicPageFlipIntervalMax = 300.0;
  static const double pageFlipDistanceMin = 0.1;
  static const double pageFlipDistanceMax = 10.0;
  static const int magnifierDelayMin = 50;
  static const int magnifierDelayMax = 5000;
  static const double magnifierScaleMin = 1.2;
  static const double magnifierScaleMax = 20.0;

  Map<String, CloudFolderStats>? _folderStatsCache;
  Timer? _folderStatsFlushTimer;
  bool _folderStatsDirty = false;
  // serialized rows kept per folder, so a flush only rebuilds the folders that
  // changed instead of re-encoding every hash on every write
  final Map<String, String> _folderStatsRows = {};
  final Set<String> _folderStatsDirtyKeys = {};
  int _loadedHashes = 0;

  // per-image dimensions and video positions are updated for every thumbnail
  // decoded and every few seconds of playback: writing the whole stored list
  // each time serialized thousands of rows on the UI isolate. They are kept in
  // memory and flushed on a timer instead (silently, without notifying every
  // settings listener).
  Timer? _imageDimensionsFlushTimer;
  bool _imageDimensionsDirty = false;
  Timer? _videoPositionsFlushTimer;
  bool _videoPositionsDirty = false;

  // parsed views of the stored lists: each getter used to re-parse the whole
  // list on every call, which happens per tile (video duration/progress) and
  // per layout lookup, i.e. many times per frame
  Map<String, String>? _folderLayoutsCache;
  Set<String>? _visitedLookup;
  Map<String, (int, int)>? _videoPositionsCache;
  Map<String, (int, int)>? _imageDimensionsCache;
  Map<String, double>? _scrollPositionsCache;
  Timer? _scrollPositionsFlushTimer;
  bool _scrollPositionsDirty = false;

  List<CloudServer>? _cloudServersCache;

  List<CloudServer> get cloudServers {
    final cached = _cloudServersCache;
    if (cached != null) return cached;
    final stored = getStringList(SettingKeys.cloudServersKey);
    if (stored != null) return _cloudServersCache = stored.map(CloudServer.fromJsonString).nonNulls.toList();
    // migrate configurations saved before the WebDAV storage change
    final legacy = getStringList(SettingKeys.legacyCloudServersKey);
    if (legacy != null && legacy.isNotEmpty) {
      final migrated = legacy.map(CloudServer.fromJsonString).nonNulls.toList();
      set(SettingKeys.cloudServersKey, migrated.map((server) => server.toJsonString()).toList());
      return _cloudServersCache = migrated;
    }
    return _cloudServersCache = const [];
  }

  set cloudServers(List<CloudServer> newValue) {
    _cloudServersCache = newValue;
    set(SettingKeys.cloudServersKey, newValue.map((server) => server.toJsonString()).toList());
  }

  void addCloudServer(CloudServer server) => cloudServers = [...cloudServers, server];

  void updateCloudServer(CloudServer server) => cloudServers = [for (final v in cloudServers) v.id == server.id ? server : v];

  void removeCloudServer(String id) => cloudServers = cloudServers.where((v) => v.id != id).toList();

  // fractional so pinch-to-zoom can resize continuously
  double get cloudColumns => (getDouble(SettingKeys.cloudColumnsKey) ?? getInt(SettingKeys.cloudColumnsKey)?.toDouble() ?? 3).clamp(minCloudColumns, maxCloudColumns);

  set cloudColumns(double newValue) => set(SettingKeys.cloudColumnsKey, newValue.clamp(minCloudColumns, maxCloudColumns));

  // one of `grid`, `list`, `mosaic`; used when a folder has no saved layout
  // (or when per-folder layouts are disabled)

  // default layout for folders containing images (and mixed content)
  String get cloudImageLayout => getString(SettingKeys.cloudImageLayoutKey) ?? 'mosaic';

  set cloudImageLayout(String newValue) => set(SettingKeys.cloudImageLayoutKey, newValue);

  // default layout for folders that only contain videos
  String get cloudVideoLayout => getString(SettingKeys.cloudVideoLayoutKey) ?? 'list';

  set cloudVideoLayout(String newValue) => set(SettingKeys.cloudVideoLayoutKey, newValue);

  // whether the layout chosen in a folder is remembered for that folder
  bool get cloudLayoutPerFolder => getBool(SettingKeys.cloudLayoutPerFolderKey) ?? false;

  set cloudLayoutPerFolder(bool newValue) => set(SettingKeys.cloudLayoutPerFolderKey, newValue);

  Map<String, String> get _cloudFolderLayouts {
    final cached = _folderLayoutsCache;
    if (cached != null) return cached;
    final stored = getStringList(SettingKeys.cloudFolderLayoutsKey) ?? const [];
    final map = <String, String>{};
    for (final entry in stored) {
      final index = entry.lastIndexOf('\t');
      if (index <= 0) continue;
      map[entry.substring(0, index)] = entry.substring(index + 1);
    }
    return _folderLayoutsCache = map;
  }

  void _setCloudFolderLayouts(Map<String, String> map) {
    _folderLayoutsCache = map;
    set(SettingKeys.cloudFolderLayoutsKey, [for (final e in map.entries) '${e.key}\t${e.value}']);
  }

  // effective layout for a folder
  String cloudLayoutFor(String url, {required bool video}) {
    if (cloudLayoutPerFolder) {
      final saved = _cloudFolderLayouts[url];
      if (saved != null) return saved;
    }
    return video ? cloudVideoLayout : cloudImageLayout;
  }

  // records the layout picked by the user: per folder when that is enabled,
  // otherwise as the default for the current media kind
  void setCloudLayoutFor(String url, String layout, {required bool video}) {
    if (cloudLayoutPerFolder && url.isNotEmpty) {
      _setCloudFolderLayouts({..._cloudFolderLayouts, url: layout});
    } else if (video) {
      cloudVideoLayout = layout;
    } else {
      cloudImageLayout = layout;
    }
  }

  // one of `all`, `image`, `video`
  String get cloudMediaFilter => getString(SettingKeys.cloudMediaFilterKey) ?? 'all';

  set cloudMediaFilter(String newValue) => set(SettingKeys.cloudMediaFilterKey, newValue);

  bool get cloudShowNames => getBool(SettingKeys.cloudShowNamesKey) ?? false;

  set cloudShowNames(bool newValue) => set(SettingKeys.cloudShowNamesKey, newValue);

  bool get cloudShowSizes => getBool(SettingKeys.cloudShowSizesKey) ?? false;

  set cloudShowSizes(bool newValue) => set(SettingKeys.cloudShowSizesKey, newValue);

  bool get cloudShowDimensions => getBool(SettingKeys.cloudShowDimensionsKey) ?? false;

  set cloudShowDimensions(bool newValue) => set(SettingKeys.cloudShowDimensionsKey, newValue);

  // show the thumbnail strip in the image viewer
  bool get cloudViewerThumbnails => getBool(SettingKeys.cloudViewerThumbnailsKey) ?? true;

  set cloudViewerThumbnails(bool newValue) => set(SettingKeys.cloudViewerThumbnailsKey, newValue);

  // position of thumbnail strip in viewer: 'bottom', 'left', 'right'
  String get cloudViewerThumbnailsPosition => getString(SettingKeys.cloudViewerThumbnailsPositionKey) ?? 'bottom';

  set cloudViewerThumbnailsPosition(String newValue) => set(SettingKeys.cloudViewerThumbnailsPositionKey, newValue);

  // show the scrubber progress bar in the image viewer
  bool get cloudViewerProgressBar => getBool(SettingKeys.cloudViewerProgressBarKey) ?? true;

  set cloudViewerProgressBar(bool newValue) => set(SettingKeys.cloudViewerProgressBarKey, newValue);

  // position of scrubber progress bar in viewer: 'bottom', 'left', 'right'
  String get cloudViewerProgressBarPosition => getString(SettingKeys.cloudViewerProgressBarPositionKey) ?? 'bottom';

  set cloudViewerProgressBarPosition(String newValue) => set(SettingKeys.cloudViewerProgressBarPositionKey, newValue);

  // layout mode in image viewer: 'paged' (page-by-page) or 'continuous' (seamless horizontal strip)
  String get cloudViewerLayoutMode => getString(SettingKeys.cloudViewerLayoutModeKey) ?? 'paged';

  set cloudViewerLayoutMode(String newValue) => set(SettingKeys.cloudViewerLayoutModeKey, newValue);

  // auto scroll speed factor in viewer (default 3.0, allows custom values)
  double get cloudViewerAutoScrollSpeed {
    final val = getDouble(SettingKeys.cloudViewerAutoScrollSpeedKey) ?? 7.0;
    if (val > autoScrollSpeedMin && val <= autoScrollSpeedMax) return val;
    return 7.0;
  }

  set cloudViewerAutoScrollSpeed(double newValue) => set(SettingKeys.cloudViewerAutoScrollSpeedKey, newValue);

  // auto page flip interval in seconds (default 1.2, allows custom values).
  // The bound is inclusive: a value the stepper/dialog accepts must read back
  // unchanged, otherwise picking the minimum silently falls back to the default.
  double get cloudViewerAutoPageFlipInterval {
    final val = getDouble(SettingKeys.cloudViewerAutoPageFlipIntervalKey) ?? 1.2;
    if (val >= viewerPageFlipIntervalMin && val <= viewerPageFlipIntervalMax) return val;
    return 1.2;
  }

  set cloudViewerAutoPageFlipInterval(double newValue) => set(SettingKeys.cloudViewerAutoPageFlipIntervalKey, newValue.clamp(viewerPageFlipIntervalMin, viewerPageFlipIntervalMax));

  // auto page flip distance as a fraction of screen width (default 0.9 = 90%)
  double get cloudViewerAutoPageFlipDistance {
    final val = getDouble(SettingKeys.cloudViewerAutoPageFlipDistanceKey) ?? 0.9;
    if (val >= pageFlipDistanceMin && val <= pageFlipDistanceMax) return val;
    return 0.9;
  }

  set cloudViewerAutoPageFlipDistance(double newValue) => set(SettingKeys.cloudViewerAutoPageFlipDistanceKey, newValue.clamp(pageFlipDistanceMin, pageFlipDistanceMax));

  // viewer scroll direction: 'horizontal' (default) or 'vertical'
  String get cloudViewerScrollDirection => getString(SettingKeys.cloudViewerScrollDirectionKey) ?? 'horizontal';

  set cloudViewerScrollDirection(String newValue) => set(SettingKeys.cloudViewerScrollDirectionKey, newValue);

  // viewer magnifier options
  bool get cloudViewerMagnifierEnabled => getBool(SettingKeys.cloudViewerMagnifierEnabledKey) ?? true;

  set cloudViewerMagnifierEnabled(bool newValue) => set(SettingKeys.cloudViewerMagnifierEnabledKey, newValue);

  int get cloudViewerMagnifierDelay {
    final val = getInt(SettingKeys.cloudViewerMagnifierDelayKey) ?? 200;
    if (val >= magnifierDelayMin && val <= magnifierDelayMax) return val;
    return 200;
  }

  set cloudViewerMagnifierDelay(int newValue) => set(SettingKeys.cloudViewerMagnifierDelayKey, newValue.clamp(magnifierDelayMin, magnifierDelayMax));

  double get cloudViewerMagnifierScale {
    final val = getDouble(SettingKeys.cloudViewerMagnifierScaleKey) ?? 2.5;
    if (val >= magnifierScaleMin && val <= magnifierScaleMax) return val;
    return 2.5;
  }

  set cloudViewerMagnifierScale(double newValue) => set(SettingKeys.cloudViewerMagnifierScaleKey, newValue.clamp(magnifierScaleMin, magnifierScaleMax));

  // mosaic scroll direction: 'vertical' (default) or 'horizontal'
  String get cloudMosaicScrollDirection => getString(SettingKeys.cloudMosaicScrollDirectionKey) ?? 'vertical';

  set cloudMosaicScrollDirection(String newValue) => set(SettingKeys.cloudMosaicScrollDirectionKey, newValue);

  // mosaic auto-scroll speed factor (default 7.0)
  double get cloudMosaicAutoScrollSpeed {
    final val = getDouble(SettingKeys.cloudMosaicAutoScrollSpeedKey) ?? 7.0;
    if (val > autoScrollSpeedMin && val <= autoScrollSpeedMax) return val;
    return 7.0;
  }

  set cloudMosaicAutoScrollSpeed(double newValue) => set(SettingKeys.cloudMosaicAutoScrollSpeedKey, newValue);

  // mosaic auto page flip interval in seconds (default 1.2)
  double get cloudMosaicAutoPageFlipInterval {
    final val = getDouble(SettingKeys.cloudMosaicAutoPageFlipIntervalKey) ?? 1.2;
    if (val >= mosaicPageFlipIntervalMin && val <= mosaicPageFlipIntervalMax) return val;
    return 1.2;
  }

  set cloudMosaicAutoPageFlipInterval(double newValue) => set(SettingKeys.cloudMosaicAutoPageFlipIntervalKey, newValue.clamp(mosaicPageFlipIntervalMin, mosaicPageFlipIntervalMax));

  // mosaic auto page flip distance as ratio of screen dimension (default 0.9)
  double get cloudMosaicAutoPageFlipDistance {
    final val = getDouble(SettingKeys.cloudMosaicAutoPageFlipDistanceKey) ?? 0.9;
    if (val >= pageFlipDistanceMin && val <= pageFlipDistanceMax) return val;
    return 0.9;
  }

  set cloudMosaicAutoPageFlipDistance(double newValue) => set(SettingKeys.cloudMosaicAutoPageFlipDistanceKey, newValue.clamp(pageFlipDistanceMin, pageFlipDistanceMax));

  // sprite sheet -> looping GIF thumbnail: on by default, replayed at a fixed
  // frames-per-second (independent of the video duration), cells read row by
  // row ("row-major") or column by column ("column-major") to match how the
  // sheet was packed
  bool get cloudSpriteAnimationEnabled => getBool(SettingKeys.cloudSpriteAnimationEnabledKey) ?? true;

  set cloudSpriteAnimationEnabled(bool newValue) => set(SettingKeys.cloudSpriteAnimationEnabledKey, newValue);

  static const double spriteAnimationSpeedMin = 0.5;
  static const double spriteAnimationSpeedMax = 60.0;
  static const double defaultSpriteAnimationSpeed = 2;

  double get cloudSpriteAnimationSpeed {
    final val = getDouble(SettingKeys.cloudSpriteAnimationSpeedKey) ?? getInt(SettingKeys.cloudSpriteAnimationSpeedKey)?.toDouble() ?? defaultSpriteAnimationSpeed;
    if (val >= spriteAnimationSpeedMin && val <= spriteAnimationSpeedMax) return val;
    return defaultSpriteAnimationSpeed;
  }

  set cloudSpriteAnimationSpeed(double newValue) => set(SettingKeys.cloudSpriteAnimationSpeedKey, newValue.clamp(spriteAnimationSpeedMin, spriteAnimationSpeedMax));

  // one of `rowMajor`, `columnMajor`
  String get cloudSpriteAnimationOrder => getString(SettingKeys.cloudSpriteAnimationOrderKey) ?? 'rowMajor';

  set cloudSpriteAnimationOrder(String newValue) => set(SettingKeys.cloudSpriteAnimationOrderKey, newValue);

  // Height (or width, for a horizontal mosaic) of the screen band in which
  // sprite animations play, as a percentage of the visible list. `100` keeps
  // the old behaviour: every visible sheet animates. Near the top/bottom the
  // band stretches to the screen centre, so the first/last rows can play too.
  static const minSpritePlaybackZone = 5;
  static const maxSpritePlaybackZone = 100;
  static const defaultSpritePlaybackZone = 5;

  int get cloudSpritePlaybackZone {
    final val = getInt(SettingKeys.cloudSpritePlaybackZoneKey) ?? defaultSpritePlaybackZone;
    return val.clamp(minSpritePlaybackZone, maxSpritePlaybackZone);
  }

  set cloudSpritePlaybackZone(int newValue) => set(SettingKeys.cloudSpritePlaybackZoneKey, newValue.clamp(minSpritePlaybackZone, maxSpritePlaybackZone));

  // Progress of the sheet at which the played frames start: `20` on a 5x5
  // sheet drops the first 5 cells and plays cells 6-25. The dropped cells stay
  // in the file; only the animation ignores them.
  static const minSpriteStartPercent = 0;
  static const maxSpriteStartPercent = 95;
  static const defaultSpriteStartPercent = 0;

  int get cloudSpriteStartPercent {
    final val = getInt(SettingKeys.cloudSpriteStartPercentKey) ?? defaultSpriteStartPercent;
    return val.clamp(minSpriteStartPercent, maxSpriteStartPercent);
  }

  set cloudSpriteStartPercent(int newValue) => set(SettingKeys.cloudSpriteStartPercentKey, newValue.clamp(minSpriteStartPercent, maxSpriteStartPercent));

  // Only list videos that have a sprite sheet, so a folder can be checked at a
  // glance. Off by default: the sheet index comes from the shared cache, so a
  // folder that was never scraped would otherwise look empty.
  bool get cloudSpriteOnly => getBool(SettingKeys.cloudSpriteOnlyKey) ?? false;

  set cloudSpriteOnly(bool newValue) => set(SettingKeys.cloudSpriteOnlyKey, newValue);

  // mosaic magnifier options
  bool get cloudMosaicMagnifierEnabled => getBool(SettingKeys.cloudMosaicMagnifierEnabledKey) ?? true;

  set cloudMosaicMagnifierEnabled(bool newValue) => set(SettingKeys.cloudMosaicMagnifierEnabledKey, newValue);

  int get cloudMosaicMagnifierDelay {
    final val = getInt(SettingKeys.cloudMosaicMagnifierDelayKey) ?? 200;
    if (val >= magnifierDelayMin && val <= magnifierDelayMax) return val;
    return 200;
  }

  set cloudMosaicMagnifierDelay(int newValue) => set(SettingKeys.cloudMosaicMagnifierDelayKey, newValue.clamp(magnifierDelayMin, magnifierDelayMax));

  double get cloudMosaicMagnifierScale {
    final val = getDouble(SettingKeys.cloudMosaicMagnifierScaleKey) ?? 2.5;
    if (val >= magnifierScaleMin && val <= magnifierScaleMax) return val;
    return 2.5;
  }

  set cloudMosaicMagnifierScale(double newValue) => set(SettingKeys.cloudMosaicMagnifierScaleKey, newValue.clamp(magnifierScaleMin, magnifierScaleMax));

  // hide the app bar, address bar and layout bar while scrolling down
  bool get cloudImmersive => getBool(SettingKeys.cloudImmersiveKey) ?? true;

  set cloudImmersive(bool newValue) => set(SettingKeys.cloudImmersiveKey, newValue);

  // one of `nameAsc`, `nameDesc`
  String get cloudSort => getString(SettingKeys.cloudSortKey) ?? 'nameAsc';

  set cloudSort(String newValue) => set(SettingKeys.cloudSortKey, newValue);

  // remote video frames are extracted over the network, which is expensive,
  // so the whole feature can be turned off
  bool get cloudVideoThumbnails => getBool(SettingKeys.cloudVideoThumbnailsKey) ?? true;

  set cloudVideoThumbnails(bool newValue) => set(SettingKeys.cloudVideoThumbnailsKey, newValue);

  // percentage of the video duration used as the thumbnail timestamp: starting
  // slightly after the beginning skips the black frame many videos open with
  double get cloudVideoThumbnailPercent => (getDouble(SettingKeys.cloudVideoThumbnailPercentKey) ?? defaultVideoThumbnailPercent).clamp(minVideoThumbnailPercent, maxVideoThumbnailPercent);

  set cloudVideoThumbnailPercent(double newValue) => set(SettingKeys.cloudVideoThumbnailPercentKey, newValue.clamp(minVideoThumbnailPercent, maxVideoThumbnailPercent));

  static const double defaultVideoThumbnailPercent = 80;
  static const double minVideoThumbnailPercent = 1;
  static const double maxVideoThumbnailPercent = 99;

  // extraction rate limit, in requests per second. A rate limit (rather than a
  // concurrency limit) is what servers actually enforce, and queued requests
  // then wait for their turn instead of bursting when a slot frees up.
  int get cloudThumbnailRate => (getInt(SettingKeys.cloudThumbnailRateKey) ?? defaultThumbnailRate).clamp(minThumbnailRate, maxThumbnailRate);

  set cloudThumbnailRate(int newValue) => set(SettingKeys.cloudThumbnailRateKey, newValue.clamp(minThumbnailRate, maxThumbnailRate));

  static const int defaultThumbnailRate = 2;
  static const int minThumbnailRate = 1;
  static const int maxThumbnailRate = 100;

  // servers rate limit per folder, so a specific folder can override the
  // global limit. `null` means the folder uses the global value.
  Map<String, int>? _folderRateCache;

  bool get cloudThumbnailRatePerFolder => getBool(SettingKeys.cloudThumbnailRatePerFolderKey) ?? false;

  set cloudThumbnailRatePerFolder(bool newValue) => set(SettingKeys.cloudThumbnailRatePerFolderKey, newValue);

  Map<String, int> get _folderRate {
    final cached = _folderRateCache;
    if (cached != null) return cached;
    final map = <String, int>{};
    for (final row in getStringList(SettingKeys.cloudThumbnailFolderRateKey) ?? const <String>[]) {
      final index = row.lastIndexOf('\t');
      if (index <= 0) continue;
      final value = int.tryParse(row.substring(index + 1));
      if (value == null) continue;
      map[cloudFolderKey(row.substring(0, index))] = value.clamp(minThumbnailRate, maxThumbnailRate);
    }
    return _folderRateCache = map;
  }

  int? cloudThumbnailRateOverride(String folderUrl) => _folderRate[cloudFolderKey(folderUrl)];

  // with the per-folder mode off, every folder uses the global value (stored
  // overrides are kept but dormant, so switching back on restores them)
  int cloudThumbnailRateForFolder(String folderUrl) {
    if (!cloudThumbnailRatePerFolder) return cloudThumbnailRate;
    return (cloudThumbnailRateOverride(folderUrl) ?? cloudThumbnailRate).clamp(minThumbnailRate, maxThumbnailRate);
  }

  void setCloudThumbnailRateForFolder(String folderUrl, int value) {
    final map = _folderRate;
    map[cloudFolderKey(folderUrl)] = value.clamp(minThumbnailRate, maxThumbnailRate);
    set(SettingKeys.cloudThumbnailFolderRateKey, [for (final e in map.entries) '${e.key}\t${e.value}']);
  }

  void clearCloudThumbnailRateForFolder(String folderUrl) {
    final map = _folderRate;
    if (map.remove(cloudFolderKey(folderUrl)) == null) return;
    set(SettingKeys.cloudThumbnailFolderRateKey, [for (final e in map.entries) '${e.key}\t${e.value}']);
  }

  // optional shared thumbnail cache on WebDAV: extracted video frames are
  // uploaded to a folder of a WebDAV service, so another install (or a fresh
  // local cache) can reuse them instead of extracting them again
  bool get cloudThumbnailCacheEnabled => getBool(SettingKeys.cloudThumbnailCacheEnabledKey) ?? false;

  set cloudThumbnailCacheEnabled(bool newValue) => set(SettingKeys.cloudThumbnailCacheEnabledKey, newValue);

  String? get cloudThumbnailCacheServerId => getString(SettingKeys.cloudThumbnailCacheServerIdKey);

  set cloudThumbnailCacheServerId(String? newValue) => set(SettingKeys.cloudThumbnailCacheServerIdKey, newValue);

  String? get cloudThumbnailCacheFolderUrl => getString(SettingKeys.cloudThumbnailCacheFolderUrlKey);

  set cloudThumbnailCacheFolderUrl(String? newValue) => set(SettingKeys.cloudThumbnailCacheFolderUrlKey, newValue);

  // the cache is fully configured when enabled, the server still exists and is
  // a WebDAV service, and a destination folder was picked
  CloudServer? get cloudThumbnailCacheServer {
    final id = cloudThumbnailCacheServerId;
    if (id == null || id.isEmpty) return null;
    for (final server in cloudServers) {
      if (server.id == id) return server;
    }
    return null;
  }

  bool get cloudThumbnailCacheConfigured => cloudThumbnailCacheServer != null && (cloudThumbnailCacheFolderUrl?.isNotEmpty ?? false);

  // remembered so the settings page can offer to scrape the same folder again
  String? get cloudScrapeFolderUrl => getString(SettingKeys.cloudScrapeFolderUrlKey);

  set cloudScrapeFolderUrl(String? newValue) => set(SettingKeys.cloudScrapeFolderUrlKey, newValue);

  bool get cloudThumbnailCacheReady => cloudThumbnailCacheEnabled && cloudThumbnailCacheConfigured;

  // diagnostic log: records network requests, thumbnail extraction, scraping
  // and cache operations, shown on the log page and colored by kind
  bool get cloudLogEnabled => getBool(SettingKeys.cloudLogEnabledKey) ?? true;

  set cloudLogEnabled(bool newValue) => set(SettingKeys.cloudLogEnabledKey, newValue);

  bool get cloudVideoDurationVisible => getBool(SettingKeys.cloudVideoDurationKey) ?? true;

  set cloudVideoDurationVisible(bool newValue) => set(SettingKeys.cloudVideoDurationKey, newValue);

  bool get cloudVideoPlayIcon => getBool(SettingKeys.cloudVideoPlayIconKey) ?? true;

  set cloudVideoPlayIcon(bool newValue) => set(SettingKeys.cloudVideoPlayIconKey, newValue);

  // URLs of folders already opened and of media already played, rendered dimmed
  List<String> get cloudVisited => getStringList(SettingKeys.cloudVisitedFoldersKey) ?? const [];

  set cloudVisited(List<String> newValue) {
    _visitedLookup = null;
    set(SettingKeys.cloudVisitedFoldersKey, newValue);
  }

  // O(1) lookup for the per-tile "watched"/dimmed check
  Set<String> get _cloudVisitedSet => _visitedLookup ??= cloudVisited.toSet();

  bool isCloudVisited(String url) => _cloudVisitedSet.contains(url);

  void markCloudVisited(String url) {
    if (url.isEmpty) return;
    final current = cloudVisited;
    if (current.contains(url)) return;
    final next = [...current, url];
    cloudVisited = next.length > 4000 ? next.sublist(next.length - 4000) : next;
  }

  // canonical folder key, with a trailing slash, so a collection URL returned
  // by a server with or without one maps to the same progress entry
  static String cloudFolderKey(String url) => url.endsWith('/') ? url : '$url/';

  bool isCloudFolderVisited(String url) {
    final key = cloudFolderKey(url);
    if (isCloudVisited(key)) return true;
    return key == url ? false : isCloudVisited(url);
  }

  // opening a subfolder also advances the progress of its parent, so a folder
  // showing "3/12" does not need to be re-listed to know that
  void markCloudFolderVisited(String url) {
    if (url.isEmpty) return;
    final key = cloudFolderKey(url);
    final wasVisited = isCloudVisited(key);
    markCloudVisited(key);
    if (wasVisited) return;
    final parent = cloudParentUrl(key);
    final stats = _folderStatsMap()[parent];
    if (stats == null) return;
    if (stats.visitedFolders < stats.totalFolders) {
      stats.visitedFolders++;
      _markFolderCompleteIfDone(stats);
      _folderStatsDirtyKeys.add(parent);
      // debounced: the flush writes the whole stored list, and the page flushes
      // on leave as well
      _scheduleFolderStatsFlush();
    }
  }

  // parent of a file or of a folder. Collection URLs already end with a slash,
  // which must be removed before looking for the previous separator, otherwise
  // a folder would be reported as its own parent.
  static String cloudParentUrl(String url) {
    var value = url;
    while (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    final scheme = value.indexOf('://');
    final last = value.lastIndexOf('/');
    if (last <= scheme + 2) return value;
    return value.substring(0, last + 1);
  }

  static int _hashUrl(String url) {
    var hash = 0x811c9dc5;
    for (final codeUnit in url.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  Map<String, CloudFolderStats> _folderStatsMap() {
    final cached = _folderStatsCache;
    if (cached != null) return cached;
    final map = <String, CloudFolderStats>{};
    for (final row in getStringList(SettingKeys.cloudFolderStatsKey) ?? const <String>[]) {
      final parts = row.split('\t');
      if (parts.length < 5) continue;
      final totalImages = int.tryParse(parts[1]) ?? 0;
      final totalFolders = int.tryParse(parts[2]) ?? 0;
      final visitedFolders = int.tryParse(parts[3]) ?? 0;
      final hashes = parts[4].isEmpty ? const <int>[] : parts[4].split(',').map((v) => int.tryParse(v, radix: 16)).nonNulls;
      // normalize legacy entries that were stored without a trailing slash
      final key = cloudFolderKey(parts[0]);
      final stats = CloudFolderStats()
        ..totalImages = totalImages
        ..totalFolders = totalFolders
        ..visitedFolders = visitedFolders
        ..complete = parts.length > 5 && parts[5] == '1'
        ..loaded.addAll(hashes);
      // rows written before the flag existed: derive it from the hashes
      _markFolderCompleteIfDone(stats);
      map[key] = stats;
      _folderStatsRows[key] = row;
      if (key != parts[0]) _folderStatsDirtyKeys.add(key);
    }
    _loadedHashes = map.values.fold(0, (sum, stats) => sum + stats.loaded.length);
    _folderStatsCache = map;
    _enforceLoadedBudget();
    return map;
  }

  // Sets the sticky completion flag when the folder is fully seen, using the
  // same criterion as the progress display: mostly images are reported by
  // loaded thumbnails, folders of folders by opened subfolders.
  static void _markFolderCompleteIfDone(CloudFolderStats stats) {
    if (stats.complete) return;
    if (stats.totalImages > 0 && stats.totalImages >= stats.totalFolders) {
      if (stats.loaded.length >= stats.totalImages) stats.complete = true;
    } else if (stats.totalFolders > 0 && stats.visitedFolders >= stats.totalFolders) {
      stats.complete = true;
    }
  }

  // Keeps the stored progress data bounded: when the total number of recorded
  // hashes exceeds the cap, the oldest folders lose their loaded set (their
  // totals and completion flag are kept, so the progress does not reset).
  void _enforceLoadedBudget() {
    if (_loadedHashes <= _maxTotalLoadedHashes) return;
    for (final entry in _folderStatsMap().entries) {
      if (_loadedHashes <= _maxTotalLoadedHashes) break;
      final count = entry.value.loaded.length;
      if (count == 0) continue;
      entry.value.loaded.clear();
      _loadedHashes -= count;
      _folderStatsDirtyKeys.add(entry.key);
    }
    _scheduleFolderStatsFlush();
  }

  // records what the folder listing contains, so a parent row can later show
  // the progress of its subfolders without listing them again
  void recordCloudFolder(String url, {required int imageCount, required int folderCount}) {
    final key = cloudFolderKey(url);
    final map = _folderStatsMap();
    var stats = map[key];
    var changed = false;
    if (stats == null) {
      if (map.length >= _maxFolderStats) {
        final evicted = map.keys.first;
        final removed = map.remove(evicted);
        if (removed != null) _loadedHashes = math.max(0, _loadedHashes - removed.loaded.length);
        _folderStatsRows.remove(evicted);
        _folderStatsDirtyKeys.remove(evicted);
      }
      stats = map[key] = CloudFolderStats();
      // a new folder must get a stored row, even when it is empty
      changed = true;
    }
    if (stats.totalImages != imageCount) {
      // new files appeared: the folder is no longer fully seen
      if (imageCount > stats.totalImages) stats.complete = false;
      stats.totalImages = imageCount;
      changed = true;
    }
    if (stats.totalFolders != folderCount) {
      if (folderCount > stats.totalFolders) stats.complete = false;
      stats.totalFolders = folderCount;
      changed = true;
    }
    final cappedVisited = math.min(stats.visitedFolders, folderCount);
    if (stats.visitedFolders != cappedVisited) {
      stats.visitedFolders = cappedVisited;
      changed = true;
    }
    final wasComplete = stats.complete;
    _markFolderCompleteIfDone(stats);
    if (stats.complete != wasComplete) changed = true;
    if (changed) {
      _folderStatsDirtyKeys.add(key);
      _scheduleFolderStatsFlush();
    }
  }

  // a thumbnail was decoded and shown: count it once, keyed by its URL hash so
  // the stored set stays compact even for folders with thousands of images
  void markCloudImageLoaded(String imageUrl) {
    if (imageUrl.isEmpty) return;
    final key = cloudFolderKey(cloudParentUrl(imageUrl));
    final stats = _folderStatsMap()[key];
    if (stats == null || stats.loaded.length >= _maxLoadedPerFolder) return;
    if (stats.loaded.add(_hashUrl(imageUrl))) {
      _loadedHashes++;
      _markFolderCompleteIfDone(stats);
      _folderStatsDirtyKeys.add(key);
      _enforceLoadedBudget();
      _scheduleFolderStatsFlush();
    }
  }

  // the picture no longer exists on the server: stop counting it as loaded
  void forgetCloudImage(String imageUrl) {
    final key = cloudFolderKey(cloudParentUrl(imageUrl));
    final stats = _folderStatsMap()[key];
    if (stats == null) return;
    if (stats.loaded.remove(_hashUrl(imageUrl))) {
      _loadedHashes = math.max(0, _loadedHashes - 1);
      _folderStatsDirtyKeys.add(key);
      _scheduleFolderStatsFlush();
    }
  }

  // the folder no longer exists on the server: drop its progress and its
  // "already opened" mark
  void forgetCloudFolder(String url) {
    final key = cloudFolderKey(url);
    final map = _folderStatsMap();
    final removed = map.remove(key);
    if (removed != null) {
      _loadedHashes = math.max(0, _loadedHashes - removed.loaded.length);
      _folderStatsRows.remove(key);
      _folderStatsDirtyKeys.remove(key);
      _scheduleFolderStatsFlush();
    }
    final current = cloudVisited;
    if (current.contains(key) || current.contains(key.substring(0, key.length - 1))) {
      cloudVisited = current.where((v) => v != key && v != key.substring(0, key.length - 1)).toList();
    }
  }

  int get cloudProgressFolderCount => _folderStatsMap().length;

  int get cloudProgressImageCount => _folderStatsMap().values.fold(
    0,
    (sum, stats) => sum + math.min(stats.complete ? stats.totalImages : stats.loaded.length, stats.totalImages),
  );

  // wipes every folder's viewing progress and the "already opened / already
  // watched" marks. Playback positions and durations are kept.
  void clearCloudFolderProgress() {
    _folderStatsCache = null;
    _folderStatsRows.clear();
    _folderStatsDirtyKeys.clear();
    _loadedHashes = 0;
    _folderStatsFlushTimer?.cancel();
    _folderStatsFlushTimer = null;
    _folderStatsDirty = false;
    _visitedLookup = null;
    set(SettingKeys.cloudFolderStatsKey, null);
    set(SettingKeys.cloudVisitedFoldersKey, null);
    clearCloudFolderScrolls();
  }

  // "loaded/total" for an image folder, "opened/total" for a folder of folders.
  // Folders that were never listed have no stats yet and show nothing.
  String? cloudFolderProgressText(String url) {
    final stats = _folderStatsMap()[cloudFolderKey(url)];
    if (stats == null) return null;
    // mostly images (or images only): report thumbnail progress
    if (stats.totalImages > 0 && stats.totalImages >= stats.totalFolders) {
      final loaded = stats.complete ? stats.totalImages : math.min(stats.loaded.length, stats.totalImages);
      return '$loaded/${stats.totalImages}';
    }
    if (stats.totalFolders > 0) {
      final visited = stats.complete ? stats.totalFolders : math.min(stats.visitedFolders, stats.totalFolders);
      return '$visited/${stats.totalFolders}';
    }
    return null;
  }

  // whether the folder is fully seen: all its images have loaded thumbnails,
  // or all its subfolders have been opened. Folders without stats are unknown.
  bool cloudFolderProgressComplete(String url) {
    final stats = _folderStatsMap()[cloudFolderKey(url)];
    if (stats == null) return false;
    // the sticky flag survives the hash budget being trimmed
    if (stats.complete) return true;
    if (stats.totalImages > 0 && stats.totalImages >= stats.totalFolders) {
      return stats.loaded.length >= stats.totalImages;
    }
    if (stats.totalFolders > 0) {
      return stats.visitedFolders >= stats.totalFolders;
    }
    return false;
  }

  bool get cloudHideCompletedFolders => getBool(SettingKeys.cloudHideCompletedFoldersKey) ?? false;

  set cloudHideCompletedFolders(bool newValue) => set(SettingKeys.cloudHideCompletedFoldersKey, newValue);

  // last scroll offset per folder, persisted so a restart resumes where the
  // user stopped. Kept for the most recently used folders only.
  Map<String, double> get _scrollPositions {
    final cached = _scrollPositionsCache;
    if (cached != null) return cached;
    final map = <String, double>{};
    for (final row in getStringList(SettingKeys.cloudFolderScrollPositionsKey) ?? const <String>[]) {
      final index = row.lastIndexOf('\t');
      if (index <= 0) continue;
      final offset = double.tryParse(row.substring(index + 1));
      if (offset == null) continue;
      map[cloudFolderKey(row.substring(0, index))] = offset;
    }
    return _scrollPositionsCache = map;
  }

  double? cloudFolderScroll(String url) => _scrollPositions[cloudFolderKey(url)];

  void setCloudFolderScroll(String url, double offset) {
    if (url.isEmpty || !offset.isFinite || offset < 0) return;
    final key = cloudFolderKey(url);
    final map = _scrollPositions;
    final current = map[key];
    if (current != null && (current - offset).abs() < 1) return;
    // move to the end so the most recently used folders are kept
    map.remove(key);
    map[key] = offset;
    while (map.length > 500) {
      map.remove(map.keys.first);
    }
    _scrollPositionsDirty = true;
    _scrollPositionsFlushTimer ??= Timer(const Duration(seconds: 2), flushCloudFolderScrolls);
  }

  void flushCloudFolderScrolls() {
    _scrollPositionsFlushTimer?.cancel();
    _scrollPositionsFlushTimer = null;
    if (!_scrollPositionsDirty) return;
    _scrollPositionsDirty = false;
    final rows = [
      for (final entry in _scrollPositions.entries) '${entry.key}\t${entry.value.toStringAsFixed(1)}',
    ];
    store.setStringList(SettingKeys.cloudFolderScrollPositionsKey, rows);
  }

  void clearCloudFolderScrolls() {
    _scrollPositionsCache = <String, double>{};
    _scrollPositionsFlushTimer?.cancel();
    _scrollPositionsFlushTimer = null;
    _scrollPositionsDirty = false;
    set(SettingKeys.cloudFolderScrollPositionsKey, null);
  }

  void _scheduleFolderStatsFlush() {
    _folderStatsDirty = true;
    // thumbnails arrive in bursts while scrolling: persist once they settle,
    // without rewriting the whole list on every few tiles
    _folderStatsFlushTimer ??= Timer(const Duration(seconds: 10), flushCloudFolderStats);
  }

  void flushCloudFolderStats() {
    _folderStatsFlushTimer?.cancel();
    _folderStatsFlushTimer = null;
    if (!_folderStatsDirty) return;
    _folderStatsDirty = false;
    final map = _folderStatsMap();
    // drop rows of folders that no longer exist, then rebuild only the rows
    // whose folder changed since the previous flush
    _folderStatsRows.removeWhere((key, _) => !map.containsKey(key));
    for (final key in _folderStatsDirtyKeys) {
      final stats = map[key];
      if (stats == null) {
        _folderStatsRows.remove(key);
      } else {
        _folderStatsRows[key] = _folderStatsRow(key, stats);
      }
    }
    _folderStatsDirtyKeys.clear();
    // keep the map order, which is the order the folders were first stored in
    final rows = [for (final key in map.keys) _folderStatsRows[key] ?? ''];
    rows.removeWhere((row) => row.isEmpty);
    // write silently: this runs every few seconds while thumbnails load, and a
    // notification would rebuild every settings listener for no visible change
    store.setStringList(SettingKeys.cloudFolderStatsKey, rows);
  }

  static String _folderStatsRow(String key, CloudFolderStats stats) {
    final hashes = stats.loaded.map((h) => h.toRadixString(16).padLeft(8, '0')).join(',');
    return '$key\t${stats.totalImages}\t${stats.totalFolders}\t${stats.visitedFolders}\t$hashes\t${stats.complete ? '1' : '0'}';
  }

  Map<String, Object?> exportCloudFolderStats() => {
    'version': 1,
    'folders': <String, Object?>{
      for (final entry in _folderStatsMap().entries)
        entry.key: <String, Object?>{
          'images': entry.value.totalImages,
          'folders': entry.value.totalFolders,
          'visited': entry.value.visitedFolders,
          'loaded': [for (final hash in entry.value.loaded) hash.toRadixString(16).padLeft(8, '0')],
        },
    },
  };

  // merges an exported backup into the current progress (never lowers a count)
  int importCloudFolderStats(Object? json) {
    if (json is! Map) return 0;
    final folders = json['folders'];
    if (folders is! Map) return 0;
    final map = _folderStatsMap();
    var count = 0;
    for (final entry in folders.entries) {
      final url = entry.key;
      final value = entry.value;
      if (url is! String || url.isEmpty || value is! Map) continue;
      final stats = map.putIfAbsent(cloudFolderKey(url), CloudFolderStats.new);
      stats.totalImages = math.max(stats.totalImages, (value['images'] as num?)?.toInt() ?? 0);
      stats.totalFolders = math.max(stats.totalFolders, (value['folders'] as num?)?.toInt() ?? 0);
      stats.visitedFolders = math.max(stats.visitedFolders, (value['visited'] as num?)?.toInt() ?? 0);
      final loaded = value['loaded'];
      if (loaded is List) {
        for (final item in loaded) {
          final hash = item is int ? item : (item is String ? int.tryParse(item, radix: 16) : null);
          if (hash != null && stats.loaded.length < _maxLoadedPerFolder && stats.loaded.add(hash)) {
            _loadedHashes++;
          }
        }
      }
      _markFolderCompleteIfDone(stats);
      count++;
    }
    if (count > 0) {
      for (final entry in folders.keys) {
        if (entry is String && entry.isNotEmpty) _folderStatsDirtyKeys.add(cloudFolderKey(entry));
      }
      _folderStatsDirty = true;
      _enforceLoadedBudget();
      flushCloudFolderStats();
    }
    return count;
  }

  // last playback position and duration of each video (milliseconds), so it
  // can both resume and show a progress bar on the tile
  Map<String, (int, int)> get _cloudVideoPositions {
    final cached = _videoPositionsCache;
    if (cached != null) return cached;
    final stored = getStringList(SettingKeys.cloudVideoPositionsKey) ?? const [];
    final map = <String, (int, int)>{};
    for (final entry in stored) {
      final parts = entry.split('\t');
      if (parts.length < 3) continue;
      final position = int.tryParse(parts[parts.length - 2]);
      final duration = int.tryParse(parts[parts.length - 1]);
      if (position == null || duration == null) continue;
      map[parts.sublist(0, parts.length - 2).join('\t')] = (position, duration);
    }
    return _videoPositionsCache = map;
  }

  int? cloudVideoPosition(String url) => _cloudVideoPositions[url]?.$1;

  int? cloudVideoDuration(String url) => _cloudVideoPositions[url]?.$2;

  void setCloudVideoProgress(String url, int positionMillis, int durationMillis) {
    if (url.isEmpty) return;
    final map = _cloudVideoPositions;
    if (positionMillis <= 0) {
      if (map.remove(url) == null) return;
    } else {
      final current = map[url];
      if (current != null && current.$1 == positionMillis && current.$2 == durationMillis) return;
      // move to the end so the flush below keeps the most recently watched
      // videos rather than the ones inserted first
      map.remove(url);
      map[url] = (positionMillis, durationMillis);
    }
    _scheduleVideoPositionsFlush();
  }

  // records the duration probed while extracting a thumbnail, keeping any
  // playback position already stored for that video
  void setCloudVideoDuration(String url, int durationMillis) {
    if (url.isEmpty || durationMillis <= 0) return;
    final map = _cloudVideoPositions;
    final current = map[url];
    if (current != null && current.$2 == durationMillis) return;
    map.remove(url);
    map[url] = (current?.$1 ?? 0, durationMillis);
    _scheduleVideoPositionsFlush();
  }

  // merges the durations of a whole folder read from the shared thumbnail
  // cache in one write, so opening a folder with hundreds of videos does not
  // rewrite the stored list once per video
  int mergeCloudVideoDurations(Map<String, int> durations) {
    if (durations.isEmpty) return 0;
    final map = _cloudVideoPositions;
    var changed = 0;
    durations.forEach((url, duration) {
      if (url.isEmpty || duration <= 0) return;
      final current = map[url];
      if (current != null && current.$2 == duration) return;
      map.remove(url);
      map[url] = (current?.$1 ?? 0, duration);
      changed++;
    });
    if (changed > 0) _scheduleVideoPositionsFlush();
    return changed;
  }

  void _scheduleVideoPositionsFlush() {
    _videoPositionsDirty = true;
    _videoPositionsFlushTimer ??= Timer(const Duration(seconds: 10), flushCloudVideoPositions);
  }

  // Writes the in-memory positions once, instead of rewriting the whole stored
  // list for every few seconds of playback or every extracted frame. The
  // duration badges are refreshed through the update stream without rebuilding
  // every settings listener.
  void flushCloudVideoPositions() {
    _videoPositionsFlushTimer?.cancel();
    _videoPositionsFlushTimer = null;
    if (!_videoPositionsDirty) return;
    _videoPositionsDirty = false;
    final map = _cloudVideoPositions;
    final entries = map.entries.toList();
    // keep the most recently watched entries, not the oldest
    final capped = entries.length > 4000 ? entries.sublist(entries.length - 4000) : entries;
    _videoPositionsCache = Map.fromEntries(capped);
    store.setStringList(SettingKeys.cloudVideoPositionsKey, [for (final e in capped) '${e.key}\t${e.value.$1}\t${e.value.$2}']);
    notifyKeyChange(SettingKeys.cloudVideoPositionsKey, null, null);
  }

  Map<String, (int, int)> get _cloudImageDimensions {
    final cached = _imageDimensionsCache;
    if (cached != null) return cached;
    final stored = getStringList(SettingKeys.cloudImageDimensionsKey) ?? const [];
    final map = <String, (int, int)>{};
    for (final entry in stored) {
      final parts = entry.split('\t');
      if (parts.length < 3) continue;
      final w = int.tryParse(parts[parts.length - 2]);
      final h = int.tryParse(parts[parts.length - 1]);
      if (w == null || h == null) continue;
      map[parts.sublist(0, parts.length - 2).join('\t')] = (w, h);
    }
    return _imageDimensionsCache = map;
  }

  (int, int)? cloudImageDimensions(String url) => _cloudImageDimensions[url];

  void setCloudImageDimensions(String url, int width, int height) {
    if (url.isEmpty || width <= 0 || height <= 0) return;
    final map = _cloudImageDimensions;
    final current = map[url];
    if (current != null && current.$1 == width && current.$2 == height) return;
    // same recency rule as the video map: the flush keeps the newest entries
    map.remove(url);
    map[url] = (width, height);
    _imageDimensionsDirty = true;
    _imageDimensionsFlushTimer ??= Timer(const Duration(seconds: 3), flushCloudImageDimensions);
  }

  // Writes the dimensions learned while decoding a folder's thumbnails in one
  // go: one write per image meant serializing up to 4000 rows per tile.
  void flushCloudImageDimensions() {
    _imageDimensionsFlushTimer?.cancel();
    _imageDimensionsFlushTimer = null;
    if (!_imageDimensionsDirty) return;
    _imageDimensionsDirty = false;
    final map = _cloudImageDimensions;
    final entries = map.entries.toList();
    final capped = entries.length > 4000 ? entries.sublist(entries.length - 4000) : entries;
    _imageDimensionsCache = Map.fromEntries(capped);
    store.setStringList(SettingKeys.cloudImageDimensionsKey, [for (final e in capped) '${e.key}\t${e.value.$1}\t${e.value.$2}']);
  }

  // last opened location, to restore the page on the next launch
  String? get cloudLastServerId => getString(SettingKeys.cloudLastServerIdKey) ?? getString(SettingKeys.legacyWebDavLastServerIdKey);

  String? get cloudLastUrl => getString(SettingKeys.cloudLastUrlKey) ?? getString(SettingKeys.legacyWebDavLastUrlKey);

  void setCloudLastLocation(String? serverId, String? url) {
    set(SettingKeys.cloudLastServerIdKey, serverId);
    set(SettingKeys.cloudLastUrlKey, url);
  }

  bool get cloudSeamlessSwitch => getBool(SettingKeys.cloudSeamlessSwitchKey) ?? true;

  set cloudSeamlessSwitch(bool newValue) => set(SettingKeys.cloudSeamlessSwitchKey, newValue);

  // decode quality of cloud images: 'standard' keeps the historical caps,
  // 'high' doubles them, 'original' decodes at the file's native resolution
  // (still bounded in practice by the decoded bitmap budget below)
  static const cloudThumbnailQualities = ['standard', 'high', 'original'];
  static const defaultCloudThumbnailQuality = 'original';

  String get cloudThumbnailQuality {
    final val = getString(SettingKeys.cloudThumbnailQualityKey) ?? defaultCloudThumbnailQuality;
    return cloudThumbnailQualities.contains(val) ? val : defaultCloudThumbnailQuality;
  }

  set cloudThumbnailQuality(String newValue) {
    if (cloudThumbnailQualities.contains(newValue)) {
      set(SettingKeys.cloudThumbnailQualityKey, newValue);
    }
  }

  // budget of the decoded bitmap cache (Flutter's imageCache). The oldest
  // bitmaps are released first when it is full, so 'original' quality cannot
  // grow the heap without bound.
  //
  // `0` means no explicit budget: the cache keeps what was decoded and lets the
  // system reclaim memory under pressure, instead of throwing away pictures the
  // user just looked at. It is still capped internally at a value no phone can
  // usefully exceed (see `applyCloudDecodeBudget`).
  static const cloudDecodeMemoryLimitsMb = [0, 256, 512, 1024, 2048, 4096];
  static const minCloudDecodeMemoryLimitMb = 256;
  static const maxCloudDecodeMemoryLimitMb = 4096;
  static const defaultCloudDecodeMemoryLimitMb = 512;

  int get cloudDecodeMemoryLimitMb {
    final val = getInt(SettingKeys.cloudDecodeMemoryLimitKey) ?? defaultCloudDecodeMemoryLimitMb;
    if (val <= 0) return 0;
    return val.clamp(minCloudDecodeMemoryLimitMb, maxCloudDecodeMemoryLimitMb);
  }

  set cloudDecodeMemoryLimitMb(int newValue) {
    final value = newValue <= 0 ? 0 : newValue.clamp(minCloudDecodeMemoryLimitMb, maxCloudDecodeMemoryLimitMb);
    set(SettingKeys.cloudDecodeMemoryLimitKey, value);
  }

  // budget of the local disk cache (downloaded originals, extracted frames,
  // sprite sheets and the small thumbnail copies).
  //
  // `0` means unlimited: nothing is evicted by a budget, which is only sensible
  // when the cache lives on a large card, so it is an explicit choice.
  static const cloudDiskCacheSizesMb = [0, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768];
  static const minCloudDiskCacheSizeMb = 256;
  static const maxCloudDiskCacheSizeMb = 32768;
  static const defaultCloudDiskCacheSizeMb = 2048;

  int get cloudDiskCacheSizeMb {
    final val = getInt(SettingKeys.cloudDiskCacheSizeMbKey) ?? defaultCloudDiskCacheSizeMb;
    if (val <= 0) return 0;
    return val.clamp(minCloudDiskCacheSizeMb, maxCloudDiskCacheSizeMb);
  }

  set cloudDiskCacheSizeMb(int newValue) {
    final value = newValue <= 0 ? 0 : newValue.clamp(minCloudDiskCacheSizeMb, maxCloudDiskCacheSizeMb);
    set(SettingKeys.cloudDiskCacheSizeMbKey, value);
  }

  // Stores a small JPEG of every displayed cloud thumbnail, so that opening a
  // folder again decodes from a local copy instead of downloading the original
  // files again. The cache holds many more images than originals would.
  bool get cloudThumbnailDiskCacheEnabled => getBool(SettingKeys.cloudThumbnailDiskCacheKey) ?? true;

  set cloudThumbnailDiskCacheEnabled(bool newValue) => set(SettingKeys.cloudThumbnailDiskCacheKey, newValue);

  // Whether the browser draws thumbnails at all. Turning it off turns the grid
  // into a file list that downloads nothing until a file is opened, which is
  // what a metered connection or a huge folder needs.
  bool get cloudShowThumbnails => getBool(SettingKeys.cloudShowThumbnailsKey) ?? true;

  set cloudShowThumbnails(bool newValue) => set(SettingKeys.cloudShowThumbnailsKey, newValue);
}
