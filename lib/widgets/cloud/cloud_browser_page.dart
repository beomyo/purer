import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:purer/image_providers/cloud_sprite_provider.dart';
import 'package:purer/model/entry/cache.dart';
import 'package:purer/model/entry/entry.dart';
import 'package:purer/model/entry/extensions/props.dart';
import 'package:purer/model/settings/settings.dart';
import 'package:purer/model/source/cloud/cloud_entry.dart';
import 'package:purer/model/source/cloud/cloud_resource.dart';
import 'package:purer/model/source/cloud/cloud_server.dart';
import 'package:purer/ref/mime_types.dart';
import 'package:purer/services/common/cloud_registry.dart';
import 'package:purer/services/common/services.dart';
import 'package:purer/services/media/cloud_client.dart';
import 'package:purer/services/media/cloud_fetch_service.dart';
import 'package:purer/services/log/purer_log.dart';
import 'package:purer/services/media/cloud_media_cache.dart';
import 'package:purer/services/media/cloud_mime.dart';
import 'package:purer/theme/format.dart';
import 'package:purer/theme/icons.dart';
import 'package:purer/utils/cloud_url.dart';
import 'package:purer/utils/file_utils.dart';
import 'package:purer/widgets/common/action_mixins/feedback.dart';
import 'package:purer/widgets/common/basic/draggable_scrollbar/scrollbar.dart';
import 'package:purer/widgets/common/basic/scaffold.dart';
import 'package:purer/widgets/common/behaviour/eager_scale_gesture_recognizer.dart';
import 'package:purer/widgets/common/extensions/build_context.dart';
import 'package:purer/widgets/common/identity/empty.dart';
import 'package:purer/widgets/common/identity/scroll_thumb.dart';
import 'package:purer/widgets/common/thumbnail/image.dart';
import 'package:purer/widgets/cloud/cloud_options_sheet.dart';
import 'package:purer/widgets/cloud/cloud_video_page.dart';
import 'package:purer/widgets/cloud/cloud_view_options.dart';
import 'package:purer/widgets/cloud/cloud_viewer_page.dart';
import 'package:purer/widgets/cloud/loupe_magnifier.dart';
import 'package:purer_model/purer_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

enum _LoadState { loading, ready, error }

// remote thumbnails can fail transiently (timeout, rate limit): retry a few
// times with a growing delay, after the extraction cooldown has expired
const _cloudThumbnailRetryDelays = [Duration(milliseconds: 500), Duration(seconds: 2), Duration(seconds: 6), Duration(seconds: 20)];

// duration badge of a cloud video, or null when it is unknown or hidden
String? _cloudVideoDurationText(PurerEntry entry, {required bool visible}) {
  if (!entry.isVideo || !visible) return null;
  final durationMillis = settings.cloudVideoDuration(entry.uri);
  if (durationMillis == null || durationMillis <= 0) return null;
  return formatFriendlyDuration(Duration(milliseconds: durationMillis));
}

class CloudBrowserPage extends StatefulWidget {
  static const routeName = '/cloud/browse';
  static const double addressBarHeight = 42;

  final CloudServer server;
  final String? initialUrl;

  const new({super.key, required this.server, this.initialUrl});

  @override
  State<CloudBrowserPage> createState() => _CloudBrowserPageState();
}

class _CloudBrowserPageState extends State<CloudBrowserPage> with TickerProviderStateMixin, FeedbackMixin {
  static const int _maxFolderSnapshots = 30;
  static const int _maxFolderLists = 60;
  // bound the memory held by listing snapshots even when each folder is huge
  static const int _maxSnapshotEntries = 20000;
  // bound the aspect ratios learned during a long session
  static const int _maxCachedAspects = 20000;

  final ValueNotifier<_LoadState> _state = ValueNotifier(_LoadState.loading);
  final ValueNotifier<String> _error = ValueNotifier('');
  final ValueNotifier<List<CloudResource>> _folders = ValueNotifier([]);
  final ValueNotifier<List<PurerEntry>> _media = ValueNotifier([]);
  // recreated per folder so the saved offset applies to the first layout (see
  // `_bindScrollController`), and swapped through `_scrollGeneration`
  ScrollController _scrollController = ScrollController();
  String? _scrollBoundUrl;
  int _scrollGeneration = 0;
  final ScrollController _addressScrollController = ScrollController();
  final GlobalKey _currentCrumbKey = GlobalKey();
  final GlobalKey _addressViewportKey = GlobalKey();

  // visited folders, in navigation order. Going back moves `_trailIndex`
  // without dropping the deeper entries, so the address bar can still offer
  // them and returning to one is instant (the listing is cached).
  List<String> _trail = [];
  int _trailIndex = 0;
  late String _currentUrl;
  StreamSubscription? _settingsSub;

  // listing snapshots per folder, so navigating back and forth does not list
  // the same folder again; `_folderLists` only keeps the folders of a listing
  // and is enough to find the sibling to move to on over-scroll
  final Map<String, _FolderSnapshot> _folderSnapshots = {};
  final Map<String, List<CloudResource>> _folderLists = {};
  final Set<String> _primingParents = {};
  // sibling folders whose first screen is being fetched ahead of the switch,
  // so a caller can await the request already in flight instead of starting
  // a second one (or timing out while it is still running)
  final Map<String, Future<void>> _prefetchFutures = {};
  // images decoded in this session, so the long-press magnifier never
  // enlarges a loading placeholder
  final Set<String> _loadedImageUris = {};
  // set by an image tile on pointer down (deepest listener runs first)
  String? _pointerImageUri;
  // a folder opened by the auto motion starts at the top, whatever offset the
  // user last stopped at in it
  bool _startAtTop = false;
  bool _advancingToNextFolder = false;
  // a folder that was just swapped in has no layout yet (maxScrollExtent is 0),
  // which would look like 'already at the end': ignore end detection briefly
  DateTime _endGuardUntil = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, DateTime> _siblingRetryAfter = {};
  int _snapshotEntryCount = 0;

  // over-scroll progress towards the next sibling folder (mosaic only)
  final ValueNotifier<double> _nextFolderProgress = ValueNotifier(0);
  final ValueNotifier<CloudResource?> _nextFolder = ValueNotifier(null);
  Timer? _overscrollTimer;
  double _overscroll = 0;
  double _overscrollThreshold = 0;
  bool _overscrollLocked = false;
  int _pointerCount = 0;

  // Mosaic auto-scroll & auto-page flip
  final ValueNotifier<bool> _autoScrollingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _autoFlippingNotifier = ValueNotifier(false);
  late final Ticker _autoScrollTicker;
  Duration _lastAutoScrollTick = Duration.zero;
  Timer? _mosaicFlipTimer;
  bool _userInteracting = false;

  // Batch selection state
  bool _selectionMode = false;
  final Set<PurerEntry> _selectedEntries = {};
  // background cache cleanup of deleted entries, chained so several batches
  // do not hit the cache server at the same time
  Future<void> _cacheCleanup = Future<void>.value();
  // bumped when the cached thumbnails of the current folder are dropped, so
  // the tiles are recreated and resolve their providers again
  int _thumbnailGeneration = 0;

  // Mosaic loupe magnifier
  bool _magnifying = false;
  final ValueNotifier<Offset> _magnifierPosition = ValueNotifier(Offset.zero);
  bool _justTerminatedAutoMotion = false;
  Timer? _magnifierTimer;
  Offset? _magnifierPointerDownPos;
  // a tap that only released the magnifier must not open the picture
  bool _suppressTap = false;
  ScrollHoldController? _magnifierHold;

  // immersive: hide the app bar while scrolling down
  bool _immersive = false;
  double _lastScrollPixels = 0;
  DateTime _lastScrollPersist = DateTime.fromMillisecondsSinceEpoch(0);

  // pinch to resize
  double _scaleStartColumns = 3;
  // live column count during a pinch, so the gesture does not write the stored
  // preference (and notify every listener) on every frame
  double? _liveColumns;

  // memoized sorting/layout: every rebuild (thumbnail aspect learning every
  // 200 ms, selection taps, immersive toggles) re-sorted the whole folder,
  // which is expensive for a folder with thousands of entries
  List<PurerEntry>? _sortedMediaSource;
  String _sortedMediaFilter = '';
  String _sortedMediaSort = '';
  List<PurerEntry> _sortedMediaCache = const [];
  List<CloudResource>? _sortedFolderSource;
  bool _sortedFolderDescending = false;
  List<CloudResource> _sortedFolderCache = const [];
  List<(List<int>, double)>? _mosaicRowsCache;
  String? _mosaicRowsKey;
  List<(List<int>, double)>? _mosaicColsCache;
  String? _mosaicColsKey;
  int _aspectsVersion = 0;

  // memoized video-only test: a folder with thousands of videos used to be
  // scanned on every rebuild and scroll event
  List<PurerEntry>? _videoModeSource;
  String _videoModeFilter = '';
  bool _videoModeCache = false;
  // memoized name-sorted siblings for the over-scroll hint and auto motion:
  // sorting the parent listing on every scroll tick was wasted work
  List<CloudResource>? _siblingSortSource;
  bool _siblingSortDescending = false;
  List<CloudResource> _siblingSortCache = const [];

  // mosaic aspect ratios (uri -> width / height), filled in the background
  final Map<String, double> _aspects = {};
  // uris of the current folder's videos that have a sprite sheet, so a tile
  // prefers the animation and skips extracting a frame that would just be hidden
  Set<String> _spriteUris = {};
  // sprite uris learned earlier in the session (from the mirror listing), so
  // going back to a cached folder shows its animations immediately instead of
  // waiting for another listing (or a pull-to-refresh)
  final Set<String> _knownSpriteUris = {};
  Timer? _aspectFlushTimer;
  Timer? _abandonTimer;

  String get _baseUrl => widget.server.url.endsWith('/') ? widget.server.url : '${widget.server.url}/';

  @override
  void initState() {
    super.initState();
    _currentUrl = _asFolderUrl(widget.initialUrl ?? _baseUrl);
    _trail = [..._ancestorsFor(_currentUrl), _currentUrl];
    _trailIndex = _trail.length - 1;
    _scrollController.addListener(_onScroll);
    _autoScrollTicker = createTicker(_onMosaicAutoScrollTick);
    _settingsSub = settings.updateStream.listen((event) {
      if (const [
        SettingKeys.cloudImageLayoutKey,
        SettingKeys.cloudVideoLayoutKey,
        SettingKeys.cloudFolderLayoutsKey,
        SettingKeys.cloudLayoutPerFolderKey,
        // the decode quality is part of the tile keys, so a change rebuilds
        // them and re-resolves their providers at the new cap
        SettingKeys.cloudThumbnailQualityKey,
        // sprite animation options change how the tiles animate
        SettingKeys.cloudSpriteAnimationEnabledKey,
        SettingKeys.cloudSpriteAnimationSpeedKey,
        SettingKeys.cloudSpriteAnimationOrderKey,
        SettingKeys.cloudSpriteStartPercentKey,
      ].contains(event.key)) {
        // No `isCurrent` guard: these options are changed from a modal sheet,
        // which makes the browser route non-current, so the change would only
        // apply at the next unrelated rebuild.
        if (mounted) setState(() {});
      } else if (event.key == SettingKeys.cloudSpritePlaybackZoneKey) {
        // the band the sheets may play in changed: tiles check it on their next
        // frame, they only need the new rect published
        WidgetsBinding.instance.addPostFrameCallback((_) => _updateSpritePlaybackBand());
        if (mounted) setState(() {});
      } else if (event.key == SettingKeys.cloudVideoPositionsKey) {
        // a duration probed while extracting a thumbnail arrived in the
        // background: refresh the badges (the video player writes this key too,
        // hence the visible-route guard)
        _sortedMediaSource = null; // a duration sort may now order differently
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
          setState(() {});
        }
      }
    });
    _fetch();
  }

  @override
  void dispose() {
    // the page is going away: stop downloading/generating the thumbnails of
    // this folder
    final leaving = _media.value.map((e) => e.uri).toList();
    abandonCloudImages(leaving);
    // no grace period on disposal: there is no accidental tap to protect
    _abandonTimer?.cancel();
    _abandonTimer = null;
    abandonCloudVideoThumbnails(leaving);
    // the band belongs to this page: without it every sprite would be allowed
    // to play again (or, worse, a stale band would pause them all)
    cloudSpritePlaybackBand.value = null;
    _settingsSub?.cancel();
    _aspectFlushTimer?.cancel();
    _overscrollTimer?.cancel();
    _autoScrollTicker.dispose();
    _cancelMosaicPageFlipTimer();
    _magnifierTimer?.cancel();
    _magnifierHold?.cancel();
    _magnifierHold = null;
    _magnifierPosition.dispose();
    _autoScrollingNotifier.dispose();
    _autoFlippingNotifier.dispose();
    // persist the progress gathered while browsing before the page goes away
    settings.flushCloudFolderStats();
    _rememberScrollPosition();
    settings.flushCloudFolderScrolls();
    _scrollController.dispose();
    _addressScrollController.dispose();
    _state.dispose();
    _error.dispose();
    _folders.dispose();
    _media.dispose();
    _nextFolderProgress.dispose();
    _nextFolder.dispose();
    super.dispose();
  }

  void _onMosaicPointerDown(PointerDownEvent event) {
    _pointerCount++;
    _userInteracting = true;
    // a new gesture starts here: the previous magnifier's tap is over
    _suppressTap = false;
    // only a decoded image tile of the mosaic can start the magnifier: folder
    // rows, blank space, the chrome and video tiles must not enlarge it
    final imageUri = _pointerImageUri;
    _pointerImageUri = null;
    if (_selectionMode || !settings.cloudMosaicMagnifierEnabled) return;
    if (imageUri == null || !_loadedImageUris.contains(imageUri)) return;
    if (_resolvedLayout(_media.value) != 'mosaic') return;
    _magnifierPointerDownPos = event.localPosition;
    _magnifierTimer?.cancel();
    _magnifierTimer = Timer(Duration(milliseconds: settings.cloudMosaicMagnifierDelay), () {
      if (!mounted) return;
      HapticFeedback.selectionClick();
      if (_scrollController.hasClients) {
        _magnifierHold?.cancel();
        _magnifierHold = _scrollController.position.hold(() {});
      }
      _magnifierPosition.value = event.localPosition;
      // releasing the magnifier must not open the picture
      _suppressTap = true;
      setState(() {
        _magnifying = true;
      });
    });
  }

  void _onMosaicPointerMove(PointerMoveEvent event) {
    if (_magnifierPointerDownPos != null && !_magnifying) {
      final dist = (event.localPosition - _magnifierPointerDownPos!).distance;
      if (dist > 18.0) {
        _magnifierTimer?.cancel();
        _magnifierTimer = null;
        _magnifierPointerDownPos = null;
      }
    }
    if (_magnifying) {
      _magnifierPosition.value = event.localPosition;
    }
  }

  void _onMosaicPointerUp(PointerEvent event) {
    final wasMagnifying = _magnifying;
    _magnifierTimer?.cancel();
    _magnifierTimer = null;
    final isTap = _magnifierPointerDownPos != null && (event.localPosition - _magnifierPointerDownPos!).distance < 20.0;
    _magnifierPointerDownPos = null;

    if (wasMagnifying) {
      setState(() {
        _magnifying = false;
      });
    }
    _magnifierHold?.cancel();
    _magnifierHold = null;

    _pointerCount = math.max(0, _pointerCount - 1);
    if (_pointerCount == 0) {
      _overscrollLocked = false;
      _userInteracting = false;
    }

    if (isTap && _stopMosaicAutoMotionIfRunning()) {
      _justTerminatedAutoMotion = true;
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) _justTerminatedAutoMotion = false;
      });
    }
  }

  bool _stopMosaicAutoMotionIfRunning() {
    if (_autoScrollingNotifier.value || _autoFlippingNotifier.value) {
      _autoScrollingNotifier.value = false;
      if (_autoScrollTicker.isActive) {
        _autoScrollTicker.stop();
      }
      _autoFlippingNotifier.value = false;
      _cancelMosaicPageFlipTimer();
      return true;
    }
    return false;
  }

  void _onMosaicAutoScrollTick(Duration elapsed) {
    if (!_autoScrollingNotifier.value || !_scrollController.hasClients) return;
    if (_userInteracting) {
      _lastAutoScrollTick = elapsed;
      return;
    }
    if (_lastAutoScrollTick == Duration.zero) {
      _lastAutoScrollTick = elapsed;
      return;
    }
    final dt = (elapsed - _lastAutoScrollTick).inMicroseconds / 1000000.0;
    _lastAutoScrollTick = elapsed;
    if (dt <= 0 || dt > 0.1) return;
    final speed = settings.cloudMosaicAutoScrollSpeed * 60.0;
    final max = _scrollController.position.maxScrollExtent;
    final current = _scrollController.offset;
    if (current >= max - 0.5) {
      unawaited(_onMosaicReachedEnd());
      return;
    }
    // still far from the end: no prefetch needed yet
    if (max - current < _scrollController.position.viewportDimension * 1.5) {
      unawaited(_prefetchNextFolder());
    }
    final next = (current + speed * dt).clamp(0.0, max);
    _scrollController.jumpTo(next);
  }

  void _toggleMosaicAutoScroll() {
    if (_autoFlippingNotifier.value) {
      _autoFlippingNotifier.value = false;
      _cancelMosaicPageFlipTimer();
    }
    final next = !_autoScrollingNotifier.value;
    _autoScrollingNotifier.value = next;
    if (next) {
      _lastAutoScrollTick = Duration.zero;
      if (!_autoScrollTicker.isActive) {
        _autoScrollTicker.start();
      }
      final speedLabel = cloudFormatFactor(settings.cloudMosaicAutoScrollSpeed);
      showFeedback(context, FeedbackType.info, '${context.l10n.cloudViewerAutoScroll} ($speedLabel)');
    } else {
      if (_autoScrollTicker.isActive) {
        _autoScrollTicker.stop();
      }
    }
  }

  void _toggleMosaicAutoPageFlip() {
    if (_autoScrollingNotifier.value) {
      _autoScrollingNotifier.value = false;
      if (_autoScrollTicker.isActive) {
        _autoScrollTicker.stop();
      }
    }
    final next = !_autoFlippingNotifier.value;
    _autoFlippingNotifier.value = next;
    if (next) {
      _scheduleNextMosaicPageFlip();
      final secStr = cloudFormatInterval(settings.cloudMosaicAutoPageFlipInterval);
      final distPercent = (settings.cloudMosaicAutoPageFlipDistance * 100).round();
      showFeedback(context, FeedbackType.info, '${context.l10n.cloudViewerAutoPageFlip} ($secStr / $distPercent%)');
    } else {
      _cancelMosaicPageFlipTimer();
    }
  }

  void _scheduleNextMosaicPageFlip() {
    _cancelMosaicPageFlipTimer();
    if (!mounted || !_autoFlippingNotifier.value) return;
    final intervalMs = (settings.cloudMosaicAutoPageFlipInterval * 1000).round();
    _mosaicFlipTimer = Timer(Duration(milliseconds: math.max(300, intervalMs)), _doMosaicPageFlip);
  }

  void _cancelMosaicPageFlipTimer() {
    _mosaicFlipTimer?.cancel();
    _mosaicFlipTimer = null;
  }

  void _doMosaicPageFlip() {
    if (!mounted || !_autoFlippingNotifier.value) return;
    if (_userInteracting) {
      _mosaicFlipTimer = Timer(const Duration(milliseconds: 400), _doMosaicPageFlip);
      return;
    }
    if (!_scrollController.hasClients) {
      _scheduleNextMosaicPageFlip();
      return;
    }
    final max = _scrollController.position.maxScrollExtent;
    final current = _scrollController.offset;
    if (current >= max - 1.0) {
      unawaited(_onMosaicReachedEnd());
      return;
    }
    final isVertical = settings.cloudMosaicScrollDirection == 'vertical';
    final viewportDimension = isVertical ? MediaQuery.sizeOf(context).height : MediaQuery.sizeOf(context).width;
    final delta = viewportDimension * settings.cloudMosaicAutoPageFlipDistance;
    // the flip animation does not produce scroll ticks, so the next folder has
    // to be prefetched from here while the end is still a screen away
    if (max - current < viewportDimension * 1.5) {
      unawaited(_prefetchNextFolder());
    }
    final target = (current + delta).clamp(0.0, max);
    if ((target - current).abs() < 1.0) {
      unawaited(_onMosaicReachedEnd());
      return;
    }
    _scrollController
        .animateTo(
          target,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOutCubic,
        )
        .then((_) {
          _scheduleNextMosaicPageFlip();
        })
        .catchError((_) {
          _scheduleNextMosaicPageFlip();
        });
  }

  Future<void> _onMosaicReachedEnd() async {
    if (_advancingToNextFolder) return;
    if (DateTime.now().isBefore(_endGuardUntil)) return;
    _advancingToNextFolder = true;
    try {
      final next = _nextFolderInParent();
      if (next == null) {
        _autoScrollingNotifier.value = false;
        _autoFlippingNotifier.value = false;
        _cancelMosaicPageFlipTimer();
        return;
      }
      // the scroll is already at the end: wait (briefly) for the prefetch
      // rather than switching to a folder whose listing is still unknown
      if (!_folderSnapshots.containsKey(next.url)) {
        await _prefetchNextFolder().timeout(const Duration(seconds: 10), onTimeout: () {});
      }
      if (!mounted) return;
      _navigateTo(next.url, lateral: true, keepAutoMotion: true);
    } finally {
      _advancingToNextFolder = false;
    }
  }

  void _onScroll() {
    // near the end of a mosaic, fetch the parent listing so the over-scroll
    // gesture can name the next folder. Done here (not when the folder opens)
    // so it cannot delay browsing or the next folder's listing.
    if (_scrollController.hasClients) {
      final position = _scrollController.position;
      if (position.extentAfter < position.viewportDimension * 1.5) {
        _primeSiblings();
        // the auto motion is heading for the end: have the next folder ready
        if (_autoScrollingNotifier.value || _autoFlippingNotifier.value) {
          unawaited(_prefetchNextFolder());
        }
      }
      // save the position while scrolling (at most once a second), so it is
      // not lost if the app is killed instead of navigating away
      final now = DateTime.now();
      if (now.difference(_lastScrollPersist) >= const Duration(seconds: 1)) {
        _lastScrollPersist = now;
        settings.setCloudFolderScroll(_currentUrl, position.pixels);
      }
      _updateSpritePlaybackBand();
    }

    if (!settings.cloudImmersive) {
      if (_immersive) setState(() => _immersive = false);
      return;
    }
    // only the horizontal mosaic collapses its fixed bar: the vertical layouts
    // use a floating SliverAppBar, which hides itself and does not need the
    // extra whole-page rebuild on every direction change
    if (_resolvedLayout(_media.value) != 'mosaic' || settings.cloudMosaicScrollDirection != 'horizontal') {
      if (_immersive) setState(() => _immersive = false);
      return;
    }
    if (!_scrollController.hasClients) return;

    final pixels = _scrollController.position.pixels;
    final delta = pixels - _lastScrollPixels;
    _lastScrollPixels = pixels;
    // scrolling up reveals the app bar, scrolling down hides it
    final shouldBeImmersive = delta > 0 ? (_immersive || pixels > 24) : false;
    if (shouldBeImmersive != _immersive) {
      setState(() => _immersive = shouldBeImmersive);
    }
  }

  // Publishes the screen band in which sprite animations play. The band is
  // centred on the visible list and its thickness is the user's percentage;
  // at the start/end of the list it stretches to the list edge (up to the
  // centre), because the first/last rows can never move near the centre.
  // `null` means no restriction (100%).
  void _updateSpritePlaybackBand() {
    if (!mounted) return;
    final zone = settings.cloudSpritePlaybackZone;
    void publish(Rect? band) {
      if (cloudSpritePlaybackBand.value != band) cloudSpritePlaybackBand.value = band;
    }

    if (zone >= 100 || !settings.cloudSpriteAnimationEnabled) {
      publish(null);
      return;
    }
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final renderObject = position.context.storageContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached || !renderObject.hasSize) return;
    final viewport = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    final horizontal = _resolvedLayout(_media.value) == 'mosaic' && settings.cloudMosaicScrollDirection == 'horizontal';
    final thickness = (horizontal ? viewport.width : viewport.height) * zone / 100;
    final center = horizontal ? viewport.center.dx : viewport.center.dy;
    var start = center - thickness / 2;
    var end = center + thickness / 2;
    if (position.pixels <= 0.5) {
      start = horizontal ? viewport.left : viewport.top;
    }
    if (position.extentAfter <= 0.5) {
      end = horizontal ? viewport.right : viewport.bottom;
    }
    publish(
      horizontal ? Rect.fromLTRB(start, viewport.top, end, viewport.bottom) : Rect.fromLTRB(viewport.left, start, viewport.right, end),
    );
  }

  String get _folderName {
    final crumbs = _breadcrumbs(_currentUrl);
    return crumbs.isNotEmpty ? crumbs.last.$1 : context.l10n.webdavRoot;
  }

  List<String> _ancestorsFor(String url) {
    final base = _baseUrl;
    if (url == base || !url.startsWith(base)) return [];
    final segments = url.substring(base.length).split('/').where((s) => s.isNotEmpty).toList();
    final ancestors = <String>[base];
    var acc = base;
    for (var i = 0; i < segments.length - 1; i++) {
      acc = '$acc${segments[i]}/';
      ancestors.add(acc);
    }
    return ancestors;
  }

  List<(String, String)> _breadcrumbs(String url) {
    final base = _baseUrl;
    final crumbs = <(String, String)>[];
    if (url.startsWith(base)) {
      final segments = url.substring(base.length).split('/').where((s) => s.isNotEmpty).toList();
      var acc = base;
      for (var i = 0; i < segments.length; i++) {
        acc = '$acc${segments[i]}/';
        crumbs.add((decodeCloudSegment(segments[i]), i == segments.length - 1 ? url : acc));
      }
    }
    return crumbs;
  }

  // deepest folder reached on this branch. The trail keeps the entries the user
  // went back from, so the address bar can offer them without re-listing.
  String get _deepestTrailUrl {
    var deepest = _currentUrl;
    for (var i = _trailIndex + 1; i < _trail.length; i++) {
      final url = _trail[i];
      if (url != _currentUrl && url.startsWith(_currentUrl) && url.length > deepest.length) {
        deepest = url;
      }
    }
    return deepest;
  }

  static String _trimFolderUrl(String url) => url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  // collection URLs from a server may or may not end with a slash; keep ours
  // canonical so cache keys and progress entries always match
  static String _asFolderUrl(String url) => url.endsWith('/') ? url : '$url/';

  static bool _sameFolder(String a, String b) => _trimFolderUrl(a) == _trimFolderUrl(b);

  String? _parentOf(String url) {
    final current = _trimFolderUrl(url);
    final base = _trimFolderUrl(_baseUrl);
    if (current == base || !current.startsWith(base)) return null;
    final last = current.lastIndexOf('/');
    if (last < 0) return null;
    final parent = current.substring(0, last + 1);
    return parent.length > base.length ? parent : null;
  }

  // persisted per folder, so the position survives leaving the browser and
  // restarting the app
  void _rememberScrollPosition() {
    if (_scrollController.hasClients) {
      settings.setCloudFolderScroll(_currentUrl, _scrollController.offset);
    }
  }

  // Hands the folder's saved offset to a fresh scroll controller, and bumps the
  // generation so the next build recreates the scroll position at that offset.
  // Jumping after the first frame instead showed the folder at the top and then
  // snapped to the position, which the user found jarring.
  void _bindScrollController(String url) {
    if (_scrollBoundUrl == url) return;
    _scrollBoundUrl = url;
    final target = _startAtTop ? 0.0 : (settings.cloudFolderScroll(url) ?? 0);
    final previous = _scrollController;
    previous.removeListener(_onScroll);
    _scrollController = ScrollController(initialScrollOffset: target <= 0 ? 0 : target);
    _scrollController.addListener(_onScroll);
    _scrollGeneration++;
    _lastScrollPixels = target <= 0 ? 0 : target;
    // the frame that follows rebuilds the scroll view with the new key, which
    // detaches and disposes the previous position: the old controller can go
    // once that happened
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    // make sure the new key is taken into account even if the content itself
    // happens to be unchanged
    if (mounted) setState(() {});
  }

  // the saved offset is already applied when the position is created, so this
  // only covers the case where the layout settled somewhere else (e.g. a very
  // rough extent estimate on the first pass)
  void _verifyScrollOffset(String url) {
    final target = settings.cloudFolderScroll(url) ?? 0;
    if (target <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || url != _currentUrl || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      // the content is shorter than remembered: stay where the layout put us
      if (target > position.maxScrollExtent) return;
      if ((position.pixels - target).abs() > 0.5) {
        _scrollController.jumpTo(target);
        _lastScrollPixels = target;
      }
    });
  }

  // `lateral` marks a move to a sibling folder (the over-scroll gesture): it is
  // not a level deeper, so going back returns to the folder list instead of the
  // sibling that happened to be shown before.
  // `keepAutoMotion` is only set by the auto motion itself: the next folder is
  // then browsed with the same mode, from its top, instead of stopping.
  void _navigateTo(String rawUrl, {bool lateral = false, bool keepAutoMotion = false}) {
    final url = _asFolderUrl(rawUrl);
    if (_sameFolder(url, _currentUrl)) return;
    // a folder change ends a batch selection: otherwise entries selected in
    // the previous folder would stay selected and could be deleted from here
    _clearSelection();
    if (keepAutoMotion) {
      _startAtTop = true;
      _lastAutoScrollTick = Duration.zero;
    } else {
      _autoScrollingNotifier.value = false;
      if (_autoScrollTicker.isActive) _autoScrollTicker.stop();
      _cancelMosaicPageFlipTimer();
      _autoFlippingNotifier.value = false;
    }
    // stop the transfers and extractions of the folder being left: they would
    // otherwise compete with the listing of the folder being opened
    final leaving = _media.value.map((e) => e.uri).toList();
    abandonCloudImages(leaving);
    _abandonThumbnailsSoon(leaving);
    _rememberScrollPosition();
    _resetOverscroll();
    final existing = lateral ? -1 : _trail.indexWhere((v) => _sameFolder(v, url));
    if (existing >= 0) {
      // already visited: reuse the cached listing instead of fetching it again
      _trailIndex = existing;
    } else if (lateral) {
      // replace the current stop instead of stacking on it
      _trail = [..._trail.take(_trailIndex), url];
      _trailIndex = _trail.length - 1;
    } else {
      // a genuinely new path: drop the forward entries and fetch once
      _trail = [..._trail.take(_trailIndex + 1), url];
      _trailIndex = _trail.length - 1;
    }
    // progress is recorded once the listing succeeds, never before the request
    setState(() {
      _currentUrl = url;
      _immersive = false;
    });
    _showFolder(url);
  }

  // moves back through the trail without dropping its forward entries, so the
  // address bar can still show (and return to) the folder we came from
  void _goBack() {
    if (_trailIndex <= 0) return;
    // going up also ends a batch selection, see `_navigateTo`
    _clearSelection();
    _rememberScrollPosition();
    final leaving = _media.value.map((e) => e.uri).toList();
    abandonCloudImages(leaving);
    _abandonThumbnailsSoon(leaving);
    _resetOverscroll();
    _trailIndex--;
    setState(() {
      _currentUrl = _trail[_trailIndex];
      _immersive = false;
    });
    _showFolder(_currentUrl);
  }

  void _showFolder(String url) {
    final snapshot = _folderSnapshots[url];
    if (snapshot == null) {
      _fetch();
      return;
    }
    _bindScrollController(url);
    _state.value = _LoadState.ready;
    _folders.value = snapshot.folders;
    _media.value = snapshot.media;
    // restore the sprite availability remembered earlier in the session, then
    // refresh it from the mirror listing: a cached listing never goes through
    // `_fetch`, which used to leave this folder's animations unplayable until
    // a pull-to-refresh cleared it
    final known = <String>{
      for (final entry in snapshot.media)
        if (_knownSpriteUris.contains(entry.uri)) entry.uri,
    };
    if (known.length != _spriteUris.length || !known.containsAll(_spriteUris)) {
      setState(() => _spriteUris = known);
    } else {
      _spriteUris = known;
    }
    unawaited(_applyFolderCache(url, snapshot.media));
    // re-insert so a folder that is revisited often is not the first evicted
    _rememberSnapshot(url, snapshot);
    if (!_startAtTop) _verifyScrollOffset(url);
    _startAtTop = false;
    _revealCurrentCrumb();
    _recordListing(url, snapshot);
    _endGuardUntil = DateTime.now().add(const Duration(milliseconds: 700));
    _resumeAutoMotion();
  }

  // keep the current segment visible even when the bar still shows the deeper
  // folders we went back from
  void _revealCurrentCrumb() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final crumbContext = _currentCrumbKey.currentContext;
      final viewportContext = _addressViewportKey.currentContext;
      if (crumbContext == null || viewportContext == null || !_addressScrollController.hasClients) return;
      final crumbBox = crumbContext.findRenderObject() as RenderBox?;
      final viewportBox = viewportContext.findRenderObject() as RenderBox?;
      if (crumbBox == null || viewportBox == null || !crumbBox.hasSize || !viewportBox.hasSize) return;
      // centre the current segment without touching the vertical scroll view
      final offset = crumbBox.localToGlobal(Offset.zero, ancestor: viewportBox).dx;
      final target = _addressScrollController.offset + offset - (viewportBox.size.width - crumbBox.size.width) / 2;
      _addressScrollController.jumpTo(target.clamp(0.0, _addressScrollController.position.maxScrollExtent));
    });
  }

  // in mosaic the layout depends on knowing the folder contents; keep the
  // sibling list around so the over-scroll gesture can name the next folder
  // returns the in-flight request, so a caller that needs the sibling list
  // (the prefetch) can wait for it instead of polling
  Future<void>? _primeSiblings() {
    // cheapest checks first: this runs on every scroll tick near the bottom
    if (_state.value != _LoadState.ready) return null;
    final parent = _parentOf(_currentUrl);
    if (parent == null || _folderLists.containsKey(parent)) return null;
    // only the mosaic layout uses the gesture, and only once its own listing
    // has arrived: do not compete with the request we are waiting for
    if (_resolvedLayout(_media.value) != 'mosaic') return null;
    if (!_primingParents.add(parent)) return null;
    final retryAfter = _siblingRetryAfter[parent];
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) {
      _primingParents.remove(parent);
      return null;
    }
    final future = _fetchSiblings(parent);
    unawaited(future);
    return future;
  }

  // The viewer offers the next album/folder, which needs the parent listing.
  // `_primeSiblings` is mosaic-only (scroll hint), so a deep link or a grid
  // layout never primes it.
  void _primeSiblingsForViewer() {
    final parent = _parentOf(_currentUrl);
    if (parent == null || _folderLists.containsKey(parent)) return;
    final retryAfter = _siblingRetryAfter[parent];
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) return;
    if (!_primingParents.add(parent)) return;
    unawaited(_fetchSiblings(parent));
  }

  void _rememberFolderList(String parent, List<CloudResource> folders) {
    _folderLists.remove(parent);
    _folderLists[parent] = folders;
    while (_folderLists.length > _maxFolderLists) {
      _folderLists.remove(_folderLists.keys.first);
    }
  }

  void _rememberSnapshot(String url, _FolderSnapshot snapshot) {
    final previous = _folderSnapshots.remove(url);
    if (previous != null) {
      _snapshotEntryCount -= previous.folders.length + previous.media.length;
    }
    _folderSnapshots[url] = snapshot;
    _snapshotEntryCount += snapshot.folders.length + snapshot.media.length;
    while (_folderSnapshots.length > _maxFolderSnapshots || (_snapshotEntryCount > _maxSnapshotEntries && _folderSnapshots.length > 1)) {
      final firstKey = _folderSnapshots.keys.first;
      final removed = _folderSnapshots.remove(firstKey);
      if (removed != null) {
        _snapshotEntryCount -= removed.folders.length + removed.media.length;
        _forgetSnapshotKeys(removed);
      }
    }
    _rememberFolderList(url, snapshot.folders);
  }

  static void _forgetSnapshotKeys(_FolderSnapshot snapshot) {
    for (final entry in snapshot.media) {
      EntryCache.forget(entry.uri);
    }
  }

  Future<void> _fetchSiblings(String parent) async {
    try {
      final client = cloudRegistry.clientForServer(widget.server);
      if (client == null) return;
      final resources = await client.list(parent);
      if (!mounted) return;
      _rememberFolderList(parent, resources.where((r) => r.isCollection).toList());
      _siblingRetryAfter.remove(parent);
    } catch (_) {
      // best effort: without the parent listing over-scroll navigation is
      // simply unavailable for this folder. Do not retry on every scroll tick.
      _siblingRetryAfter[parent] = DateTime.now().add(const Duration(seconds: 30));
      if (_siblingRetryAfter.length > 200) _siblingRetryAfter.remove(_siblingRetryAfter.keys.first);
    } finally {
      _primingParents.remove(parent);
    }
  }

  CloudResource? _nextFolderInParent([String? url]) {
    final targetUrl = url ?? _currentUrl;
    final parent = _parentOf(targetUrl);
    if (parent == null) return null;
    final folders = _folderLists[parent];
    if (folders == null || folders.length < 2) return null;
    final sorted = _sortedSiblingsFor(folders, descending: settings.cloudSort == 'nameDesc');
    final index = sorted.indexWhere((f) => _sameFolder(f.url, targetUrl));
    if (index < 0) return null;
    // completed folders are skipped when the user chose to hide them
    final hideCompleted = settings.cloudHideCompletedFolders;
    for (var i = index + 1; i < sorted.length; i++) {
      final folder = sorted[i];
      if (hideCompleted && settings.cloudFolderProgressComplete(folder.url)) continue;
      return folder;
    }
    return null;
  }

  List<CloudResource> _sortedSiblingsFor(List<CloudResource> folders, {required bool descending}) {
    if (identical(_siblingSortSource, folders) && _siblingSortDescending == descending) return _siblingSortCache;
    _siblingSortSource = folders;
    _siblingSortDescending = descending;
    _siblingSortCache = sortCloudResourcesByName(folders, descending: descending);
    return _siblingSortCache;
  }

  Future<List<PurerEntry>> _loadFolderImages(String url) async {
    final client = cloudRegistry.clientForServer(widget.server);
    if (client == null) return [];
    try {
      final resources = await client.list(url);
      final media = <PurerEntry>[];
      var index = 0;
      for (final resource in resources.where((r) => !r.isCollection)) {
        final mime = _mimeForResource(resource);
        if (!MimeTypes.isImage(mime)) continue;
        media.add(cloudEntryFromResource(resource, mimeType: mime, id: -1 - index));
        index++;
      }
      return _sortEntries(media, settings.cloudSort);
    } catch (_) {
      return [];
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollUpdateNotification) {
      _updateSpritePlaybackBand();
    }
    if (notification is ScrollEndNotification) {
      _overscrollLocked = false;
    }
    if (notification is UserScrollNotification && notification.direction == ScrollDirection.idle) {
      _overscrollLocked = false;
    }
    final mosaicDir = (settings.cloudMosaicScrollDirection == 'horizontal') ? Axis.horizontal : Axis.vertical;
    if (notification is OverscrollNotification && notification.metrics.axis == mosaicDir) {
      if (_overscrollLocked) return false;
      if (_resolvedLayout(_media.value) != 'mosaic') return false;
      // a folder of subfolders (or of videos only) is not a picture stream:
      // there is nothing to swipe through, so the gesture must not switch to
      // the next folder
      if (!_media.value.any((e) => e.isImage)) return false;
      if (notification.metrics.extentAfter > 0 || notification.overscroll <= 0) return false;
      final next = _nextFolderInParent();
      if (next == null) {
        // the parent listing is not known yet: fetch it, the next attempt will
        // be able to show the hint
        _primeSiblings();
        return false;
      }
      _nextFolder.value = next;
      _overscrollThreshold = (mosaicDir == Axis.vertical ? MediaQuery.sizeOf(context).height : MediaQuery.sizeOf(context).width) / 3;
      _overscroll += notification.overscroll;
      _nextFolderProgress.value = (_overscroll / _overscrollThreshold).clamp(0.0, 1.0);
      _overscrollTimer?.cancel();
      _overscrollTimer = Timer(const Duration(milliseconds: 700), _resetOverscroll);
      if (_overscroll >= _overscrollThreshold) {
        _resetOverscroll();
        _overscrollLocked = true;
        HapticFeedback.mediumImpact();
        _navigateTo(next.url, lateral: true);
      }
      return false;
    }
    if (notification is ScrollUpdateNotification && notification.metrics.extentAfter > 0) {
      // only touch the notifiers when a hint is actually showing
      if (_overscroll != 0 || _nextFolder.value != null) {
        _resetOverscroll();
      }
    }
    return false;
  }

  void _resetOverscroll() {
    _overscrollTimer?.cancel();
    _overscrollTimer = null;
    _overscroll = 0;
    _nextFolderProgress.value = 0;
    _nextFolder.value = null;
  }

  _FolderSnapshot _snapshotFrom(List<CloudResource> resources, {Map<String, PurerEntry> previous = const {}}) {
    final folders = resources.where((r) => r.isCollection).toList();
    final media = <PurerEntry>[];
    var index = 0;
    for (final resource in resources.where((r) => !r.isCollection)) {
      final mime = _mimeForResource(resource);
      if (!MimeTypes.isImage(mime) && !MimeTypes.isVideo(mime)) continue;
      media.add(previous[resource.url] ?? cloudEntryFromResource(resource, mimeType: mime, id: -1 - index));
      index++;
    }
    return _FolderSnapshot(folders, media);
  }

  // folders opened from a cached listing never go through `_fetch`, so their
  // progress bookkeeping happens here too
  void _recordListing(String url, _FolderSnapshot snapshot) {
    final imageCount = snapshot.media.where((e) => e.isImage).length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      settings.recordCloudFolder(url, imageCount: imageCount, folderCount: snapshot.folders.length);
      settings.markCloudFolderVisited(url);
    });
  }

  // auto motion keeps running after a lateral switch: restart its scheduler
  // on the new folder, which is shown from its top
  void _resumeAutoMotion() {
    if (!_autoScrollingNotifier.value && !_autoFlippingNotifier.value) return;
    _lastAutoScrollTick = Duration.zero;
    if (_autoScrollingNotifier.value && !_autoScrollTicker.isActive) {
      _autoScrollTicker.start();
    }
    if (_autoFlippingNotifier.value) {
      _scheduleNextMosaicPageFlip();
    }
  }

  // Lists the sibling the auto motion is heading to, plus the payload of its
  // first screen, before the scroll actually reaches the end. Without it the
  // switch waits for a listing and shows a screen of blurry placeholders.
  Future<void> _prefetchNextFolder() async {
    if (_state.value != _LoadState.ready) return;
    var next = _nextFolderInParent();
    if (next == null) {
      // the parent listing may still be on its way
      final priming = _primeSiblings();
      if (priming != null) await priming;
      if (!mounted) return;
      next = _nextFolderInParent();
    }
    if (next == null) return;
    final url = next.url;
    if (_folderSnapshots.containsKey(url)) return;
    final inFlight = _prefetchFutures[url];
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final future = _prefetchFolder(url);
    _prefetchFutures[url] = future;
    try {
      await future;
    } finally {
      // the request handles its own errors, so the returned future is inert
      _prefetchFutures.remove(url)?.ignore();
    }
  }

  Future<void> _prefetchFolder(String url) async {
    try {
      final client = cloudRegistry.clientForServer(widget.server);
      if (client == null) return;
      final resources = await client.list(url);
      if (!mounted) return;
      final snapshot = _snapshotFrom(resources);
      _rememberSnapshot(url, snapshot);
      unawaited(_prefetchFirstScreen(snapshot.media));
    } catch (_) {
      // best effort: the switch falls back to a normal listing
    }
  }

  // warms the disk cache for the first screen of the next folder, so its tiles
  // decode from local bytes instead of waiting on the server
  Future<void> _prefetchFirstScreen(List<PurerEntry> media) async {
    // thumbnails are turned off: the next folder's tiles download nothing, so
    // warming the cache would spend traffic for pictures never shown
    if (!settings.cloudShowThumbnails) return;
    final count = (settings.cloudColumns.round() * 2).clamp(3, 8);
    final images = media.where((e) => e.isImage);
    for (final entry in images.take(count)) {
      if (!mounted) return;
      if (!entry.isDecodingSupported) continue;
      if (_loadedImageUris.contains(entry.uri)) continue;
      try {
        await cloudImageLoader.bytesFor(entry.uri);
      } catch (_) {
        // a file that cannot be fetched is skipped, not retried here
      }
    }
  }

  // `keepContent` is used by pull-to-refresh: the current tiles stay visible
  // (and keep their entries, so video frames are not requested again) until the
  // fresh listing replaces them
  Future<void> _fetch({bool keepContent = false}) async {
    final url = _currentUrl;
    if (!keepContent) {
      _state.value = _LoadState.loading;
      _folders.value = [];
      _media.value = [];
      // sprite availability belongs to the folder being left
      _spriteUris = {};
    }
    try {
      final client = cloudRegistry.clientForServer(widget.server);
      if (client == null) {
        throw StateError('找不到该服务');
      }
      final resources = await client.list(url);
      if (!mounted || url != _currentUrl) return;

      final previous = keepContent ? {for (final entry in _media.value) entry.uri: entry} : const <String, PurerEntry>{};
      final snapshot = _snapshotFrom(resources, previous: previous);
      final folders = snapshot.folders;
      final media = snapshot.media;

      _rememberSnapshot(url, snapshot);
      // bind before the values, so the frame that shows the content is already
      // laid out at the saved offset (a refresh keeps the current position)
      if (!keepContent) _bindScrollController(url);
      _folders.value = folders;
      _media.value = media;
      _state.value = _LoadState.ready;
      // durations learned by a previous scrape (on this or another device):
      // the mirrored cache folder is listed once instead of probing each video
      unawaited(_applyFolderCache(url, media));

      if (!keepContent && !_startAtTop) {
        _verifyScrollOffset(url);
      }
      _startAtTop = false;
      _revealCurrentCrumb();
      _endGuardUntil = DateTime.now().add(const Duration(milliseconds: 700));
      _resumeAutoMotion();

      // the grid is on screen first: progress persistence and the "last
      // location" write must not sit between the listing response and the frame,
      // and must never run before the request (a slow store would delay it)
      final imageCount = media.where((e) => e.isImage).length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        settings.recordCloudFolder(url, imageCount: imageCount, folderCount: folders.length);
        settings.markCloudFolderVisited(url);
        if (mounted && url == _currentUrl) {
          if (settings.cloudLastServerId != widget.server.id || settings.cloudLastUrl != url) {
            settings.setCloudLastLocation(widget.server.id, url);
          }
        }
      });
    } catch (error) {
      if (!mounted || url != _currentUrl) return;
      if (keepContent) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(cloudErrorText(error))));
        return;
      }
      _error.value = cloudErrorText(error);
      _state.value = _LoadState.error;
    }
  }

  // the aspect ratio is learned from each thumbnail that loads (see
  // `_onTileImageInfo`). Probing every file with a separate Range request used
  // to flood rate limited servers and delay the next folder's listing.
  void _scheduleAspectFlush() {
    // grid and list layouts do not use aspect ratios when laying out, so
    // learning one only needs a rebuild when dimensions are displayed
    if (_resolvedLayout(_media.value) != 'mosaic' && !settings.cloudShowDimensions) return;
    // thumbnails arrive in bursts while scrolling: refresh once they settle
    // instead of rebuilding the whole page several times per second
    _aspectFlushTimer ??= Timer(const Duration(milliseconds: 350), () {
      _aspectFlushTimer = null;
      if (mounted) setState(() {});
    });
  }

  // records the real aspect ratio of a video, taken from its extracted frame,
  // so the mosaic layout does not have to fall back to 16/9
  void _onTileAspect(String uri, double aspect) {
    if (!mounted || !aspect.isFinite || aspect <= 0) return;
    final current = _aspects[uri];
    if (current != null && (current - aspect).abs() / current < 0.02) return;
    if (current == null && _aspects.length >= _maxCachedAspects) {
      // bound the memo of a long session: drop the oldest learned ratios (the
      // folders they belong to are no longer on screen)
      for (final key in _aspects.keys.take(_aspects.length - _maxCachedAspects + 2000).toList()) {
        _aspects.remove(key);
      }
    }
    _aspects[uri] = aspect;
    _aspectsVersion++;
    _scheduleAspectFlush();
  }

  // merges the durations read from the mirrored cache folder into the local
  // store, so the duration badges show without probing each video. The file
  // name carries the duration, hence a single listing is enough.
  Future<void> _applyFolderCache(String url, List<PurerEntry> media) async {
    if (!cloudMediaCache.isReady || media.isEmpty) return;
    // the mirror only holds video frames: an image-only folder would cost a
    // needless PROPFIND for nothing
    if (!media.any((e) => e.isVideo)) return;
    final listing = await cloudMediaCache.listing(url);
    if (!mounted || url != _currentUrl) return;
    final durations = <String, int>{};
    final spriteVideos = <String>[];
    final spriteOnly = <String>[];
    for (final entry in media) {
      if (!entry.isVideo) continue;
      final name = CloudMediaCache.nameFor(entry.uri);
      final sprite = listing.sprites[name];
      // a sprite sheet's file name also carries the duration
      final duration = listing.frames[name]?.durationMillis ?? sprite?.durationMillis;
      if (duration != null && duration > 0 && settings.cloudVideoDuration(entry.uri) == null) {
        durations[entry.uri] = duration;
      }
      if (sprite != null) {
        spriteVideos.add(entry.uri);
        if (listing.frames[name] == null) spriteOnly.add(entry.uri);
      }
    }
    if (durations.isNotEmpty) settings.mergeCloudVideoDurations(durations);
    // sprite animation enabled: prefetch the sheets so every video that has one
    // shows the animation (and only the videos without a sheet keep the frame).
    // Disabled: nothing is downloaded (a sheet could not be shown anyway).
    // remember which videos have a sheet so their tiles animate (and skip the
    // otherwise wasted frame extraction); rebuild so tiles pick this up
    final hasSprite = spriteVideos.toSet();
    _knownSpriteUris.addAll(hasSprite);
    if (_knownSpriteUris.length > 20000) {
      _knownSpriteUris.removeAll(_knownSpriteUris.take(10000).toList());
    }
    if (hasSprite.length != _spriteUris.length || !hasSprite.containsAll(_spriteUris)) {
      setState(() => _spriteUris = hasSprite);
    } else {
      _spriteUris = hasSprite;
    }
    final toLoad = settings.cloudSpriteAnimationEnabled ? spriteVideos : const <String>[];
    if (toLoad.isNotEmpty) {
      // only the first screen is fetched ahead: downloading every sheet of a
      // video-heavy folder competed with the thumbnails the user is looking at.
      // The other tiles fetch their sheet when they are built (scrolled to).
      final ahead = (settings.cloudColumns.round() * 3).clamp(6, 24);
      unawaited(_animateSpritesInBackground(url, toLoad.take(ahead).toList()));
    }
    purerLog.debug(PurerLogCategory.cache, '应用缩略图缓存 ${PurerLog.redactUrl(url)} durations=${durations.length} sprite=${spriteVideos.length} spriteOnly=${spriteOnly.length}');
  }

  // Downloads the sprite sheets for the given videos in the background, several
  // at a time and without a dialog. Called for the videos that have a sheet (to
  // prefer them) or, when the option is off, just the sprite-only videos (which
  // would otherwise show an empty placeholder).
  Future<void> _animateSpritesInBackground(String folderUrl, List<String> uris) async {
    final service = mediaFetchService;
    if (service is! CloudAwareMediaFetchService) return;
    await service.animateSpriteThumbnailsForFolder(folderUrl, uris);
  }

  // drops the cached thumbnails of the entries of the current folder (the
  // persisted payloads and the in-memory image keys), so they are fetched again
  Future<void> _rebuildThumbnails() async {
    final entries = _media.value;
    if (entries.isEmpty || !mounted) return;
    final progress = ValueNotifier<(int, int)>((0, entries.length));
    final cancelled = ValueNotifier(false);
    BuildContext? dialogContext;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          dialogContext = context;
          return _TaskProgressDialog(
            title: context.l10n.cloudRebuildThumbnails,
            progress: progress,
            cancelled: cancelled,
          );
        },
      ),
    );
    // let the dialog build before the task runs: a very fast task could
    // otherwise finish before its context is set and leave the dialog open
    await WidgetsBinding.instance.endOfFrame;
    var done = 0;
    for (final entry in entries) {
      if (cancelled.value) break;
      await evictCloudThumbnailLocal(entry);
      done++;
      progress.value = (done, entries.length);
    }
    final wasCancelled = cancelled.value;
    // one listing per folder instead of one per video
    if (!wasCancelled) await evictCloudThumbnailsShared(entries);
    final ctx = dialogContext;
    if (ctx != null && ctx.mounted) Navigator.of(ctx).pop();
    if (!mounted) return;
    // aspect ratios were derived from the discarded images, and the tiles must
    // be recreated to resolve their providers again
    _aspects.clear();
    _aspectsVersion++;
    _thumbnailGeneration++;
    setState(() {});
    _showMessage(
      wasCancelled ? context.l10n.cloudTaskCancelled(done, entries.length) : context.l10n.cloudRebuildDone(done),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm({required String title, required String message}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.webdavActionCancel)),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(title),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  void _startSelectionMode([PurerEntry? initialEntry]) {
    setState(() {
      _selectionMode = true;
      _selectedEntries.clear();
      if (initialEntry != null) {
        _selectedEntries.add(initialEntry);
      }
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedEntries.clear();
    });
  }

  // called while navigating: the surrounding setState renders it
  void _clearSelection() {
    if (!_selectionMode && _selectedEntries.isEmpty) return;
    _selectionMode = false;
    _selectedEntries.clear();
  }

  void _toggleSelectEntry(PurerEntry entry) {
    setState(() {
      if (_selectedEntries.contains(entry)) {
        _selectedEntries.remove(entry);
      } else {
        _selectedEntries.add(entry);
      }
    });
  }

  // entries actually shown with the current media filter: select-all must not
  // reach files hidden by the filter, which would otherwise be deleted unseen
  List<PurerEntry> get _visibleMedia => _sortedMediaFor(_media.value, settings.cloudMediaFilter, settings.cloudSort);

  void _toggleSelectAll() {
    final visible = _visibleMedia;
    if (visible.isEmpty) return;
    setState(() {
      if (visible.every(_selectedEntries.contains)) {
        _selectedEntries.clear();
      } else {
        _selectedEntries.addAll(visible);
      }
    });
  }

  // long press selects an entry in the layouts where it is not taken by the
  // loupe magnifier (grid / list), like a regular gallery
  void _onEntryLongPress(PurerEntry entry) {
    if (_selectionMode) {
      _toggleSelectEntry(entry);
    } else {
      _startSelectionMode(entry);
    }
  }

  // copies one absolute URL per line, ready to paste into a browser or another
  // app. The URLs are the storage URLs, without embedded credentials.
  Future<void> _copySelectedLinks() async {
    final links = _selectedEntries.map((entry) => entry.uri).toList();
    if (links.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: links.join('\n')));
    if (!mounted) return;
    _showMessage(context.l10n.cloudLinksCopied(links.length));
  }

  Future<void> _deleteSelectedEntries() async {
    final count = _selectedEntries.length;
    if (count == 0 || !mounted) return;

    final confirmed = await _confirm(
      title: context.l10n.entryActionDelete,
      message: context.l10n.cloudDeleteSelectedConfirmation(count),
    );
    if (!confirmed || !mounted) return;

    final client = cloudRegistry.clientForServer(widget.server);
    if (client == null) return;

    final entriesToDelete = List.of(_selectedEntries);
    final total = entriesToDelete.length;
    final progress = ValueNotifier<(int, int)>((0, total));
    final cancelled = ValueNotifier(false);
    BuildContext? dialogContext;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          dialogContext = context;
          return _TaskProgressDialog(
            title: context.l10n.entryActionDelete,
            progress: progress,
            cancelled: cancelled,
          );
        },
      ),
    );
    // let the dialog build before the task runs: a very fast task could
    // otherwise finish before its context is set and leave the dialog open
    await WidgetsBinding.instance.endOfFrame;

    final deleted = <PurerEntry>[];
    var failed = 0;
    for (final entry in entriesToDelete) {
      if (cancelled.value) break;
      try {
        await client.delete(entry.uri);
        deleted.add(entry);
      } catch (error) {
        failed++;
        purerLog.warn(PurerLogCategory.network, '删除失败 ${PurerLog.redactUrl(entry.uri)} error=$error');
      }
      progress.value = (progress.value.$1 + 1, total);
    }
    final wasCancelled = cancelled.value;

    final ctx = dialogContext;
    if (ctx != null && ctx.mounted) Navigator.of(ctx).pop();
    if (!mounted) return;
    _exitSelectionMode();
    if (deleted.isNotEmpty) {
      _removeMultipleMedia(deleted);
      // the shared-cache cleanup needs one listing per folder and many DELETEs:
      // keep it off the delete loop (and off the dialog)
      _cacheCleanup = _cacheCleanup
          .then((_) async {
            await evictCloudThumbnails(deleted);
            for (final entry in deleted) {
              if (entry.isImage) settings.forgetCloudImage(entry.uri);
              if (entry.isVideo) settings.setCloudVideoProgress(entry.uri, 0, 0);
            }
          })
          .catchError((Object error) {
            purerLog.warn(PurerLogCategory.cache, '清理已删除文件的缓存失败 error=$error');
          });
    }
    _showMessage(
      wasCancelled ? context.l10n.cloudTaskCancelled(progress.value.$1, total) : context.l10n.cloudDeleteDone(deleted.length, failed),
    );
  }

  // Re-extracts the thumbnail of the selected videos, for the frames that are
  // not representative (black leader, solid color, wrong position). The cached
  // frame is dropped first, locally and in the shared WebDAV cache.
  Future<void> _regenerateSelectedThumbnails() async {
    final entries = _selectedEntries.where((e) => e.isVideo).toList();
    if (entries.isEmpty) {
      _showMessage(context.l10n.cloudRegenerateNone);
      return;
    }
    final service = mediaFetchService;
    if (service is! CloudAwareMediaFetchService) return;

    final total = entries.length;
    final progress = ValueNotifier<(int, int)>((0, total));
    final cancelled = ValueNotifier(false);
    BuildContext? dialogContext;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          dialogContext = context;
          return _TaskProgressDialog(
            title: context.l10n.cloudBatchRegenerate,
            progress: progress,
            cancelled: cancelled,
          );
        },
      ),
    );
    // let the dialog build before the task runs: a very fast task could
    // otherwise finish before its context is set and leave the dialog open
    await WidgetsBinding.instance.endOfFrame;

    // drop the cached frames up front: local keys per entry, then one mirror
    // listing per folder for the shared copies (a per-video removal cost a
    // PROPFIND each)
    for (final entry in entries) {
      await evictCloudThumbnailLocal(entry);
    }
    await evictCloudThumbnailsShared(entries);

    var success = 0, failed = 0;
    for (final entry in entries) {
      if (cancelled.value) break;
      final result = await service.regenerateVideoThumbnail(entry.uri, mimeType: entry.mimeType);
      if (result.ok) {
        success++;
      } else {
        failed++;
      }
      final current = progress.value.$1 + 1;
      progress.value = (current, total);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final wasCancelled = cancelled.value;
    purerLog.info(PurerLogCategory.thumbnail, '批量重新生成缩略图 success=$success failed=$failed cancelled=${cancelled.value}');

    final context2 = dialogContext;
    if (context2 != null && context2.mounted) Navigator.of(context2).pop();

    if (!mounted) return;
    // the discarded aspect ratios came from the old frames, and the tiles must
    // be recreated to resolve the regenerated frames
    _aspects.clear();
    _aspectsVersion++;
    _thumbnailGeneration++;
    _exitSelectionMode();
    setState(() {});
    _showMessage(
      wasCancelled ? context.l10n.cloudTaskCancelled(progress.value.$1, total) : context.l10n.cloudRegenerateDone(success, failed),
    );
  }

  // Triggered from the view settings: download the sprite sheets of every video
  // in the current folder that has one (usually already automatic). Runs in the
  // background; the tiles animate as the sheets arrive.
  Future<void> _loadSpritesNow() async {
    final service = mediaFetchService;
    if (service is! CloudAwareMediaFetchService) return;
    final videos = _media.value.where((e) => e.isVideo).toList();
    if (videos.isEmpty) {
      _showMessage(context.l10n.cloudSpriteNone);
      return;
    }
    final progress = ValueNotifier<(int, int)>((0, videos.length));
    final cancelled = ValueNotifier(false);
    BuildContext? dialogContext;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          dialogContext = context;
          return _TaskProgressDialog(
            title: context.l10n.cloudSpriteLoadNow,
            progress: progress,
            cancelled: cancelled,
          );
        },
      ),
    );
    // let the dialog build before the task runs: a very fast task could
    // otherwise finish before its context is set and leave the dialog open
    await WidgetsBinding.instance.endOfFrame;
    final summary = await service.animateSpriteThumbnailsForFolder(
      _currentUrl,
      videos.map((e) => e.uri).toList(),
      onProgress: (done, total) => progress.value = (done, total),
      isCancelled: () => cancelled.value,
    );
    final wasCancelled = cancelled.value;
    final ctx = dialogContext;
    if (ctx != null && ctx.mounted) Navigator.of(ctx).pop();
    purerLog.info(PurerLogCategory.thumbnail, '雪碧图加载 generated=${summary.generated} skipped=${summary.skipped} failed=${summary.failed}');
    if (!mounted) return;
    _showMessage(
      wasCancelled ? context.l10n.cloudTaskCancelled(progress.value.$1, videos.length) : (summary.generated == 0 ? context.l10n.cloudSpriteNotFound : context.l10n.cloudSpriteDone(summary.generated, summary.skipped, summary.failed)),
    );
  }

  void _removeMultipleMedia(Iterable<PurerEntry> entries) {
    if (!mounted) return;
    final uris = entries.map((e) => e.uri).toSet();
    final url = _currentUrl;
    final folders = _folders.value;
    final media = _media.value.where((e) => !uris.contains(e.uri)).toList();
    _media.value = media;
    _rememberSnapshot(url, _FolderSnapshot(folders, media));
    for (final u in uris) {
      _aspects.remove(u);
    }
    settings.recordCloudFolder(
      url,
      imageCount: media.where((e) => e.isImage).length,
      folderCount: folders.length,
    );
    setState(() {});
  }

  // long press on a folder row: delete it and everything it contains
  Future<void> _deleteFolder(CloudResource folder) async {
    if (!await _confirm(title: context.l10n.entryActionDelete, message: context.l10n.cloudDeleteFolderConfirmation(folder.name)) || !mounted) return;
    try {
      final client = cloudRegistry.clientForServer(widget.server);
      if (client == null) throw StateError('找不到该服务');
      await client.delete(folder.url);
      // the list is updated first: dropping the mirrored cache can wait for the
      // cache server's timeout, and the folder is already gone from the source
      _removeFolder(folder);
      _cacheCleanup = _cacheCleanup.then((_) => cloudMediaCache.removeFolder(folder.url)).catchError((Object error) {
        purerLog.warn(PurerLogCategory.cache, '清理已删除文件夹的缓存失败 error=$error');
      });
    } catch (error) {
      if (!mounted) return;
      _showMessage('${context.l10n.cloudDeleteFailed}: ${cloudErrorText(error)}');
    }
  }

  void _removeFolder(CloudResource folder) {
    if (!mounted) return;
    final url = _currentUrl;
    final folders = _folders.value.where((f) => f.url != folder.url).toList();
    final media = _media.value;
    _folders.value = folders;
    _rememberSnapshot(url, _FolderSnapshot(folders, media));
    settings.recordCloudFolder(
      url,
      imageCount: media.where((e) => e.isImage).length,
      folderCount: folders.length,
    );
    settings.forgetCloudFolder(folder.url);
    final removedSnapshot = _folderSnapshots.remove(folder.url);
    if (removedSnapshot != null) {
      _snapshotEntryCount -= removedSnapshot.folders.length + removedSnapshot.media.length;
      _forgetSnapshotKeys(removedSnapshot);
    }
    _folderLists.remove(folder.url);
    setState(() {});
  }

  // a compact JSON backup of the folder progress, so reinstalling the app does
  // not lose which pictures have already been seen
  Future<void> _exportProgress() async {
    final json = settings.exportCloudFolderStats();
    final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(json));
    final basename = 'purer-progress-${DateTime.now().millisecondsSinceEpoch}';
    final result = await storageService.createFile(basename: basename, mimeType: MimeTypes.json, bytes: bytes);
    if (!mounted) return;
    if (result == true) {
      _showMessage(context.l10n.genericSuccessFeedback);
    } else if (result == false) {
      _showMessage(context.l10n.genericFailureFeedback);
    }
  }

  Future<void> _clearProgress() async {
    if (!await _confirm(title: context.l10n.cloudClearProgress, message: context.l10n.cloudClearProgressConfirmation) || !mounted) return;
    settings.clearCloudFolderProgress();
    setState(() {});
    _showMessage(context.l10n.genericSuccessFeedback);
  }

  Future<void> _importProgress() async {
    final bytes = await storageService.openFile();
    if (!mounted || bytes.isEmpty) return;
    try {
      final count = settings.importCloudFolderStats(jsonDecode(utf8.decode(bytes)));
      if (count > 0) {
        _showMessage(context.l10n.cloudProgressImported(count));
        if (mounted) setState(() {});
      } else {
        _showMessage(context.l10n.genericFailureFeedback);
      }
    } catch (_) {
      _showMessage(context.l10n.genericFailureFeedback);
    }
  }

  // stops extracting the thumbnails of a folder that is no longer on screen,
  // after a short grace period so an accidental tap does not lose progress
  void _abandonThumbnailsSoon(Iterable<String> uris) {
    final list = uris.toList();
    if (list.isEmpty) return;
    _abandonTimer?.cancel();
    _abandonTimer = Timer(const Duration(seconds: 3), () {
      _abandonTimer = null;
      abandonCloudVideoThumbnails(list);
    });
  }

  double _aspectOf(PurerEntry entry) {
    final cached = _aspects[entry.uri];
    if (cached != null) return cached.clamp(0.35, 2.6);
    if (entry.width > 0 && entry.height > 0) {
      return (entry.width / entry.height).clamp(0.35, 2.6);
    }
    return (entry.isVideo ? (16 / 9) : 1.0).clamp(0.35, 2.6);
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (_magnifying || _selectionMode) return;
    _scaleStartColumns = _liveColumns ?? settings.cloudColumns;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_magnifying || _selectionMode) return;
    if (details.pointerCount < 2) return;
    final scale = details.scale;
    if (scale <= 0) return;
    final columns = (_scaleStartColumns / scale).clamp(1.0, 8.0);
    // quarter-column steps: a continuous value rebuilt the whole mosaic (and
    // recomputed every row) on each frame of the gesture
    final stepped = (columns * 4).roundToDouble() / 4;
    if (stepped == _liveColumns) return;
    // only the local layout value changes while the gesture runs: persisting
    // per frame wrote the preference and rebuilt everything dozens of times
    setState(() => _liveColumns = stepped);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final columns = _liveColumns;
    if (columns == null) return;
    _liveColumns = null;
    settings.cloudColumns = columns;
    if (mounted) setState(() {});
  }

  static String _mimeForResource(CloudResource resource) => cloudMimeForResource(resource);

  void _openFolder(CloudResource folder) => _navigateTo(folder.url);

  Future<void> _openEntry(List<PurerEntry> visibleEntries, PurerEntry entry) async {
    if (_selectionMode) {
      _toggleSelectEntry(entry);
      return;
    }
    // the pointer only released the magnifier
    if (_suppressTap) return;
    if (_stopMosaicAutoMotionIfRunning() || _justTerminatedAutoMotion) return;
    if (entry.isVideo) {
      // remember that this video was opened, and where we stopped watching
      setState(() => settings.markCloudVisited(entry.uri));
      // the video backend streams the file itself, so hand it a URL it can
      // consume: an authenticated URL for WebDAV, a loopback bridge for SMB
      final playableUrl = await cloudRegistry.playbackUrl(entry.uri);
      if (!mounted) return;
      final playableEntry = playableUrl == entry.uri ? entry : entry.copyWith(uri: playableUrl);
      await Navigator.push(
        context,
        MaterialPageRoute(
          settings: const RouteSettings(name: CloudVideoPage.routeName),
          builder: (context) => CloudVideoPage(entry: playableEntry, storageUri: entry.uri),
        ),
      );
      if (mounted) setState(() {});
      return;
    }
    // the viewer offers the next album: make sure its parent listing is known
    // even in a layout/deep link that never primed siblings
    _primeSiblingsForViewer();
    final index = visibleEntries.indexOf(entry);
    final images = visibleEntries.where((e) => e.isImage).toList();
    final imageIndex = images.indexOf(entry);
    if (index < 0 || images.isEmpty || imageIndex < 0) return;
    final resultUrl = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: CloudViewerPage.routeName),
        builder: (context) => CloudViewerPage(
          entries: images,
          initialIndex: imageIndex,
          currentFolderUrl: _currentUrl,
          getNextFolder: _nextFolderInParent,
          loadFolderImages: _loadFolderImages,
          onFolderChanged: (newUrl) {
            _navigateTo(newUrl, lateral: true);
          },
        ),
      ),
    );
    if (mounted && resultUrl != null && !_sameFolder(resultUrl, _currentUrl)) {
      _navigateTo(resultUrl, lateral: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content = PurerScaffold(
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onMosaicPointerDown,
        onPointerMove: _onMosaicPointerMove,
        onPointerUp: _onMosaicPointerUp,
        onPointerCancel: _onMosaicPointerUp,
        child: Stack(
          children: [
            ValueListenableBuilder<_LoadState>(
              valueListenable: _state,
              builder: (context, state, child) {
                return ValueListenableBuilder<List<CloudResource>>(
                  valueListenable: _folders,
                  builder: (context, folders, child) {
                    return ValueListenableBuilder<List<PurerEntry>>(
                      valueListenable: _media,
                      builder: (context, media, child) => _buildScrollView(context, state: state, folders: folders, media: media),
                    );
                  },
                );
              },
            ),
            _NextFolderHint(folder: _nextFolder, progress: _nextFolderProgress),
            if (_magnifying)
              FullscreenZoomMagnifier(
                positionNotifier: _magnifierPosition,
                scale: settings.cloudMosaicMagnifierScale,
              ),
          ],
        ),
      ),
    );
    return PopScope(
      // in selection mode, back first leaves the selection instead of the folder
      canPop: _trailIndex <= 0 && !_selectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_selectionMode) {
          _exitSelectionMode();
        } else {
          _goBack();
        }
      },
      child: content,
    );
  }

  Widget _buildScrollView(BuildContext context, {required _LoadState state, required List<CloudResource> folders, required List<PurerEntry> media}) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateSpritePlaybackBand());
    final committedColumns = context.select<Settings, double>((s) => s.cloudColumns);
    final columns = _liveColumns ?? committedColumns;
    final mediaFilter = context.select<Settings, String>((s) => s.cloudMediaFilter);
    final showNames = context.select<Settings, bool>((s) => s.cloudShowNames);
    final showSizes = context.select<Settings, bool>((s) => s.cloudShowSizes);
    final showDimensions = context.select<Settings, bool>((s) => s.cloudShowDimensions);
    final immersiveEnabled = context.select<Settings, bool>((s) => s.cloudImmersive);
    // a folder holding only videos (or the "videos only" filter) uses the video
    // default layout, everything else the image default
    final videoMode = _isVideoMode(media, mediaFilter);
    final layout = context.select<Settings, String>((s) => s.cloudLayoutFor(_currentUrl, video: videoMode));
    final topInset = MediaQuery.paddingOf(context).top;
    final headerHeight = topInset + kToolbarHeight + CloudBrowserPage.addressBarHeight;

    final sort = context.select<Settings, String>((s) => s.cloudSort);
    // folders only have a name: keep them name-sorted whatever the media sort
    final folderDescending = sort == 'nameDesc';
    final hideCompleted = context.select<Settings, bool>((s) => s.cloudHideCompletedFolders);

    final allSortedFolders = _sortedFoldersFor(folders, descending: folderDescending);
    final sortedFolders = hideCompleted ? allSortedFolders.where((f) => !settings.cloudFolderProgressComplete(f.url)).toList() : allSortedFolders;
    final sortedVisible = _sortedMediaFor(media, mediaFilter, sort);

    final isHorizontalMosaic = layout == 'mosaic' && settings.cloudMosaicScrollDirection == 'horizontal';
    final List<Widget> contentSlivers;
    if (state == _LoadState.loading) {
      contentSlivers = [const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()))];
    } else if (state == _LoadState.error) {
      contentSlivers = [
        SliverFillRemaining(
          hasScrollBody: false,
          child: ValueListenableBuilder<String>(
            valueListenable: _error,
            builder: (context, error, child) => EmptyContent(
              icon: AIcons.error,
              text: '${context.l10n.webdavLoadError}\n$error',
              bottom: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: OutlinedButton(onPressed: _fetch, child: Text(context.l10n.webdavRefresh)),
              ),
            ),
          ),
        ),
      ];
    } else if (sortedFolders.isEmpty && sortedVisible.isEmpty) {
      if (hideCompleted && allSortedFolders.isNotEmpty) {
        contentSlivers = [
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyContent(
              icon: Icons.filter_alt,
              text: context.l10n.cloudAllCompletedHidden,
              bottom: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: TextButton(
                  onPressed: () => settings.cloudHideCompletedFolders = false,
                  child: Text(context.l10n.cloudShowCompletedFolders),
                ),
              ),
            ),
          ),
        ];
      } else {
        contentSlivers = [
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyContent(icon: AIcons.folder, text: context.l10n.webdavEmptyFolder),
          ),
        ];
      }
    } else {
      contentSlivers = [
        if (sortedFolders.isNotEmpty) _buildFolderSliver(context, sortedFolders),
        if (sortedVisible.isNotEmpty)
          // the horizontal mosaic returns its own layout before reaching this
          // list, so only the vertical arrangement is needed here
          if (layout == 'mosaic')
            ..._buildMosaicSlivers(context, sortedVisible, columns, showNames, showSizes, showDimensions)
          else if (layout == 'list')
            _buildListSliver(context, sortedVisible, showNames, showSizes, showDimensions)
          else
            _buildGridSliver(context, sortedVisible, columns, showNames, showSizes, showDimensions),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
      ];
    }

    if (isHorizontalMosaic && state == _LoadState.ready && sortedVisible.isNotEmpty) {
      // only the images follow the configured direction: the folders keep a
      // normal vertical list above them (they used to scroll sideways too)
      final viewport = MediaQuery.sizeOf(context);
      final folderHeight = math.min(sortedFolders.length * 56.0, viewport.height * .3);
      return Column(
        children: [
          // the fixed bar has no sliver to scroll away: collapse it like the
          // sliver app bar of the other layouts
          ClipRect(
            child: AnimatedAlign(
              alignment: Alignment.topCenter,
              heightFactor: _immersive ? 0 : 1,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              child: _buildFixedAppBar(context, immersiveEnabled, videoMode, layout: layout),
            ),
          ),
          if (sortedFolders.isNotEmpty)
            SizedBox(
              height: folderHeight,
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: sortedFolders.length,
                itemBuilder: (context, index) => _buildFolderTile(context, sortedFolders[index]),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => RefreshIndicator(
                onRefresh: () => _fetch(keepContent: true),
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onScrollNotification,
                  // the vertical layouts get the draggable scrollbar; a
                  // horizontal one at least shows where the user is
                  child: Scrollbar(
                    controller: _scrollController,
                    child: CustomScrollView(
                      key: ValueKey<int>(_scrollGeneration),
                      controller: _scrollController,
                      scrollDirection: Axis.horizontal,
                      physics: _magnifying ? const NeverScrollableScrollPhysics() : _LockedScrollPhysics(isLocked: () => _magnifying),
                      scrollCacheExtent: const ScrollCacheExtent.viewport(.5),
                      slivers: _buildHorizontalMosaicSlivers(
                        context,
                        sortedVisible,
                        columns,
                        showNames,
                        showSizes,
                        showDimensions,
                        height: math.max(constraints.maxHeight, 120),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Listener(
      onPointerDown: (_) => _pointerCount++,
      onPointerUp: (_) {
        _pointerCount = math.max(0, _pointerCount - 1);
        if (_pointerCount == 0) _overscrollLocked = false;
      },
      onPointerCancel: (_) {
        _pointerCount = math.max(0, _pointerCount - 1);
        if (_pointerCount == 0) _overscrollLocked = false;
      },
      child: RawGestureDetector(
        gestures: {
          EagerScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerScaleGestureRecognizer>(
            () => EagerScaleGestureRecognizer(debugOwner: this),
            (instance) {
              instance
                ..onStart = _onScaleStart
                ..onUpdate = _onScaleUpdate
                ..onEnd = _onScaleEnd;
            },
          ),
        },
        child: DraggableScrollbar(
          backgroundColor: Colors.white,
          scrollThumbSize: PurerScrollThumb.thumbSize,
          scrollThumbBuilder: PurerScrollThumb.builder(
            height: PurerScrollThumb.thumbHeight,
            backgroundColor: Colors.white,
          ),
          controller: _scrollController,
          padding: EdgeInsets.only(top: immersiveEnabled ? 0 : headerHeight),
          labelTextBuilder: (offsetY) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(_folderName, style: const TextStyle(color: Colors.black87)),
          ),
          crumbTextBuilder: (label) => const SizedBox.shrink(),
          child: RefreshIndicator(
            // refresh keeps the current tiles (and their image providers) in
            // place: clearing them made every video frame look regenerated
            onRefresh: () => _fetch(keepContent: true),
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: CustomScrollView(
                // a new position per folder, created at that folder's saved
                // offset instead of starting at the top and jumping
                key: ValueKey<int>(_scrollGeneration),
                controller: _scrollController,
                physics: _magnifying ? const NeverScrollableScrollPhysics() : _LockedScrollPhysics(isLocked: () => _magnifying),
                // build half a screen ahead: every remote thumbnail is a full
                // download, and preloading a whole extra screen queued dozens of
                // files the user may never look at, delaying the visible ones
                // and the next folder's listing
                scrollCacheExtent: layout == 'mosaic' || layout == 'grid' ? const ScrollCacheExtent.viewport(.5) : const ScrollCacheExtent.pixels(800),
                slivers: [
                  _buildAppBar(context, immersiveEnabled, videoMode, layout: layout),
                  ...contentSlivers,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // the first three interaction buttons (auto motion toggles and the
  // "completed" filter), kept on the left when full screen is enabled
  List<Widget> _buildLeftAppBarActions(BuildContext context, String layout) {
    // auto scroll / page flip only make sense when the folder actually holds
    // images to move through (a folder of subfolders or videos does not)
    final hasImages = _media.value.any((e) => e.isImage);
    return [
      // the back arrow used to sit in the address bar below; moving it into the
      // toolbar puts the folder navigation next to the other actions
      IconButton(
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        icon: const Icon(Icons.arrow_back_ios_new, size: 20),
        onPressed: _trailIndex > 0 ? _goBack : () => Navigator.maybePop(context),
      ),
      if (layout == 'mosaic' && hasImages) ...[
        ValueListenableBuilder<bool>(
          valueListenable: _autoScrollingNotifier,
          builder: (context, autoScrolling, child) => IconButton(
            tooltip: context.l10n.cloudViewerAutoScroll,
            color: autoScrolling ? Theme.of(context).colorScheme.primary : null,
            icon: Icon(autoScrolling ? Icons.pause_circle_filled : Icons.play_circle_outline),
            onPressed: _toggleMosaicAutoScroll,
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: _autoFlippingNotifier,
          builder: (context, autoFlipping, child) => IconButton(
            tooltip: context.l10n.cloudViewerAutoPageFlip,
            color: autoFlipping ? Theme.of(context).colorScheme.primary : null,
            icon: Icon(autoFlipping ? Icons.auto_stories : Icons.auto_stories_outlined),
            onPressed: _toggleMosaicAutoPageFlip,
          ),
        ),
      ],
      IconButton(
        isSelected: settings.cloudHideCompletedFolders,
        tooltip: context.l10n.cloudHideCompletedFolders,
        icon: const Icon(Icons.filter_alt_outlined),
        selectedIcon: const Icon(Icons.filter_alt),
        onPressed: () => settings.cloudHideCompletedFolders = !settings.cloudHideCompletedFolders,
      ),
    ];
  }

  // selection and the view options, kept on the right in every mode
  List<Widget> _buildRightAppBarActions(BuildContext context, bool videoMode, String layout) {
    return [
      IconButton(
        tooltip: context.l10n.webdavRefresh,
        icon: const Icon(Icons.refresh),
        onPressed: () => _fetch(keepContent: true),
      ),
      IconButton(
        tooltip: context.l10n.cloudBatchSelect,
        icon: const Icon(Icons.checklist_rounded),
        onPressed: _startSelectionMode,
      ),
      IconButton(
        tooltip: context.l10n.webdavViewOptions,
        icon: const Icon(Icons.settings_outlined),
        onPressed: () => showCloudViewOptions(
          context,
          url: _currentUrl,
          video: videoMode,
          onRebuildThumbnails: _rebuildThumbnails,
          onExportProgress: _exportProgress,
          onImportProgress: _importProgress,
          onClearProgress: _clearProgress,
          onLoadSprites: _loadSpritesNow,
        ),
      ),
    ];
  }

  List<Widget> _buildSelectionActions(BuildContext context) {
    final visible = _visibleMedia;
    final allVisibleSelected = visible.isNotEmpty && visible.every(_selectedEntries.contains);
    return [
      IconButton(
        tooltip: context.l10n.menuActionSelectAll,
        icon: Icon(allVisibleSelected ? Icons.deselect : Icons.select_all),
        onPressed: visible.isEmpty ? null : _toggleSelectAll,
      ),
      IconButton(
        tooltip: context.l10n.cloudBatchRegenerate,
        icon: const Icon(Icons.autorenew),
        onPressed: _selectedEntries.any((e) => e.isVideo) ? _regenerateSelectedThumbnails : null,
      ),
      IconButton(
        tooltip: context.l10n.cloudCopySelectedLinks,
        icon: const Icon(Icons.link),
        onPressed: _selectedEntries.isEmpty ? null : _copySelectedLinks,
      ),
      IconButton(
        tooltip: context.l10n.entryActionDelete,
        icon: const Icon(Icons.delete_outline),
        onPressed: _selectedEntries.isEmpty ? null : _deleteSelectedEntries,
      ),
    ];
  }

  List<Widget> _buildAppBarActions(BuildContext context, bool videoMode, String layout) => [
    ..._buildLeftAppBarActions(context, layout),
    ..._buildRightAppBarActions(context, videoMode, layout),
  ];

  static const double _appBarActionWidth = 48;

  // when the system status bar is hidden, the toolbar also moves to the very
  // top and its leading area holds the first interaction buttons
  List<Widget> _appBarLeadingActions(BuildContext context, String layout, {required bool splitActions}) {
    if (_selectionMode) return [IconButton(icon: const Icon(Icons.close), onPressed: _exitSelectionMode)];
    if (!splitActions) return const [];
    return _buildLeftAppBarActions(context, layout);
  }

  Widget _buildFixedAppBar(BuildContext context, bool immersiveEnabled, bool videoMode, {required String layout}) {
    final fullScreen = settings.hideSystemStatusBar;
    final splitActions = fullScreen && !_selectionMode;
    final leadingActions = _appBarLeadingActions(context, layout, splitActions: splitActions);
    final actions = _selectionMode ? _buildSelectionActions(context) : (splitActions ? _buildRightAppBarActions(context, videoMode, layout) : _buildAppBarActions(context, videoMode, layout));
    return AppBar(
      primary: true,
      automaticallyImplyLeading: false,
      // the folder name is redundant with the address bar, and there is no
      // drawer in this app: no leading button, no title while browsing
      leading: leadingActions.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, children: leadingActions),
      leadingWidth: leadingActions.isEmpty ? null : (_selectionMode ? kToolbarHeight : leadingActions.length * _appBarActionWidth),
      title: _selectionMode ? Text(context.l10n.cloudSelectedCount(_selectedEntries.length)) : null,
      actions: actions,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(CloudBrowserPage.addressBarHeight),
        child: _buildAddressBar(context),
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, bool immersiveEnabled, bool videoMode, {required String layout}) {
    final fullScreen = settings.hideSystemStatusBar;
    final splitActions = fullScreen && !_selectionMode;
    final leadingActions = _appBarLeadingActions(context, layout, splitActions: splitActions);
    final actions = _selectionMode ? _buildSelectionActions(context) : (splitActions ? _buildRightAppBarActions(context, videoMode, layout) : _buildAppBarActions(context, videoMode, layout));
    return SliverAppBar(
      primary: true,
      pinned: !immersiveEnabled,
      floating: immersiveEnabled,
      snap: immersiveEnabled,
      automaticallyImplyLeading: false,
      leading: leadingActions.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, children: leadingActions),
      leadingWidth: leadingActions.isEmpty ? null : (_selectionMode ? kToolbarHeight : leadingActions.length * _appBarActionWidth),
      title: _selectionMode ? Text(context.l10n.cloudSelectedCount(_selectedEntries.length)) : null,
      actions: actions,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(CloudBrowserPage.addressBarHeight),
        child: _buildAddressBar(context),
      ),
    );
  }

  Widget _buildAddressBar(BuildContext context) {
    // the trail keeps the folders we went back from, so the address bar can
    // still show that depth and return to any of them without re-listing
    final crumbs = _breadcrumbs(_deepestTrailUrl);
    final entries = <(String, String)>[(context.l10n.webdavRoot, _baseUrl), ...crumbs];
    final currentIndex = entries.indexWhere((crumb) => _sameFolder(crumb.$2, _currentUrl));
    final selected = currentIndex < 0 ? entries.length - 1 : currentIndex;
    final disabledColor = Theme.of(context).disabledColor;
    return SizedBox(
      height: CloudBrowserPage.addressBarHeight,
      child: Row(
        children: [
          // the back arrow and the jump action moved out of this bar: the
          // back arrow is in the toolbar, and a path can still be reached by
          // tapping any breadcrumb
          const SizedBox(width: 4),
          Expanded(
            child: SingleChildScrollView(
              key: _addressViewportKey,
              controller: _addressScrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0) const Icon(Icons.chevron_right, size: 16),
                    InkWell(
                      key: i == selected ? _currentCrumbKey : null,
                      onTap: i == selected ? null : () => _navigateTo(entries[i].$2),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                        child: Text(
                          entries[i].$1,
                          style: TextStyle(
                            // folders deeper than the current one were reached
                            // before: dimmed, but still tappable to go forward
                            color: i == selected ? Theme.of(context).colorScheme.primary : (i > selected ? disabledColor : null),
                            fontWeight: i == selected ? FontWeight.bold : null,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderSliver(BuildContext context, List<CloudResource> folders) {
    return SliverList.builder(
      itemCount: folders.length,
      itemBuilder: (context, index) => _buildFolderTile(context, folders[index]),
    );
  }

  Widget _buildFolderTile(BuildContext context, CloudResource folder) {
    final disabledColor = Theme.of(context).disabledColor;
    final hintColor = Theme.of(context).hintColor;
    // O(1) via the cached lookup; collection URLs may differ by a slash
    final isVisited = settings.isCloudFolderVisited(folder.url);
    final color = isVisited ? disabledColor : null;
    // "loaded/total" for an image folder, "opened/total" for a folder of
    // folders; one level deep, nothing is counted recursively
    final progress = settings.cloudFolderProgressText(folder.url);
    return ListTile(
      minLeadingWidth: 56,
      leading: SizedBox(
        width: 56,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(AIcons.folder, color: color),
            if (progress != null)
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  progress,
                  maxLines: 1,
                  style: TextStyle(fontSize: 10, height: 1.1, color: color ?? hintColor),
                ),
              ),
          ],
        ),
      ),
      title: Text(folder.name, style: TextStyle(color: color)),
      onTap: () => _openFolder(folder),
      onLongPress: () => _deleteFolder(folder),
    );
  }

  // effective layout of the current folder: video default for video-only
  // content, image default otherwise, overridden by a per-folder choice
  static bool _computeVideoMode(List<PurerEntry> media, String filter) => filter == 'video' || (filter == 'all' && media.isNotEmpty && media.every((e) => e.isVideo));

  // memoized: this runs from `_buildScrollView`, `_resolvedLayout` and the
  // scroll handler, and scanning a large folder each time was measurable
  bool _isVideoMode(List<PurerEntry> media, String filter) {
    if (identical(_videoModeSource, media) && _videoModeFilter == filter) return _videoModeCache;
    final result = _computeVideoMode(media, filter);
    _videoModeSource = media;
    _videoModeFilter = filter;
    _videoModeCache = result;
    return result;
  }

  String _resolvedLayout(List<PurerEntry> media) => settings.cloudLayoutFor(_currentUrl, video: _isVideoMode(media, settings.cloudMediaFilter));

  // watch progress (0..1) of a video, or null when unknown
  static double? _progressOf(PurerEntry entry) {
    if (!entry.isVideo) return null;
    final position = settings.cloudVideoPosition(entry.uri);
    final duration = settings.cloudVideoDuration(entry.uri);
    if (position == null || duration == null || duration <= 0) return null;
    return (position / duration).clamp(0.0, 1.0);
  }

  // a thumbnail decoded: remember the aspect ratio for the mosaic layout and,
  // for images, count the picture as loaded in its folder progress
  void _onTileImageInfo(PurerEntry entry, ImageInfo info) {
    final dim = settings.cloudImageDimensions(entry.uri);
    final width = dim?.$1 ?? info.image.width;
    final height = dim?.$2 ?? info.image.height;
    if (width > 0 && height > 0) {
      entry.width = width;
      entry.height = height;
      _onTileAspect(entry.uri, width / height);
    }
    if (entry.isImage) {
      _loadedImageUris.add(entry.uri);
      // drop the oldest half instead of everything: a `clear` also made the
      // pictures still on screen briefly unable to start the magnifier, since
      // their info event will not fire again
      if (_loadedImageUris.length > 20000) {
        _loadedImageUris.removeAll(_loadedImageUris.take(10000).toList());
      }
      settings.markCloudImageLoaded(entry.uri);
    }
  }

  List<PurerEntry> _sortedMediaFor(List<PurerEntry> media, String filter, String sort) {
    if (identical(_sortedMediaSource, media) && _sortedMediaFilter == filter && _sortedMediaSort == sort) {
      return _sortedMediaCache;
    }
    final visible = switch (filter) {
      'image' => media.where((e) => e.isImage).toList(),
      'video' => media.where((e) => e.isVideo).toList(),
      _ => media,
    };
    _sortedMediaSource = media;
    _sortedMediaFilter = filter;
    _sortedMediaSort = sort;
    _sortedMediaCache = _sortEntries(visible, sort);
    return _sortedMediaCache;
  }

  List<CloudResource> _sortedFoldersFor(List<CloudResource> folders, {required bool descending}) {
    if (identical(_sortedFolderSource, folders) && _sortedFolderDescending == descending) {
      return _sortedFolderCache;
    }
    _sortedFolderSource = folders;
    _sortedFolderDescending = descending;
    _sortedFolderCache = sortCloudResourcesByName(folders, descending: descending);
    return _sortedFolderCache;
  }

  // rows of the vertical mosaic, cached until the entries, the width, the
  // column count or a learned aspect ratio changes
  List<(List<int>, double)> _mosaicRowsFor(List<PurerEntry> entries, double columns, double width) {
    final key = '${identityHashCode(entries)}|$columns|$width|$_aspectsVersion';
    final cached = _mosaicRowsCache;
    if (cached != null && _mosaicRowsKey == key) return cached;
    final targetHeight = width / columns;
    final rows = <(List<int>, double)>[];
    var items = <int>[];
    var aspectSum = 0.0;
    void flushRow({required bool complete}) {
      if (items.isEmpty) return;
      final height = complete ? width / aspectSum : targetHeight;
      rows.add((List.of(items), height.clamp(48.0, targetHeight * 2.4)));
      items = [];
      aspectSum = 0;
    }

    for (var i = 0; i < entries.length; i++) {
      final aspect = _aspectOf(entries[i]);
      final nextWidth = (aspectSum + aspect) * targetHeight;
      if (items.isNotEmpty && nextWidth > width) {
        flushRow(complete: true);
      }
      items.add(i);
      aspectSum += aspect;
    }
    flushRow(complete: false);
    _mosaicRowsKey = key;
    _mosaicRowsCache = rows;
    return rows;
  }

  // columns of the horizontal mosaic, with the same caching
  List<(List<int>, double)> _horizontalColsFor(List<PurerEntry> entries, double columns, double height) {
    final key = '${identityHashCode(entries)}|$columns|$height|$_aspectsVersion';
    final cached = _mosaicColsCache;
    if (cached != null && _mosaicColsKey == key) return cached;
    final targetWidth = height / columns;
    final cols = <(List<int>, double)>[];
    var items = <int>[];
    var invAspectSum = 0.0;
    void flushCol({required bool complete}) {
      if (items.isEmpty) return;
      final w = complete ? height / invAspectSum : targetWidth;
      cols.add((List.of(items), w.clamp(48.0, targetWidth * 2.4)));
      items = [];
      invAspectSum = 0;
    }

    for (var i = 0; i < entries.length; i++) {
      final aspect = _aspectOf(entries[i]);
      final invAspect = 1.0 / (aspect > 0 ? aspect : 1.0);
      final nextHeight = (invAspectSum + invAspect) * targetWidth;
      if (items.isNotEmpty && nextHeight > height) {
        flushCol(complete: true);
      }
      items.add(i);
      invAspectSum += invAspect;
    }
    flushCol(complete: false);
    _mosaicColsKey = key;
    _mosaicColsCache = cols;
    return cols;
  }

  // media sort: name, size or duration, each ascending or descending, with the
  // name as a stable tie-breaker. Durations are the ones already known from
  // extraction/playback; unknown values sort as 0.
  static List<PurerEntry> _sortEntries(List<PurerEntry> entries, String sort) {
    final descending = sort.endsWith('Desc');
    final bySize = sort.startsWith('size');
    final byDuration = sort.startsWith('duration');
    int compare(PurerEntry a, PurerEntry b) {
      final nameA = (a.sourceTitle ?? a.bestTitle ?? '').toLowerCase();
      final nameB = (b.sourceTitle ?? b.bestTitle ?? '').toLowerCase();
      int result;
      if (bySize) {
        result = (a.sizeBytes ?? 0).compareTo(b.sizeBytes ?? 0);
      } else if (byDuration) {
        result = (settings.cloudVideoDuration(a.uri) ?? 0).compareTo(settings.cloudVideoDuration(b.uri) ?? 0);
      } else {
        result = nameA.compareTo(nameB);
      }
      if (result == 0) result = nameA.compareTo(nameB);
      return descending ? -result : result;
    }

    return [...entries]..sort(compare);
  }

  Widget _buildListSliver(BuildContext context, List<PurerEntry> entries, bool showNames, bool showSizes, bool showDimensions) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final showThumbnails = context.select<Settings, bool>((s) => s.cloudShowThumbnails);
    final showVideoDuration = context.select<Settings, bool>((s) => s.cloudVideoDurationVisible);
    final showVideoPlayIcon = context.select<Settings, bool>((s) => s.cloudVideoPlayIcon);
    return SliverList.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final isSelected = _selectedEntries.contains(entry);
        final watched = entry.isVideo && settings.isCloudVisited(entry.uri);
        final sizeBytes = entry.sizeBytes;
        final sizeText = (showSizes && sizeBytes != null) ? formatFileSize(settings.purerLocale, sizeBytes, round: 0) : null;
        final dimensionText = (showDimensions && entry.width > 0 && entry.height > 0) ? '${entry.width} × ${entry.height}' : null;
        final durationText = _cloudVideoDurationText(entry, visible: showVideoDuration);
        final subtitleText = [?sizeText, ?dimensionText, ?durationText].join('  ·  ');
        return ListTile(
          key: ValueKey('${entry.uri}@${settings.cloudThumbnailQuality}@$_thumbnailGeneration'),
          selected: isSelected,
          leading: SizedBox(
            width: 56,
            height: 56,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (!showThumbnails) _MediaPlaceholder(entry: entry, icon: entry.isVideo ? Icons.video_file_outlined : Icons.image_outlined),
                // a contained video leaves letterbox bars: keep them plain, a
                // type placeholder behind would show through the bars
                if (showThumbnails && entry.isVideo) const ColoredBox(color: Color(0xFF1E222A)),
                if (showThumbnails && entry.isVideo)
                  _VideoThumbnail(
                    entry: entry,
                    extent: 56,
                    devicePixelRatio: dpr,
                    isMosaic: false,
                    showLoading: settings.cloudVideoThumbnails,
                    hasSprite: _spriteUris.contains(entry.uri),
                    onImageInfo: _onTileImageInfo,
                    onAspect: (aspect) => _onTileAspect(entry.uri, aspect),
                  )
                else if (showThumbnails)
                  ThumbnailImage(
                    entry: entry,
                    extent: 56,
                    devicePixelRatio: dpr,
                    fit: BoxFit.cover,
                    showLoadingBackground: false,
                    showLoadingIndicator: true,
                    prioritizeOnVisible: true,
                    onImageInfo: (info) => _onTileImageInfo(entry, info),
                  ),
                if (showThumbnails && entry.isVideo && settings.cloudVideoThumbnails) _VideoLoadingOverlay(entry.uri),
                // selection keeps the picture visible, with the check on top
                if (_selectionMode)
                  Align(
                    alignment: Alignment.topRight,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected ? Theme.of(context).colorScheme.primary : const Color(0x99000000),
                        border: Border.all(
                          color: isSelected ? Theme.of(context).colorScheme.primary : Colors.white,
                          width: 2,
                        ),
                      ),
                      child: isSelected ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
                    ),
                  ),
              ],
            ),
          ),
          title: Text(
            entry.sourceTitle ?? entry.bestTitle ?? '',
            style: watched ? TextStyle(color: Theme.of(context).disabledColor) : null,
          ),
          subtitle: subtitleText.isEmpty ? null : Text(subtitleText),
          trailing: entry.isVideo && showVideoPlayIcon ? const Icon(Icons.play_circle_outline, size: 20) : null,
          onTap: () => _openEntry(entries, entry),
          onLongPress: () => _onEntryLongPress(entry),
        );
      },
    );
  }

  Widget _buildGridSliver(BuildContext context, List<PurerEntry> entries, double columns, bool showNames, bool showSizes, bool showDimensions) {
    final crossAxisCount = columns.round().clamp(1, 10);
    final width = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // no padding or spacing: the images touch each other edge to edge
    return SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: 0,
        crossAxisSpacing: 0,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return _CloudTile(
          // the quality is part of the identity: changing it recreates the
          // tile state, which re-resolves its provider at the new decode cap
          key: ValueKey('${entry.uri}@${settings.cloudThumbnailQuality}@$_thumbnailGeneration'),
          entry: entry,
          hasSprite: _spriteUris.contains(entry.uri),
          extent: width / crossAxisCount,
          devicePixelRatio: dpr,
          showName: showNames,
          showSize: showSizes,
          showDimensions: showDimensions,
          watched: entry.isVideo && settings.isCloudVisited(entry.uri),
          progress: _progressOf(entry),
          onImageInfo: _onTileImageInfo,
          onAspect: (aspect) => _onTileAspect(entry.uri, aspect),
          onTap: () => _openEntry(entries, entry),
          onLongPress: () => _onEntryLongPress(entry),
          selectionMode: _selectionMode,
          isSelected: _selectedEntries.contains(entry),
        );
      },
    );
  }

  List<Widget> _buildMosaicSlivers(BuildContext context, List<PurerEntry> entries, double columns, bool showNames, bool showSizes, bool showDimensions) {
    final width = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // no gaps: rows are edge to edge, and the whole mosaic uses the full width
    final rows = _mosaicRowsFor(entries, columns, width);

    return [
      SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, rowIndex) {
          final (indices, height) = rows[rowIndex];
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var k = 0; k < indices.length; k++)
                SizedBox(
                  width: _aspectOf(entries[indices[k]]) * height,
                  height: height,
                  child: _CloudTile(
                    key: ValueKey('${entries[indices[k]].uri}@${settings.cloudThumbnailQuality}@$_thumbnailGeneration'),
                    entry: entries[indices[k]],
                    hasSprite: _spriteUris.contains(entries[indices[k]].uri),
                    extent: math.max(_aspectOf(entries[indices[k]]) * height, 48),
                    devicePixelRatio: dpr,
                    showName: showNames,
                    showSize: showSizes,
                    showDimensions: showDimensions,
                    watched: entries[indices[k]].isVideo && settings.isCloudVisited(entries[indices[k]].uri),
                    progress: _progressOf(entries[indices[k]]),
                    isMosaic: true,
                    onImageInfo: _onTileImageInfo,
                    onAspect: (aspect) => _onTileAspect(entries[indices[k]].uri, aspect),
                    onImagePointerDown: entries[indices[k]].isImage ? () => _pointerImageUri = entries[indices[k]].uri : null,
                    onTap: () => _openEntry(entries, entries[indices[k]]),
                    selectionMode: _selectionMode,
                    isSelected: _selectedEntries.contains(entries[indices[k]]),
                  ),
                ),
            ],
          );
        },
      ),
    ];
  }

  // images laid out in columns of the given height; `height` is the space left
  // below the app bar and the folder list, so the columns always fit exactly
  List<Widget> _buildHorizontalMosaicSlivers(
    BuildContext context,
    List<PurerEntry> entries,
    double columns,
    bool showNames,
    bool showSizes,
    bool showDimensions, {
    required double height,
  }) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cols = _horizontalColsFor(entries, columns, height);

    return [
      SliverList.builder(
        itemCount: cols.length,
        itemBuilder: (context, colIndex) {
          final (indices, colWidth) = cols[colIndex];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var k = 0; k < indices.length; k++)
                SizedBox(
                  width: colWidth,
                  height: colWidth / (_aspectOf(entries[indices[k]]) > 0 ? _aspectOf(entries[indices[k]]) : 1.0),
                  child: _CloudTile(
                    key: ValueKey('${entries[indices[k]].uri}@${settings.cloudThumbnailQuality}@$_thumbnailGeneration'),
                    entry: entries[indices[k]],
                    hasSprite: _spriteUris.contains(entries[indices[k]].uri),
                    extent: math.max(colWidth, 48),
                    devicePixelRatio: dpr,
                    showName: showNames,
                    showSize: showSizes,
                    showDimensions: showDimensions,
                    watched: entries[indices[k]].isVideo && settings.isCloudVisited(entries[indices[k]].uri),
                    progress: _progressOf(entries[indices[k]]),
                    isMosaic: true,
                    onImageInfo: _onTileImageInfo,
                    onAspect: (aspect) => _onTileAspect(entries[indices[k]].uri, aspect),
                    onImagePointerDown: entries[indices[k]].isImage ? () => _pointerImageUri = entries[indices[k]].uri : null,
                    onTap: () => _openEntry(entries, entries[indices[k]]),
                    selectionMode: _selectionMode,
                    isSelected: _selectedEntries.contains(entries[indices[k]]),
                  ),
                ),
            ],
          );
        },
      ),
    ];
  }
}

// play affordance, duration badge and watch progress, stacked on top of a video
// tile whether or not its frame could be extracted
class _VideoOverlay extends StatelessWidget {
  final double? progress;
  final String? durationText;
  final bool showPlayIcon;
  // uri of the video whose sheet is animating in this tile: the play badge then
  // draws the sheet playback progress in its ring
  final String? spriteProgressUri;

  const new({this.progress, this.durationText, this.showPlayIcon = true, this.spriteProgressUri});

  @override
  Widget build(BuildContext context) {
    final value = progress;
    final duration = durationText;
    final hasProgress = value != null && value > 0;
    // keep the bottom row clear of the progress bar
    final bottomInset = hasProgress ? 5.0 : 3.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (showPlayIcon)
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: EdgeInsets.only(left: 3, bottom: bottomInset),
              child: spriteProgressUri == null
                  ? const Icon(
                      Icons.play_circle_outline,
                      color: Colors.white,
                      size: 22,
                      shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                    )
                  : _SpritePlayProgressIcon(uri: spriteProgressUri!),
            ),
          ),
        if (duration != null)
          Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: EdgeInsets.only(right: 3, bottom: bottomInset),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  child: Text(
                    duration,
                    style: const TextStyle(color: Colors.white, fontSize: 11, height: 1.2),
                  ),
                ),
              ),
            ),
          ),
        if (hasProgress)
          Align(
            alignment: Alignment.bottomCenter,
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(Colors.redAccent),
            ),
          ),
      ],
    );
  }
}

// Play affordance of a sprite-animated tile: the ring around the play glyph is
// the sheet's playback progress, so a glance at the tile tells how far the
// little animation is from looping.
class _SpritePlayProgressIcon extends StatelessWidget {
  final String uri;

  const new({required this.uri});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: cloudSpriteProgressNotifier(uri),
      builder: (context, progress, child) => CustomPaint(
        size: const Size(22, 22),
        painter: _SpritePlayProgressPainter(progress),
      ),
    );
  }
}

class _SpritePlayProgressPainter extends CustomPainter {
  final double progress;

  const new(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 1.2;
    // dark disc, so the ring stays visible on a bright frame
    canvas.drawCircle(center, radius + 0.6, Paint()..color = Colors.black45);
    final ringRect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final value = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
    if (value > 0) {
      canvas.drawArc(
        ringRect,
        -math.pi / 2,
        2 * math.pi * value,
        false,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
    final glyph = Path()
      ..moveTo(center.dx - 2.4, center.dy - 4.0)
      ..lineTo(center.dx + 4.2, center.dy)
      ..lineTo(center.dx - 2.4, center.dy + 4.0)
      ..close();
    canvas.drawPath(
      glyph.shift(const Offset(0, 1)),
      Paint()
        ..color = Colors.black54
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
    canvas.drawPath(glyph, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _SpritePlayProgressPainter oldDelegate) => oldDelegate.progress != progress;
}

class _CloudTile extends StatelessWidget {
  final PurerEntry entry;
  // true when this video has a sprite sheet, so the tile animates it and skips
  // extracting a frame
  final bool hasSprite;
  final double extent;
  final double devicePixelRatio;
  final bool isMosaic;
  final bool showName;
  final bool showSize;
  final bool showDimensions;
  final bool watched;
  final double? progress;
  final VoidCallback onTap;
  final void Function(PurerEntry entry, ImageInfo info)? onImageInfo;
  // a sprite sheet's cell aspect ratio is the video's, so it can be learned
  // without extracting a frame
  final void Function(double aspect)? onAspect;
  final bool selectionMode;
  final bool isSelected;
  // only set for image tiles of the mosaic: tells the page that the pointer
  // went down on an image, so the long-press magnifier may start
  final VoidCallback? onImagePointerDown;
  // grid only: long press starts (or extends) a batch selection
  final VoidCallback? onLongPress;

  const new({
    super.key,
    required this.entry,
    required this.extent,
    required this.devicePixelRatio,
    required this.onTap,
    this.hasSprite = false,
    this.isMosaic = false,
    this.showName = false,
    this.showSize = false,
    this.showDimensions = false,
    this.watched = false,
    this.progress,
    this.onImageInfo,
    this.onAspect,
    this.selectionMode = false,
    this.isSelected = false,
    this.onImagePointerDown,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    // options are selected here (rather than read from `settings` directly) so
    // that toggling them applies immediately, even from the options sheet
    final showVideoDuration = context.select<Settings, bool>((s) => s.cloudVideoDurationVisible);
    final showVideoPlayIcon = context.select<Settings, bool>((s) => s.cloudVideoPlayIcon);
    final showThumbnails = context.select<Settings, bool>((s) => s.cloudShowThumbnails);
    Widget content;
    if (!showThumbnails) {
      // nothing is downloaded while thumbnails are off: a tile only says what
      // kind of file it is
      content = _MediaPlaceholder(
        entry: entry,
        icon: entry.isVideo ? Icons.video_file_outlined : Icons.image_outlined,
      );
    } else if (entry.isVideo) {
      final videoThumbnailsEnabled = context.select<Settings, bool>((s) => s.cloudVideoThumbnails);
      content = Stack(
        fit: StackFit.expand,
        children: [
          // stands in until the frame arrives; a contained video leaves
          // letterbox bars, so this is plain instead of the type placeholder
          const ColoredBox(color: Color(0xFF1E222A)),
          // the animation built from a sprite sheet replaces the static frame;
          // when no animation exists this falls back to the frame thumbnail
          _VideoThumbnail(
            entry: entry,
            extent: extent,
            devicePixelRatio: devicePixelRatio,
            isMosaic: isMosaic,
            showLoading: videoThumbnailsEnabled,
            hasSprite: hasSprite,
            onImageInfo: onImageInfo,
            onAspect: onAspect,
          ),
          // the frame is being extracted: say so instead of showing an empty tile
          if (videoThumbnailsEnabled) _VideoLoadingOverlay(entry.uri),
        ],
      );
    } else {
      content = ThumbnailImage(
        entry: entry,
        extent: extent,
        devicePixelRatio: devicePixelRatio,
        fit: BoxFit.cover,
        isMosaic: isMosaic,
        heroTag: null,
        // the bytes are local already; a low-res pass would decode the same
        // file a second time for no benefit on an image tile
        progressive: false,
        // no `errorPlaceholder`: a tile that really cannot be loaded keeps the
        // standard broken-image look instead of becoming an invisible hole
        retryDelays: _cloudThumbnailRetryDelays,
        showLoadingIndicator: true,
        prioritizeOnVisible: true,
        onImageInfo: (info) => onImageInfo?.call(entry, info),
      );
    }
    // videos already watched are dimmed
    if (watched) {
      content = Opacity(opacity: 0.55, child: content);
    }
    if (showName || showSize || showDimensions) {
      final sizeBytes = entry.sizeBytes;
      final sizeText = (showSize && sizeBytes != null) ? formatFileSize(settings.purerLocale, sizeBytes, round: 0) : null;
      final dimensionText = (showDimensions && entry.width > 0 && entry.height > 0) ? '${entry.width} × ${entry.height}' : null;
      final detailsText = [?sizeText, ?dimensionText].join('  ·  ');
      final nameText = showName ? (entry.sourceTitle ?? entry.bestTitle ?? '') : null;
      content = Stack(
        fit: StackFit.expand,
        children: [
          content,
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 3),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (nameText != null)
                    Text(
                      nameText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  if (detailsText.isNotEmpty)
                    Text(
                      detailsText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    if (entry.isVideo) {
      // above the name/size gradient: the badge and the play icon used to be
      // covered by it when file names were shown
      content = Stack(
        fit: StackFit.expand,
        children: [
          content,
          _VideoOverlay(
            progress: progress,
            durationText: _cloudVideoDurationText(entry, visible: showVideoDuration),
            showPlayIcon: showVideoPlayIcon,
            // with a sheet animation the badge's ring tracks its progress
            spriteProgressUri: hasSprite && showVideoPlayIcon && context.select<Settings, bool>((s) => s.cloudSpriteAnimationEnabled) ? entry.uri : null,
          ),
        ],
      );
    }
    if (selectionMode) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          content,
          if (isSelected)
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
                color: Colors.white24,
              ),
            ),
          Positioned(
            top: 6,
            right: 6,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected ? Theme.of(context).colorScheme.primary : const Color(0x99000000),
                border: Border.all(
                  color: isSelected ? Theme.of(context).colorScheme.primary : Colors.white,
                  width: 2,
                ),
                boxShadow: const [
                  BoxShadow(color: Colors.black45, blurRadius: 4, offset: Offset(0, 1)),
                ],
              ),
              child: isSelected ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
            ),
          ),
        ],
      );
    }
    final tile = InkWell(onTap: onTap, onLongPress: onLongPress, child: content);
    final onDown = onImagePointerDown;
    return onDown == null ? tile : Listener(onPointerDown: (_) => onDown(), child: tile);
  }
}

// Video thumbnail that prefers the looping animation built from a sprite sheet,
// if one exists, and otherwise shows the regular extracted frame. A missing or
// broken animation must never leave the tile blank, so any load error falls
// back to the frame thumbnail.
class _VideoThumbnail extends StatefulWidget {
  final PurerEntry entry;
  final double extent;
  final double devicePixelRatio;
  final bool isMosaic;
  final bool showLoading;
  // true when the folder listing already knows this video has a sprite sheet
  final bool hasSprite;
  final void Function(PurerEntry entry, ImageInfo info)? onImageInfo;
  final void Function(double aspect)? onAspect;

  const new({
    required this.entry,
    required this.extent,
    required this.devicePixelRatio,
    required this.isMosaic,
    required this.showLoading,
    this.hasSprite = false,
    this.onImageInfo,
    this.onAspect,
  });

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  // null while checking, then whether an animation is available for this video
  bool? _hasAnimation;
  bool _animationError = false;
  bool _fetchingSprite = false;

  String get _uri => widget.entry.uri;

  @override
  void initState() {
    super.initState();
    cloudSpriteAnimationsVersion.addListener(_onAnimationsInvalidated);
    cloudSpriteAnimationUpdates.addListener(_onSpriteUpdated);
    _check();
  }

  @override
  void didUpdateWidget(covariant _VideoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.uri != _uri || oldWidget.hasSprite != widget.hasSprite) {
      _hasAnimation = null;
      _animationError = false;
      _check();
    } else {
      _maybeFetchSprite();
    }
  }

  @override
  void dispose() {
    cloudSpriteAnimationsVersion.removeListener(_onAnimationsInvalidated);
    cloudSpriteAnimationUpdates.removeListener(_onSpriteUpdated);
    super.dispose();
  }

  void _onAnimationsInvalidated() {
    _animationError = false;
    _check();
  }

  // only this video's sheet changed: the other tiles of the folder do not need
  // to stat the disk again (a global bump made this quadratic while a folder
  // auto-loaded its sheets)
  void _onSpriteUpdated() {
    if (!cloudSpriteAnimationUpdates.value.contains(_uri)) return;
    _animationError = false;
    if (mounted) setState(() => _hasAnimation = true);
  }

  Future<void> _check() async {
    if (!settings.cloudSpriteAnimationEnabled) {
      if (mounted && _hasAnimation != false) setState(() => _hasAnimation = false);
      return;
    }
    final has = await hasCloudSpriteAnimation(_uri);
    if (!mounted) return;
    if (has != _hasAnimation) {
      setState(() {
        _hasAnimation = has;
        // a fresh animation replaces any previous decode failure
        if (has) _animationError = false;
      });
    }
    if (!has) _maybeFetchSprite();
  }

  // Starts the sheet download once, outside of build. The tile prefers the
  // animation when the folder listing says the video has a sheet, and skips
  // extracting a frame that would just be hidden.
  void _maybeFetchSprite() {
    if (_fetchingSprite || _animationError) return;
    if (!settings.cloudSpriteAnimationEnabled || !widget.hasSprite || _hasAnimation == true) return;
    _fetchingSprite = true;
    unawaited(_fetchSpriteNow());
  }

  // the sheet is downloaded: show the animation right away and drop the frame
  void _onAnimationReady() {
    if (!mounted) return;
    _animationError = false;
    if (_hasAnimation != true) setState(() => _hasAnimation = true);
  }

  Widget _buildFrame() => ThumbnailImage(
    // toggling "automatic video thumbnails" must retry a tile that failed
    // while the feature was off, instead of keeping its error placeholder
    key: ValueKey('cloud-frame-${widget.entry.uri}@${widget.showLoading}'),
    entry: widget.entry,
    extent: widget.extent,
    devicePixelRatio: widget.devicePixelRatio,
    // a fixed tile shows the whole frame at its real ratio instead of
    // cropping it; the mosaic already sizes the tile to that ratio
    fit: widget.isMosaic ? BoxFit.cover : BoxFit.contain,
    isMosaic: widget.isMosaic,
    heroTag: null,
    showLoadingBackground: false,
    showLoadingIndicator: widget.showLoading,
    errorPlaceholder: _MediaPlaceholder(entry: widget.entry),
    retryDelays: widget.showLoading ? _cloudThumbnailRetryDelays : const [],
    onImageInfo: (info) => widget.onImageInfo?.call(widget.entry, info),
  );

  @override
  Widget build(BuildContext context) {
    final animationEnabled = settings.cloudSpriteAnimationEnabled;
    // sprite-first: when the video has a sprite sheet, wait for/display its
    // animation and do NOT extract a frame that would just be hidden. A sheet
    // that fails to load falls back to the frame; a video with no sheet shows
    // the frame as usual.
    final preferSprite = animationEnabled && widget.hasSprite && !_animationError;
    if (preferSprite) {
      if (_hasAnimation == true) {
        return CloudSpriteAnimation(
          key: ValueKey('sprite-$_uri@${settings.cloudSpriteAnimationOrder}@${settings.cloudSpriteAnimationSpeed}@${settings.cloudSpriteStartPercent}'),
          uri: _uri,
          order: settings.cloudSpriteAnimationOrder,
          speed: settings.cloudSpriteAnimationSpeed,
          startPercent: settings.cloudSpriteStartPercent,
          // decode the sheet for the cell size this tile is drawn at
          cellDim: (widget.extent * widget.devicePixelRatio).round().clamp(96, 1024),
          // a fixed tile keeps the video's real ratio; the mosaic tile already
          // has that ratio, so it can fill it
          fit: widget.isMosaic ? BoxFit.cover : BoxFit.contain,
          onCellAspect: widget.onAspect,
          onError: () {
            if (mounted && !_animationError) setState(() => _animationError = true);
          },
        );
      }
      // the sheet is on its way: show a spinner instead of a frame that would
      // be hidden as soon as the sheet arrives. The download itself is started
      // by `didUpdateWidget`/`_check`, never as a side effect of build.
      if (!_fetchingSprite && !_animationError) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _maybeFetchSprite();
        });
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          _MediaPlaceholder(entry: widget.entry),
          const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
            ),
          ),
        ],
      );
    }
    // no sprite sheet (or animation disabled): regular extracted frame
    return _buildFrame();
  }

  Future<void> _fetchSpriteNow() async {
    try {
      final service = mediaFetchService;
      if (service is! CloudAwareMediaFetchService) return;
      final ok = await service.animateSpriteThumbnail(_uri);
      if (!mounted) return;
      if (ok == true) {
        _onAnimationReady();
      } else {
        // no sheet after all, or a download/decode failure: keep the frame, so
        // a tile is never stuck on the placeholder
        if (_animationError != true) setState(() => _animationError = true);
      }
    } finally {
      _fetchingSprite = false;
    }
  }
}

// a small spinner over a video tile while its frame is being extracted
class _VideoLoadingOverlay extends StatelessWidget {
  final String uri;

  const new(this.uri);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: cloudGeneratingVideoThumbnails,
      builder: (context, generating, child) {
        if (!generating.contains(uri)) return const SizedBox.shrink();
        return const Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
              child: Padding(
                padding: EdgeInsets.all(5),
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
            ),
          ),
        );
      },
    );
  }
}

// stand-in for a tile whose thumbnail is not drawn: either a video whose frame
// is still being extracted, or any file while thumbnails are turned off. It
// shows the type, which is the useful information a file list needs.
class _MediaPlaceholder extends StatelessWidget {
  final PurerEntry entry;
  final IconData icon;

  const new({required this.entry, this.icon = Icons.video_file_outlined});

  @override
  Widget build(BuildContext context) {
    var ext = (entry.extension ?? '').replaceFirst('.', '').trim();
    if (ext.isEmpty) {
      final name = entry.sourceTitle ?? entry.bestTitle ?? entry.uri;
      final dot = name.lastIndexOf('.');
      if (dot != -1 && dot < name.length - 1) {
        ext = name.substring(dot + 1).split('?').first.split('/').first;
      }
    }
    ext = ext.toUpperCase();

    return ColoredBox(
      color: const Color(0xFF1E222A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 32,
              color: Colors.white.withValues(alpha: 0.65),
            ),
            if (ext.isNotEmpty) ...[
              const SizedBox(height: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 0.5),
                ),
                child: Text(
                  ext,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// over-scroll hint shown while the user is pulling past the end of a mosaic
class _NextFolderHint extends StatelessWidget {
  final ValueListenable<CloudResource?> folder;
  final ValueListenable<double> progress;

  const new({required this.folder, required this.progress});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CloudResource?>(
      valueListenable: folder,
      builder: (context, next, child) {
        if (next == null) return const SizedBox.shrink();
        return ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, child) {
            if (value <= 0) return const SizedBox.shrink();
            final isHorizontal = settings.cloudMosaicScrollDirection == 'horizontal';
            return Align(
              alignment: isHorizontal ? Alignment.centerRight : Alignment.bottomCenter,
              child: Padding(
                padding: isHorizontal ? EdgeInsets.only(right: 16 + MediaQuery.paddingOf(context).right) : EdgeInsets.only(left: 16, right: 16, bottom: 16 + MediaQuery.paddingOf(context).bottom),
                child: IgnorePointer(
                  child: Material(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(24),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(isHorizontal ? Icons.keyboard_arrow_right : Icons.keyboard_arrow_down, color: Colors.white, size: 20),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              context.l10n.cloudNextFolder(next.name),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 72,
                            child: LinearProgressIndicator(
                              value: value.clamp(0.0, 1.0),
                              minHeight: 3,
                              backgroundColor: Colors.white24,
                              valueColor: const AlwaysStoppedAnimation(Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// listing kept in memory so navigating within the trail is instant
class _FolderSnapshot {
  final List<CloudResource> folders;
  final List<PurerEntry> media;

  const new(this.folders, this.media);
}

class _LockedScrollPhysics extends AlwaysScrollableScrollPhysics {
  final bool Function() isLocked;
  const new({super.parent, required this.isLocked});

  @override
  _LockedScrollPhysics applyTo(ScrollPhysics? ancestor) => _LockedScrollPhysics(
    parent: buildParent(ancestor),
    isLocked: isLocked,
  );

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    if (isLocked()) return false;
    return super.shouldAcceptUserOffset(position);
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (isLocked()) return 0.0;
    return super.applyPhysicsToUserOffset(position, offset);
  }
}

// progress of a batch action (delete, rebuild thumbnails, load sprite sheets),
// with an optional cancel button
class _TaskProgressDialog extends StatelessWidget {
  final String title;
  final ValueNotifier<(int, int)> progress;
  final ValueNotifier<bool> cancelled;

  const new({
    required this.title,
    required this.progress,
    required this.cancelled,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<(int, int)>(
      valueListenable: progress,
      builder: (context, value, child) {
        final (done, total) = value;
        return PopScope(
          // the system back button used to dismiss the dialog without
          // cancelling the task, which then kept running invisibly
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            cancelled.value = true;
            Navigator.of(context).pop();
          },
          child: AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: total <= 0 ? null : done / total),
                const SizedBox(height: 12),
                Text(context.l10n.cloudRegenerateProgress(done, total)),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancelled.value = true;
                  Navigator.pop(context);
                },
                child: Text(context.l10n.cancelTooltip),
              ),
            ],
          ),
        );
      },
    );
  }
}
