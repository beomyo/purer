import 'dart:async';
import 'dart:math' as math;

import 'package:purer/model/entry/entry.dart';
import 'package:purer/model/entry/extensions/images.dart';
import 'package:purer/model/entry/extensions/props.dart';
import 'package:purer/model/settings/modules/cloud.dart';
import 'package:purer/model/settings/settings.dart';
import 'package:purer/model/source/cloud/cloud_resource.dart';
import 'package:purer/services/common/cloud_registry.dart';
import 'package:purer/services/common/services.dart';
import 'package:purer/services/media/cloud_client.dart';
import 'package:purer/theme/icons.dart';
import 'package:purer/widgets/common/action_mixins/feedback.dart';
import 'package:purer/widgets/common/basic/scaffold.dart';
import 'package:purer/widgets/common/extensions/build_context.dart';
import 'package:purer/widgets/common/thumbnail/image.dart';
import 'package:purer/widgets/cloud/cloud_options_sheet.dart';
import 'package:purer/widgets/cloud/cloud_transfer_dialog.dart';
import 'package:purer/widgets/cloud/loupe_magnifier.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

// what the viewer's "more" menu can do with the current picture
enum _ViewerAction { save, share, copyLink }

class CloudViewerPage extends StatefulWidget {
  static const routeName = '/cloud/viewer';

  final List<PurerEntry> entries;
  final int initialIndex;
  final String? currentFolderUrl;
  final CloudResource? Function(String? currentFolderUrl)? getNextFolder;
  final Future<List<PurerEntry>> Function(String folderUrl)? loadFolderImages;
  final ValueChanged<String>? onFolderChanged;

  const new({
    super.key,
    required this.entries,
    required this.initialIndex,
    this.currentFolderUrl,
    this.getNextFolder,
    this.loadFolderImages,
    this.onFolderChanged,
  });

  @override
  State<CloudViewerPage> createState() => _CloudViewerPageState();
}

class _CloudViewerPageState extends State<CloudViewerPage> with FeedbackMixin {
  static const double _stripHeight = 76;
  static const double _stripWidth = 68;
  static const double _barWidth = 48;

  late List<PurerEntry> _entries;
  late String? _currentFolderUrl;
  late final int _initialIndex;
  late final PageController _pageController;
  late final ValueNotifier<int> _indexNotifier;
  final GlobalKey<_ContinuousStripViewState> _continuousKey = GlobalKey();

  // paging is blocked while the user pinches or has zoomed in, so trying to
  // zoom never flips to the neighbouring image
  final ValueNotifier<bool> _blockPaging = ValueNotifier(false);
  final ValueNotifier<bool> _autoScrollingNotifier = ValueNotifier(false);

  // Immersive mode state
  bool _immersive = false;
  bool _showProgressBarInImmersive = false;
  bool _showExitImmersiveButton = false;
  Timer? _hideProgressBarTimer;
  Timer? _hideExitTimer;

  // Next album overscroll state
  final ValueNotifier<double> _nextFolderProgress = ValueNotifier(0);
  final ValueNotifier<CloudResource?> _nextFolder = ValueNotifier(null);
  bool _overscrollLocked = false;
  double _overscroll = 0;
  Timer? _overscrollTimer;
  bool _loadingNextAlbum = false;
  // `_loadingNextAlbum` also covers the seamless case, where the spinner must
  // stay hidden until the new album is actually on screen
  bool _showNextAlbumLoading = false;
  Timer? _nextAlbumSpinnerTimer;
  // next albums listed ahead of time, keyed by folder url
  final Map<String, List<PurerEntry>> _prefetchedAlbums = {};
  final Set<String> _prefetchingAlbums = {};

  // Auto page flip state
  final ValueNotifier<bool> _autoFlippingNotifier = ValueNotifier(false);
  Timer? _pageFlipTimer;
  bool _userInteracting = false;

  // Magnifier state
  bool _magnifying = false;
  final ValueNotifier<Offset> _magnifierPosition = ValueNotifier(Offset.zero);
  bool _justTerminatedAutoMotion = false;
  Timer? _magnifierTimer;
  Offset? _magnifierPointerDownPos;
  // a tap that only released the magnifier must not toggle the controls
  bool _suppressTap = false;
  // areas occupied by the chrome (buttons, strip, sliders): a press there must
  // not start the magnifier
  List<Rect> _chromeAreas = const [];
  // the hold of the paged viewer while zoomed, released when paging resumes
  ScrollHoldController? _blockHold;

  @override
  void initState() {
    super.initState();
    _entries = List.of(widget.entries);
    _currentFolderUrl = widget.currentFolderUrl;
    _initialIndex = widget.initialIndex.clamp(0, _entries.isEmpty ? 0 : _entries.length - 1);
    _pageController = PageController(initialPage: _initialIndex);
    _indexNotifier = ValueNotifier(_initialIndex);
    _blockPaging.addListener(_onBlockPagingChanged);
    _indexNotifier.addListener(_onIndexChangedForPrefetch);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _prefetchNeighbors(_initialIndex);
      _prefetchNextAlbum();
    });
  }

  void _onBlockPagingChanged() {
    if (_blockPaging.value && _pageController.hasClients) {
      _blockHold ??= _pageController.position.hold(() {});
    } else {
      _blockHold?.cancel();
      _blockHold = null;
    }
  }

  // Prefetch the neighbouring pictures of the paged viewer: without it a swipe
  // only starts downloading when the page becomes visible.
  void _prefetchNeighbors(int index) {
    for (final i in [index - 1, index + 1]) {
      if (i < 0 || i >= _entries.length) continue;
      final entry = _entries[i];
      if (!entry.isDecodingSupported) continue;
      unawaited(precacheImage(entry.getFullImage(), context).catchError((Object _) {}));
    }
  }

  // The auto motion is about to reach the end of the album: list the next one
  // and decode its first picture, so the switch does not show a spinner or a
  // blurry frame.
  void _onIndexChangedForPrefetch() {
    final remaining = _entries.length - 1 - _indexNotifier.value;
    if (remaining > 2) return;
    _prefetchNextAlbum();
  }

  void _prefetchNextAlbum() {
    if (widget.getNextFolder == null || widget.loadFolderImages == null) return;
    final next = widget.getNextFolder!(_currentFolderUrl);
    if (next == null) return;
    if (_prefetchedAlbums.containsKey(next.url) || !_prefetchingAlbums.add(next.url)) return;
    unawaited(_prefetchAlbum(next));
  }

  Future<void> _prefetchAlbum(CloudResource next) async {
    try {
      final entries = await widget.loadFolderImages!(next.url);
      if (!mounted || entries.isEmpty) return;
      _prefetchedAlbums[next.url] = entries;
      while (_prefetchedAlbums.length > 3) {
        _prefetchedAlbums.remove(_prefetchedAlbums.keys.first);
      }
      // decoding at the viewer's cap makes the swap instant
      final first = entries.firstWhere((e) => e.isDecodingSupported, orElse: () => entries.first);
      if (first.isDecodingSupported) {
        try {
          await precacheImage(first.getFullImage(), context);
        } catch (_) {
          // the image is decoded again when shown
        }
      }
    } catch (_) {
      // best effort: the switch lists the album normally
    } finally {
      _prefetchingAlbums.remove(next.url);
    }
  }

  @override
  void dispose() {
    _indexNotifier.removeListener(_onIndexChangedForPrefetch);
    _nextAlbumSpinnerTimer?.cancel();
    _blockPaging.removeListener(_onBlockPagingChanged);
    _blockHold?.cancel();
    _blockHold = null;
    _cancelPageFlipTimer();
    _autoFlippingNotifier.dispose();
    _pageController.dispose();
    _indexNotifier.dispose();
    _blockPaging.dispose();
    _autoScrollingNotifier.dispose();
    _nextFolderProgress.dispose();
    _nextFolder.dispose();
    _overscrollTimer?.cancel();
    _hideProgressBarTimer?.cancel();
    _hideExitTimer?.cancel();
    _magnifierPosition.dispose();
    _magnifierTimer?.cancel();
    super.dispose();
  }

  void _goTo(int index, {bool animate = false}) {
    if (index < 0 || index >= _entries.length) return;
    if (settings.cloudViewerLayoutMode == 'continuous') {
      _continuousKey.currentState?.scrollToIndex(index, animate: animate);
    } else {
      if (_pageController.hasClients) {
        if (animate) {
          _pageController.animateToPage(index, duration: const Duration(milliseconds: 350), curve: Curves.easeInOutCubic);
        } else {
          _pageController.jumpToPage(index);
        }
      }
    }
  }

  void _cancelAutoFlip() {
    if (_autoFlippingNotifier.value) {
      _autoFlippingNotifier.value = false;
      _cancelPageFlipTimer();
    }
  }

  void _onUserInteractionStart() {
    _userInteracting = true;
  }

  void _onUserInteractionEnd() {
    _userInteracting = false;
    if (_autoFlippingNotifier.value) {
      _scheduleNextPageFlip();
    }
  }

  void _onViewerPointerDown(PointerDownEvent event) {
    // a new gesture starts here: the previous magnifier's tap is over
    _suppressTap = false;
    _onUserInteractionStart();
    // pressing a control (top bar, strip, slider, progress bar) must not start
    // the magnifier over the chrome
    if (_chromeAreas.any((rect) => rect.contains(event.localPosition))) return;
    if (!settings.cloudViewerMagnifierEnabled) return;
    _magnifierPointerDownPos = event.localPosition;
    _magnifierTimer?.cancel();
    _magnifierTimer = Timer(Duration(milliseconds: settings.cloudViewerMagnifierDelay), () {
      if (!mounted) return;
      HapticFeedback.selectionClick();
      _blockPaging.value = true;
      _magnifierPosition.value = event.localPosition;
      // the release must not also toggle the controls
      _suppressTap = true;
      setState(() {
        _magnifying = true;
      });
    });
  }

  void _onViewerPointerMove(PointerMoveEvent event) {
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

  void _onViewerPointerUp(PointerEvent event) {
    final wasMagnifying = _magnifying;
    _magnifierTimer?.cancel();
    _magnifierTimer = null;
    final isTap = _magnifierPointerDownPos != null && (event.localPosition - _magnifierPointerDownPos!).distance < 20.0;
    _magnifierPointerDownPos = null;

    if (wasMagnifying) {
      _blockPaging.value = false;
      setState(() {
        _magnifying = false;
      });
    }

    // in immersive a tap reveals the controls instead (see _onImmersiveTapScreen)
    if (!_suppressTap && isTap && !_immersive && _stopAutoMotionIfRunning()) {
      _justTerminatedAutoMotion = true;
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) _justTerminatedAutoMotion = false;
      });
      _onUserInteractionEnd();
      return;
    }

    _onUserInteractionEnd();
  }

  bool _stopAutoMotionIfRunning() {
    if (_autoScrollingNotifier.value || _autoFlippingNotifier.value) {
      _autoScrollingNotifier.value = false;
      _autoFlippingNotifier.value = false;
      _cancelPageFlipTimer();
      return true;
    }
    return false;
  }

  void _toggleAutoPageFlip() {
    if (_autoScrollingNotifier.value) {
      _autoScrollingNotifier.value = false;
    }
    final next = !_autoFlippingNotifier.value;
    _autoFlippingNotifier.value = next;
    if (next) {
      _scheduleNextPageFlip();
      final sec = settings.cloudViewerAutoPageFlipInterval;
      final secStr = cloudFormatInterval(sec);
      final distPercent = (settings.cloudViewerAutoPageFlipDistance * 100).round();
      showFeedback(context, FeedbackType.info, '${context.l10n.cloudViewerAutoPageFlip} ($secStr / $distPercent%)');
    } else {
      _cancelPageFlipTimer();
    }
  }

  void _scheduleNextPageFlip() {
    _cancelPageFlipTimer();
    if (!mounted || !_autoFlippingNotifier.value) return;
    final intervalMs = (settings.cloudViewerAutoPageFlipInterval * 1000).round();
    _pageFlipTimer = Timer(Duration(milliseconds: math.max(300, intervalMs)), _doPageFlip);
  }

  void _cancelPageFlipTimer() {
    _pageFlipTimer?.cancel();
    _pageFlipTimer = null;
  }

  void _doPageFlip() {
    if (!mounted || !_autoFlippingNotifier.value) return;
    if (_userInteracting || _loadingNextAlbum) {
      // User is actively touching screen or album is loading; check again in 400ms
      _pageFlipTimer = Timer(const Duration(milliseconds: 400), _doPageFlip);
      return;
    }

    if (settings.cloudViewerLayoutMode == 'continuous') {
      _continuousKey.currentState?.flipPage(
        ratio: settings.cloudViewerAutoPageFlipDistance,
        onDone: _scheduleNextPageFlip,
        onReachedEnd: _advanceToNextAlbum,
      );
    } else {
      // Paged mode: flip one page forward
      if (_pageController.hasClients) {
        final cur = _pageController.page?.round() ?? _indexNotifier.value;
        if (cur < _entries.length - 1) {
          _pageController
              .nextPage(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeInOutCubic,
              )
              .then((_) {
                _scheduleNextPageFlip();
              })
              .catchError((_) {
                _scheduleNextPageFlip();
              });
        } else {
          _advanceToNextAlbum();
        }
      } else {
        _scheduleNextPageFlip();
      }
    }
  }

  Future<void> _advanceToNextAlbum() async {
    if (_loadingNextAlbum) return;
    if (widget.getNextFolder == null || widget.loadFolderImages == null) {
      _autoFlippingNotifier.value = false;
      _cancelPageFlipTimer();
      return;
    }
    final next = widget.getNextFolder!(_currentFolderUrl);
    if (next != null) {
      await _loadNextAlbum(next, automatic: true);
      if (_autoFlippingNotifier.value) {
        _scheduleNextPageFlip();
      }
    } else {
      _autoFlippingNotifier.value = false;
      _cancelPageFlipTimer();
    }
  }

  void _toggleAutoScroll() {
    _cancelAutoFlip();
    if (settings.cloudViewerLayoutMode != 'continuous') {
      settings.cloudViewerLayoutMode = 'continuous';
      setState(() {});
    }
    final next = !_autoScrollingNotifier.value;
    _autoScrollingNotifier.value = next;
    if (next) {
      final speedLabel = cloudFormatFactor(settings.cloudViewerAutoScrollSpeed);
      showFeedback(context, FeedbackType.info, '${context.l10n.cloudViewerAutoScroll} ($speedLabel)');
    }
  }

  Widget _immersivePill({required IconData icon, String? label, required VoidCallback onTap, bool active = false}) {
    final color = active ? Theme.of(context).colorScheme.primary : Colors.white;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: label == null ? 10 : 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: active ? color : Colors.white38),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 2)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 20),
              if (label != null) ...[
                const SizedBox(width: 6),
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _toggleImmersive(bool enable) {
    setState(() {
      _immersive = enable;
      _showProgressBarInImmersive = false;
      _showExitImmersiveButton = false;
    });
    _hideProgressBarTimer?.cancel();
    _hideExitTimer?.cancel();
  }

  void _onImmersiveTapScreen() {
    if (_suppressTap) return;
    if (_justTerminatedAutoMotion) return;
    if (!_immersive) {
      // a tap first stops the auto motion; when nothing is moving it hides the
      // chrome, which is what a tap does in a gallery viewer
      if (_stopAutoMotionIfRunning()) return;
      _toggleImmersive(true);
      return;
    }
    // in immersive the chrome is hidden: a tap reveals the controls (including
    // the auto page flip toggle) instead of stopping the motion
    _showImmersiveControls();
  }

  void _showImmersiveControls() {
    setState(() => _showExitImmersiveButton = !_showExitImmersiveButton);
    _restartImmersiveControlsTimer();
  }

  void _restartImmersiveControlsTimer() {
    _hideExitTimer?.cancel();
    if (!_showExitImmersiveButton) return;
    _hideExitTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showExitImmersiveButton = false);
    });
  }

  // starting/stopping the flip from the immersive overlay must not hide the
  // overlay itself, so the state of the toggle can be read while pressing it
  void _toggleAutoPageFlipFromImmersive() {
    _toggleAutoPageFlip();
    _restartImmersiveControlsTimer();
  }

  void _onImmersiveProgressTouch() {
    if (!_immersive) return;
    _hideProgressBarTimer?.cancel();
    if (!_showProgressBarInImmersive) {
      setState(() => _showProgressBarInImmersive = true);
    }
  }

  void _onImmersiveProgressRelease() {
    if (!_immersive) return;
    _hideProgressBarTimer?.cancel();
    _hideProgressBarTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showProgressBarInImmersive = false);
    });
  }

  void _handleOverscroll(double delta) {
    if (_overscrollLocked || _loadingNextAlbum) return;
    if (widget.getNextFolder == null || widget.loadFolderImages == null) return;
    final next = widget.getNextFolder!(_currentFolderUrl);
    if (next == null) return;
    _nextFolder.value = next;
    final isVertical = settings.cloudViewerScrollDirection == 'vertical';
    final threshold = (isVertical ? MediaQuery.sizeOf(context).height : MediaQuery.sizeOf(context).width) / 3;
    _overscroll += delta;
    _nextFolderProgress.value = (_overscroll / threshold).clamp(0.0, 1.0);
    _overscrollTimer?.cancel();
    _overscrollTimer = Timer(const Duration(milliseconds: 700), _resetOverscroll);
    if (_overscroll >= threshold) {
      _resetOverscroll();
      _overscrollLocked = true;
      HapticFeedback.mediumImpact();
      _loadNextAlbum(next);
    }
  }

  void _resetOverscroll() {
    _overscrollTimer?.cancel();
    _overscrollTimer = null;
    _overscroll = 0;
    _nextFolderProgress.value = 0;
    _nextFolder.value = null;
  }

  void _onStripReachedEnd() {
    if (_loadingNextAlbum) return;
    if (widget.getNextFolder == null || widget.loadFolderImages == null) {
      _autoScrollingNotifier.value = false;
      return;
    }
    final next = widget.getNextFolder!(_currentFolderUrl);
    if (next != null) {
      _loadNextAlbum(next, automatic: true);
    } else {
      _autoScrollingNotifier.value = false;
    }
  }

  // `automatic` marks the switch done by the auto motion: only then does the
  // seamless setting apply, a manual over-scroll keeps the loading feedback
  Future<void> _loadNextAlbum(CloudResource next, {bool automatic = false}) async {
    if (_loadingNextAlbum) return;
    final prefetched = _prefetchedAlbums.remove(next.url);
    final seamless = settings.cloudSeamlessSwitch && automatic;
    _nextAlbumSpinnerTimer?.cancel();
    setState(() {
      _loadingNextAlbum = true;
      // 无缝切换：预取就绪时直接替换，不显示转圈；未预取到则先静默等待，
      // 10 秒仍未就绪才显示加载提示（兜底）
      _showNextAlbumLoading = prefetched == null && !seamless;
    });
    if (seamless && prefetched == null) {
      _nextAlbumSpinnerTimer = Timer(const Duration(seconds: 10), () {
        if (!mounted || !_loadingNextAlbum) return;
        setState(() => _showNextAlbumLoading = true);
      });
    }
    try {
      final newEntries = prefetched ?? await widget.loadFolderImages!(next.url);
      if (!mounted) return;
      if (newEntries.isEmpty) {
        showFeedback(context, FeedbackType.warn, context.l10n.cloudViewerAlbumEmpty(next.name));
        _overscrollLocked = false;
        return;
      }
      setState(() {
        _entries = newEntries;
        _currentFolderUrl = next.url;
        _indexNotifier.value = 0;
      });
      widget.onFolderChanged?.call(next.url);
      if (settings.cloudViewerLayoutMode == 'continuous') {
        _continuousKey.currentState?.resetToStart();
      } else {
        if (_pageController.hasClients) {
          _pageController.jumpToPage(0);
        }
      }
      showFeedback(context, FeedbackType.info, context.l10n.cloudViewerNextAlbum(next.name));
    } catch (e) {
      if (mounted) {
        showFeedback(context, FeedbackType.warn, '${context.l10n.cloudViewerNextAlbumError}: ${cloudErrorText(e)}');
      }
    } finally {
      _nextAlbumSpinnerTimer?.cancel();
      _nextAlbumSpinnerTimer = null;
      if (mounted) {
        setState(() {
          _loadingNextAlbum = false;
          _showNextAlbumLoading = false;
        });
        _overscrollLocked = false;
      }
    }
  }

  PurerEntry? get _currentEntry {
    if (_entries.isEmpty) return null;
    return _entries[_indexNotifier.value.clamp(0, _entries.length - 1)];
  }

  String _fileNameOf(PurerEntry entry) => entry.sourceTitle ?? entry.bestTitle ?? 'file';

  Future<void> _onViewerAction(_ViewerAction action) async {
    final entry = _currentEntry;
    if (entry == null) return;
    switch (action) {
      case _ViewerAction.save:
        await _saveEntry(entry);
      case _ViewerAction.share:
        await _shareEntry(entry);
      case _ViewerAction.copyLink:
        await _copyEntryLink(entry);
    }
  }

  Future<void> _saveEntry(PurerEntry entry) async {
    final source = await cloudRegistry.playbackSource(entry.uri);
    if (!mounted) return;
    final result = await runCloudTransfer(
      context,
      title: context.l10n.cloudSaveToPhone,
      run: (transferId, onProgress) => storageService.saveRemoteFile(
        url: source.url,
        headers: source.headers,
        name: _fileNameOf(entry),
        mimeType: entry.mimeType,
        transferId: transferId,
        onProgress: onProgress,
      ),
      cancel: storageService.cancelSaveTransfer,
    );
    if (!mounted) return;
    if (result == null) {
      showFeedback(context, FeedbackType.info, context.l10n.cloudTransferCancelled);
      return;
    }
    showFeedback(
      context,
      result ? FeedbackType.info : FeedbackType.warn,
      result ? context.l10n.genericSuccessFeedback : context.l10n.genericFailureFeedback,
    );
  }

  Future<void> _shareEntry(PurerEntry entry) async {
    final source = await cloudRegistry.playbackSource(entry.uri);
    if (!mounted) return;
    // the file is streamed into the cache first: the dialog stays up until the
    // chooser opens, and can cancel a slow download
    final ok = await runCloudTransfer(
      context,
      title: context.l10n.cloudShare,
      run: (transferId, onProgress) => shareService.shareRemoteFile(
        url: source.url,
        headers: source.headers,
        name: _fileNameOf(entry),
        mimeType: entry.mimeType,
        transferId: transferId,
      ),
      cancel: shareService.cancelShare,
    );
    if (!mounted) return;
    if (ok == null) {
      showFeedback(context, FeedbackType.info, context.l10n.cloudTransferCancelled);
      return;
    }
    if (!ok) showFeedback(context, FeedbackType.warn, context.l10n.genericFailureFeedback);
  }

  Future<void> _copyEntryLink(PurerEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.uri));
    if (!mounted) return;
    showFeedback(context, FeedbackType.info, context.l10n.cloudLinkCopied);
  }

  Future<void> _showCustomSpeedDialog(BuildContext context, StateSetter setSheetState) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudViewerCustomSpeedTitle,
      suffix: 'x',
      initial: settings.cloudViewerAutoScrollSpeed,
      min: CloudSettings.autoScrollSpeedMin,
      max: CloudSettings.autoScrollSpeedMax,
      hint: '3.0',
      minExclusive: true,
    );
    if (result == null) return;
    settings.cloudViewerAutoScrollSpeed = result;
    setSheetState(() {});
    setState(() {});
  }

  Future<void> _showCustomIntervalDialog(BuildContext context, StateSetter setSheetState) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudViewerCustomIntervalTitle,
      suffix: 's',
      initial: settings.cloudViewerAutoPageFlipInterval,
      min: CloudSettings.viewerPageFlipIntervalMin,
      max: CloudSettings.viewerPageFlipIntervalMax,
      hint: '3.0',
      minExclusive: true,
    );
    if (result == null) return;
    settings.cloudViewerAutoPageFlipInterval = result;
    if (_autoFlippingNotifier.value) _scheduleNextPageFlip();
    setSheetState(() {});
    setState(() {});
  }

  Future<void> _showCustomDistanceDialog(BuildContext context, StateSetter setSheetState) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudViewerCustomDistanceTitle,
      suffix: '%',
      initial: (settings.cloudViewerAutoPageFlipDistance * 100).round(),
      min: (CloudSettings.pageFlipDistanceMin * 100).round(),
      max: (CloudSettings.pageFlipDistanceMax * 100).round(),
      hint: '80',
      decimal: false,
    );
    if (result == null) return;
    settings.cloudViewerAutoPageFlipDistance = result / 100.0;
    setSheetState(() {});
    setState(() {});
  }

  Future<void> _showCustomMagnifierDelayDialog(BuildContext context, StateSetter setSheetState) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudCustomMagnifierDelayTitle,
      suffix: 'ms',
      initial: settings.cloudViewerMagnifierDelay,
      min: CloudSettings.magnifierDelayMin,
      max: CloudSettings.magnifierDelayMax,
      hint: '200',
      decimal: false,
    );
    if (result == null) return;
    settings.cloudViewerMagnifierDelay = result.round();
    setSheetState(() {});
    setState(() {});
  }

  Future<void> _showCustomMagnifierScaleDialog(BuildContext context, StateSetter setSheetState) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudCustomMagnifierScaleTitle,
      suffix: 'x',
      initial: settings.cloudViewerMagnifierScale,
      min: CloudSettings.magnifierScaleMin,
      max: CloudSettings.magnifierScaleMax,
      hint: '2.0',
    );
    if (result == null) return;
    settings.cloudViewerMagnifierScale = result;
    setSheetState(() {});
    setState(() {});
  }

  void _openViewerSettings(BuildContext context) {
    final l10n = context.l10n;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
        maxWidth: 1000,
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final mode = settings.cloudViewerLayoutMode;
          final showStrip = settings.cloudViewerThumbnails;
          final stripPos = settings.cloudViewerThumbnailsPosition;
          final showBar = settings.cloudViewerProgressBar;
          final barPos = settings.cloudViewerProgressBarPosition;
          final magnifierOn = settings.cloudViewerMagnifierEnabled;

          // shared with the browser view options, so both sheets look the same
          Widget chipsRow(List<Widget> chips) => cloudOptionChips(context, chips);

          Widget fieldRow({required String label, required List<Widget> chips}) => cloudOptionField(context, label: label, chips: chips);

          // a numeric option as one line (label, minus, value, plus); the value
          // itself opens the exact input dialog, so the preset chips are gone
          Widget numberRow({
            required String label,
            required String valueLabel,
            required double value,
            required double min,
            required double max,
            required double step,
            required ValueChanged<double> onChanged,
            required VoidCallback onTapValue,
          }) =>
              CloudNumberStepper(
                label: label,
                valueLabel: valueLabel,
                value: value,
                min: min,
                max: max,
                step: step,
                onChanged: (v) {
                  onChanged(v);
                  setSheetState(() {});
                  setState(() {});
                },
                onTapValue: onTapValue,
              );

          Widget positionRow({required String label, required String current, required ValueChanged<String> onSelected}) => fieldRow(
            label: label,
            chips: [
              for (final (value, name) in [
                ('bottom', l10n.cloudViewerPositionBottom),
                ('left', l10n.cloudViewerPositionLeft),
                ('right', l10n.cloudViewerPositionRight),
              ])
                ChoiceChip(
                  label: Text(name),
                  selected: current == value,
                  onSelected: (selected) {
                    if (!selected) return;
                    onSelected(value);
                    setSheetState(() {});
                    setState(() {});
                  },
                ),
            ],
          );

          final displaySummary = [
            if (showStrip) l10n.cloudViewerThumbnails,
            if (showBar) l10n.cloudViewerProgressBar,
          ].join(' · ');

          return CloudOptionsSheet(
            title: l10n.cloudViewerSettings,
            header: null,
            children: [
              // browsing mode
              CloudOptionSection(
                icon: Icons.view_carousel_outlined,
                title: l10n.cloudViewerMode,
                summary: mode == 'continuous' ? l10n.cloudViewerModeContinuous : l10n.cloudViewerModePaged,
                children: [
                  chipsRow([
                    ChoiceChip(
                      label: Text(l10n.cloudViewerModePaged),
                      selected: mode == 'paged',
                      onSelected: (selected) {
                        if (!selected) return;
                        settings.cloudViewerLayoutMode = 'paged';
                        setSheetState(() {});
                        setState(() {});
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (_pageController.hasClients) {
                            _pageController.jumpToPage(_indexNotifier.value);
                          }
                        });
                      },
                    ),
                    ChoiceChip(
                      label: Text(l10n.cloudViewerModeContinuous),
                      selected: mode == 'continuous',
                      onSelected: (selected) {
                        if (!selected) return;
                        settings.cloudViewerLayoutMode = 'continuous';
                        setSheetState(() {});
                        setState(() {});
                      },
                    ),
                  ]),
                  fieldRow(
                    label: l10n.cloudScrollDirection,
                    chips: [
                      ChoiceChip(
                        label: Text(l10n.cloudDirectionHorizontal),
                        selected: settings.cloudViewerScrollDirection == 'horizontal',
                        onSelected: (selected) {
                          if (!selected) return;
                          settings.cloudViewerScrollDirection = 'horizontal';
                          setSheetState(() {});
                          setState(() {});
                        },
                      ),
                      ChoiceChip(
                        label: Text(l10n.cloudDirectionVertical),
                        selected: settings.cloudViewerScrollDirection == 'vertical',
                        onSelected: (selected) {
                          if (!selected) return;
                          settings.cloudViewerScrollDirection = 'vertical';
                          setSheetState(() {});
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                ],
              ),
              // auto motion
              CloudOptionSection(
                icon: Icons.play_circle_outline,
                title: l10n.cloudViewerAutoScroll,
                summary: '${cloudFormatFactor(settings.cloudViewerAutoScrollSpeed)} · ${cloudFormatInterval(settings.cloudViewerAutoPageFlipInterval)} · ${(settings.cloudViewerAutoPageFlipDistance * 100).round()}%',
                children: [
                  numberRow(
                    label: l10n.cloudViewerAutoScrollSpeed,
                    valueLabel: cloudFormatFactor(settings.cloudViewerAutoScrollSpeed),
                    value: settings.cloudViewerAutoScrollSpeed,
                    // the discrete step must not land on the setting's
                    // exclusive lower bound
                    min: 0.1,
                    max: CloudSettings.autoScrollSpeedMax,
                    step: 0.5,
                    onChanged: (v) => settings.cloudViewerAutoScrollSpeed = v,
                    onTapValue: () => _showCustomSpeedDialog(context, setSheetState),
                  ),
                  numberRow(
                    label: l10n.cloudViewerAutoPageFlipInterval,
                    valueLabel: cloudFormatInterval(settings.cloudViewerAutoPageFlipInterval),
                    value: settings.cloudViewerAutoPageFlipInterval,
                    min: CloudSettings.viewerPageFlipIntervalMin,
                    max: CloudSettings.viewerPageFlipIntervalMax,
                    step: 0.1,
                    onChanged: (v) {
                      settings.cloudViewerAutoPageFlipInterval = v;
                      if (_autoFlippingNotifier.value) _scheduleNextPageFlip();
                    },
                    onTapValue: () => _showCustomIntervalDialog(context, setSheetState),
                  ),
                  numberRow(
                    label: l10n.cloudViewerAutoPageFlipDistance,
                    valueLabel: '${(settings.cloudViewerAutoPageFlipDistance * 100).round()}%',
                    value: settings.cloudViewerAutoPageFlipDistance,
                    min: CloudSettings.pageFlipDistanceMin,
                    max: CloudSettings.pageFlipDistanceMax,
                    step: 0.05,
                    onChanged: (v) => settings.cloudViewerAutoPageFlipDistance = v,
                    onTapValue: () => _showCustomDistanceDialog(context, setSheetState),
                  ),
                ],
              ),
              // what the viewer shows
              CloudOptionSection(
                icon: Icons.visibility_outlined,
                title: l10n.cloudTabDisplay,
                summary: displaySummary,
                children: [
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: Text(l10n.cloudViewerThumbnails),
                    value: showStrip,
                    onChanged: (v) {
                      settings.cloudViewerThumbnails = v;
                      setSheetState(() {});
                      setState(() {});
                    },
                  ),
                  if (showStrip)
                    positionRow(
                      label: l10n.cloudViewerPosition,
                      current: stripPos,
                      onSelected: (pos) => settings.cloudViewerThumbnailsPosition = pos,
                    ),
                  const Divider(height: 8),
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: Text(l10n.cloudViewerProgressBar),
                    value: showBar,
                    onChanged: (v) {
                      settings.cloudViewerProgressBar = v;
                      setSheetState(() {});
                      setState(() {});
                    },
                  ),
                  if (showBar)
                    positionRow(
                      label: l10n.cloudViewerPosition,
                      current: barPos,
                      onSelected: (pos) => settings.cloudViewerProgressBarPosition = pos,
                    ),
                ],
              ),
              // loupe magnifier
              CloudOptionSection(
                icon: Icons.zoom_in,
                title: l10n.cloudMagnifier,
                summary: magnifierOn ? '${cloudFormatFactor(settings.cloudViewerMagnifierScale)} · ${settings.cloudViewerMagnifierDelay}ms' : null,
                children: [
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: Text(l10n.cloudMagnifier),
                    value: magnifierOn,
                    onChanged: (v) {
                      settings.cloudViewerMagnifierEnabled = v;
                      setSheetState(() {});
                      setState(() {});
                    },
                  ),
                  if (magnifierOn) ...[
                    numberRow(
                      label: l10n.cloudMagnifierDelay,
                      valueLabel: '${settings.cloudViewerMagnifierDelay}ms',
                      value: settings.cloudViewerMagnifierDelay.toDouble(),
                      min: CloudSettings.magnifierDelayMin.toDouble(),
                      max: CloudSettings.magnifierDelayMax.toDouble(),
                      step: 50,
                      onChanged: (v) => settings.cloudViewerMagnifierDelay = v.round(),
                      onTapValue: () => _showCustomMagnifierDelayDialog(context, setSheetState),
                    ),
                    numberRow(
                      label: l10n.cloudMagnifierScale,
                      valueLabel: '${settings.cloudViewerMagnifierScale.toStringAsFixed(1)}x',
                      value: settings.cloudViewerMagnifierScale,
                      min: CloudSettings.magnifierScaleMin,
                      max: CloudSettings.magnifierScaleMax,
                      step: 0.2,
                      onChanged: (v) => settings.cloudViewerMagnifierScale = v,
                      onTapValue: () => _showCustomMagnifierScaleDialog(context, setSheetState),
                    ),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    if (entries.isEmpty) {
      return const PurerScaffold(backgroundColor: Colors.black);
    }
    final showStrip = !_immersive && settings.cloudViewerThumbnails;
    final stripPos = settings.cloudViewerThumbnailsPosition;
    final showProgressBar = settings.cloudViewerProgressBar && entries.length > 1;
    final barPos = settings.cloudViewerProgressBarPosition;
    final layoutMode = settings.cloudViewerLayoutMode;
    final viewerDirection = settings.cloudViewerScrollDirection == 'vertical' ? Axis.vertical : Axis.horizontal;

    final hasBottom = (showProgressBar && barPos == 'bottom') || (showStrip && stripPos == 'bottom');
    final hasLeft = (showProgressBar && barPos == 'left') || (showStrip && stripPos == 'left');
    final hasRight = (showProgressBar && barPos == 'right') || (showStrip && stripPos == 'right');

    final topInset = _immersive ? 0.0 : (MediaQuery.paddingOf(context).top + 52);
    final bottomInset = _immersive ? 0.0 : (MediaQuery.paddingOf(context).bottom + (hasBottom && showStrip ? _stripHeight : 0));

    _updateChromeAreas(
      context,
      showStrip: showStrip,
      stripPos: stripPos,
      showProgressBar: showProgressBar,
      barPos: barPos,
      hasBottom: hasBottom,
      hasLeft: hasLeft,
      hasRight: hasRight,
      topInset: topInset,
      bottomInset: bottomInset,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          Navigator.pop(context, _currentFolderUrl);
        }
      },
      child: PurerScaffold(
        backgroundColor: Colors.black,
        body: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onViewerPointerDown,
          onPointerMove: _onViewerPointerMove,
          onPointerUp: _onViewerPointerUp,
          onPointerCancel: _onViewerPointerUp,
          child: Stack(
            children: [
              if (layoutMode == 'continuous')
                _ContinuousStripView(
                  key: _continuousKey,
                  entries: entries,
                  direction: viewerDirection,
                  indexNotifier: _indexNotifier,
                  initialIndex: _indexNotifier.value,
                  onBlockPaging: (value) => _blockPaging.value = value,
                  autoScrollingNotifier: _autoScrollingNotifier,
                  onPauseAutoScroll: () => _autoScrollingNotifier.value = false,
                  onUserInteractionStart: _onUserInteractionStart,
                  onUserInteractionEnd: _onUserInteractionEnd,
                  onReachedEnd: _onStripReachedEnd,
                  onOverscroll: _handleOverscroll,
                  onScrollBack: _resetOverscroll,
                  onTap: _onImmersiveTapScreen,
                  isMagnifying: _magnifying,
                )
              else
                NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification is OverscrollNotification && notification.metrics.axis == viewerDirection) {
                      if (notification.overscroll > 0 && _indexNotifier.value == entries.length - 1) {
                        _handleOverscroll(notification.overscroll);
                      }
                    }
                    if (notification is ScrollUpdateNotification && notification.metrics.extentAfter > 0) {
                      _resetOverscroll();
                    }
                    return false;
                  },
                  child: Listener(
                    onPointerDown: (_) => _onUserInteractionStart(),
                    onPointerUp: (_) => _onUserInteractionEnd(),
                    onPointerCancel: (_) => _onUserInteractionEnd(),
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _blockPaging,
                      builder: (context, blocked, child) => PageView.builder(
                        controller: _pageController,
                        scrollDirection: viewerDirection,
                        physics: (blocked || _magnifying) ? const NeverScrollableScrollPhysics() : _ViewerPageScrollPhysics(isLocked: () => _blockPaging.value || _magnifying),
                        onPageChanged: (index) {
                          _indexNotifier.value = index;
                          _blockPaging.value = false;
                          _prefetchNeighbors(index);
                        },
                        itemCount: entries.length,
                        itemBuilder: (context, index) => _RemoteImagePage(
                          entry: entries[index],
                          onBlockPaging: (value) => _blockPaging.value = value,
                          onTap: _onImmersiveTapScreen,
                          onUserInteractionStart: _onUserInteractionStart,
                          onUserInteractionEnd: _onUserInteractionEnd,
                        ),
                      ),
                    ),
                  ),
                ),
              // Top app bar
              if (!_immersive && !_magnifying)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    child: Row(
                      children: [
                        IconButton(
                          color: Colors.white,
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context, _currentFolderUrl),
                        ),
                        // the counter used to share the leftover width with a
                        // Spacer, which left it unreadable on 360dp phones
                        Expanded(
                          child: ValueListenableBuilder<int>(
                            valueListenable: _indexNotifier,
                            builder: (context, index, child) => Text(
                              '${index + 1} / ${entries.length}',
                              maxLines: 1,
                              overflow: TextOverflow.fade,
                              softWrap: false,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                shadows: [
                                  Shadow(color: Colors.black87, blurRadius: 4, offset: Offset(0, 1)),
                                ],
                              ),
                            ),
                          ),
                        ),
                        ValueListenableBuilder<bool>(
                          valueListenable: _autoScrollingNotifier,
                          builder: (context, autoScrolling, child) => IconButton(
                            tooltip: context.l10n.cloudViewerAutoScroll,
                            color: autoScrolling ? Theme.of(context).colorScheme.primary : Colors.white,
                            icon: Icon(autoScrolling ? Icons.pause_circle_filled : Icons.play_circle_outline),
                            onPressed: _toggleAutoScroll,
                          ),
                        ),
                        ValueListenableBuilder<bool>(
                          valueListenable: _autoFlippingNotifier,
                          builder: (context, autoFlipping, child) => IconButton(
                            tooltip: context.l10n.cloudViewerAutoPageFlip,
                            color: autoFlipping ? Theme.of(context).colorScheme.primary : Colors.white,
                            icon: Icon(autoFlipping ? Icons.auto_stories : Icons.auto_stories_outlined),
                            onPressed: _toggleAutoPageFlip,
                          ),
                        ),
                        IconButton(
                          tooltip: context.l10n.cloudViewerImmersive,
                          color: Colors.white,
                          icon: const Icon(Icons.fullscreen),
                          onPressed: () => _toggleImmersive(true),
                        ),
                        IconButton(
                          tooltip: context.l10n.cloudViewerSettings,
                          color: Colors.white,
                          icon: const Icon(Icons.tune),
                          onPressed: () => _openViewerSettings(context),
                        ),
                        PopupMenuButton<_ViewerAction>(
                          tooltip: context.l10n.cloudMoreActions,
                          icon: const Icon(Icons.more_vert, color: Colors.white),
                          onSelected: (action) => unawaited(_onViewerAction(action)),
                          itemBuilder: (context) => [
                            PopupMenuItem(value: _ViewerAction.save, child: Text(context.l10n.cloudSaveToPhone)),
                            PopupMenuItem(value: _ViewerAction.share, child: Text(context.l10n.cloudShare)),
                            PopupMenuItem(value: _ViewerAction.copyLink, child: Text(context.l10n.cloudCopyLink)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              // Immersive controls: revealed by a tap. They include the auto page
              // flip toggle, so the motion can be driven without leaving immersive.
              if (_immersive && _showExitImmersiveButton && !_magnifying)
                Positioned(
                  top: MediaQuery.paddingOf(context).top + 16,
                  right: 16,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ValueListenableBuilder<bool>(
                        valueListenable: _autoFlippingNotifier,
                        builder: (context, autoFlipping, child) => _immersivePill(
                          icon: autoFlipping ? Icons.auto_stories : Icons.auto_stories_outlined,
                          active: autoFlipping,
                          onTap: _toggleAutoPageFlipFromImmersive,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _immersivePill(
                        icon: Icons.fullscreen_exit,
                        label: context.l10n.cloudViewerExitImmersive,
                        onTap: () => _toggleImmersive(false),
                      ),
                    ],
                  ),
                ),
              // Left overlay
              if (hasLeft && !_magnifying)
                Positioned(
                  left: 0,
                  top: topInset,
                  bottom: bottomInset,
                  child: Padding(
                    padding: EdgeInsets.only(left: MediaQuery.paddingOf(context).left),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (showProgressBar && barPos == 'left')
                          Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerDown: (_) => _onImmersiveProgressTouch(),
                            onPointerUp: (_) => _onImmersiveProgressRelease(),
                            onPointerCancel: (_) => _onImmersiveProgressRelease(),
                            child: AnimatedOpacity(
                              opacity: _immersive ? (_showProgressBarInImmersive ? 1.0 : 0.0) : 1.0,
                              duration: const Duration(milliseconds: 200),
                              child: SizedBox(
                                width: _barWidth,
                                child: _ImageProgressBar(
                                  count: entries.length,
                                  index: _indexNotifier,
                                  onIndexChanged: _goTo,
                                  axis: Axis.vertical,
                                ),
                              ),
                            ),
                          ),
                        if (showStrip && stripPos == 'left')
                          Container(
                            color: const Color(0xCC000000),
                            width: _stripWidth,
                            child: _ThumbnailStrip(
                              entries: entries,
                              index: _indexNotifier,
                              onTap: _goTo,
                              axis: Axis.vertical,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              // Right overlay
              if (hasRight && !_magnifying)
                Positioned(
                  right: 0,
                  top: topInset,
                  bottom: bottomInset,
                  child: Padding(
                    padding: EdgeInsets.only(right: MediaQuery.paddingOf(context).right),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (showStrip && stripPos == 'right')
                          Container(
                            color: const Color(0xCC000000),
                            width: _stripWidth,
                            child: _ThumbnailStrip(
                              entries: entries,
                              index: _indexNotifier,
                              onTap: _goTo,
                              axis: Axis.vertical,
                            ),
                          ),
                        if (showProgressBar && barPos == 'right')
                          Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerDown: (_) => _onImmersiveProgressTouch(),
                            onPointerUp: (_) => _onImmersiveProgressRelease(),
                            onPointerCancel: (_) => _onImmersiveProgressRelease(),
                            child: AnimatedOpacity(
                              opacity: _immersive ? (_showProgressBarInImmersive ? 1.0 : 0.0) : 1.0,
                              duration: const Duration(milliseconds: 200),
                              child: SizedBox(
                                width: _barWidth,
                                child: _ImageProgressBar(
                                  count: entries.length,
                                  index: _indexNotifier,
                                  onIndexChanged: _goTo,
                                  axis: Axis.vertical,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              // Bottom overlay
              if (hasBottom && !_magnifying)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (showProgressBar && barPos == 'bottom')
                          Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerDown: (_) => _onImmersiveProgressTouch(),
                            onPointerUp: (_) => _onImmersiveProgressRelease(),
                            onPointerCancel: (_) => _onImmersiveProgressRelease(),
                            child: AnimatedOpacity(
                              opacity: _immersive ? (_showProgressBarInImmersive ? 1.0 : 0.0) : 1.0,
                              duration: const Duration(milliseconds: 200),
                              child: _ImageProgressBar(
                                count: entries.length,
                                index: _indexNotifier,
                                onIndexChanged: _goTo,
                                axis: Axis.horizontal,
                              ),
                            ),
                          ),
                        if (showStrip && stripPos == 'bottom')
                          Container(
                            color: const Color(0xCC000000),
                            height: _stripHeight,
                            child: _ThumbnailStrip(
                              entries: entries,
                              index: _indexNotifier,
                              onTap: _goTo,
                              axis: Axis.horizontal,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              // Next album overscroll hint
              _NextAlbumHint(folder: _nextFolder, progress: _nextFolderProgress),
              // Loading spinner when switching albums (hidden while the seamless
              // switch is waiting for a prefetched album)
              if (_showNextAlbumLoading)
                const Center(
                  child: Card(
                    color: Color(0xCC000000),
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
                ),
              // Magnifier overlay
              if (_magnifying)
                FullscreenZoomMagnifier(
                  positionNotifier: _magnifierPosition,
                  scale: settings.cloudViewerMagnifierScale,
                ),
            ],
          ),
        ),
      ),
    );
  }

  // The magnifier must not start over the chrome (buttons, thumbnail strip,
  // sliders), which are drawn on top of the picture. Their rectangles are
  // computed here, from the same locals the build uses.
  void _updateChromeAreas(
    BuildContext context, {
    required bool showStrip,
    required String stripPos,
    required bool showProgressBar,
    required String barPos,
    required bool hasBottom,
    required bool hasLeft,
    required bool hasRight,
    required double topInset,
    required double bottomInset,
  }) {
    final screen = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final areas = <Rect>[];
    if (!_immersive && !_magnifying) {
      areas.add(Rect.fromLTRB(0, 0, screen.width, padding.top + 52));
    }
    if (_immersive && _showExitImmersiveButton && !_magnifying) {
      areas.add(Rect.fromLTRB(screen.width - 220, 0, screen.width, padding.top + 72));
    }
    if (!_magnifying && hasLeft) {
      final width = (showStrip && stripPos == 'left' ? _stripWidth : 0.0) + (showProgressBar && barPos == 'left' ? _barWidth : 0.0) + padding.left;
      areas.add(Rect.fromLTRB(0, topInset, width, screen.height - bottomInset));
    }
    if (!_magnifying && hasRight) {
      final width = (showStrip && stripPos == 'right' ? _stripWidth : 0.0) + (showProgressBar && barPos == 'right' ? _barWidth : 0.0) + padding.right;
      areas.add(Rect.fromLTRB(screen.width - width, topInset, screen.width, screen.height - bottomInset));
    }
    if (!_magnifying && hasBottom) {
      final height = (showStrip && stripPos == 'bottom' ? _stripHeight : 0.0) + (showProgressBar && barPos == 'bottom' ? 48.0 : 0.0) + padding.bottom;
      areas.add(Rect.fromLTRB(0, screen.height - height, screen.width, screen.height));
    }
    _chromeAreas = areas;
  }
}

class _StripScrollPhysics extends ClampingScrollPhysics {
  final bool Function() isLocked;
  const new({super.parent, required this.isLocked});

  @override
  _StripScrollPhysics applyTo(ScrollPhysics? ancestor) => _StripScrollPhysics(
    parent: buildParent(ancestor),
    isLocked: isLocked,
  );

  @override
  double get dragStartDistanceMotionThreshold => 28;

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    if (isLocked()) return false;
    return super.shouldAcceptUserOffset(position);
  }
}

// continuous horizontal/vertical strip view that places all images side by side seamlessly with zoom support
class _ContinuousStripView extends StatefulWidget {
  final List<PurerEntry> entries;
  final Axis direction;
  final ValueNotifier<int> indexNotifier;
  final int initialIndex;
  final ValueChanged<bool> onBlockPaging;
  final ValueListenable<bool> autoScrollingNotifier;
  final VoidCallback? onPauseAutoScroll;
  final VoidCallback? onUserInteractionStart;
  final VoidCallback? onUserInteractionEnd;
  final VoidCallback? onReachedEnd;
  final ValueChanged<double>? onOverscroll;
  final VoidCallback? onScrollBack;
  final VoidCallback? onTap;
  final bool isMagnifying;

  const new({
    super.key,
    required this.entries,
    this.direction = Axis.horizontal,
    required this.indexNotifier,
    required this.initialIndex,
    required this.onBlockPaging,
    required this.autoScrollingNotifier,
    this.onPauseAutoScroll,
    this.onUserInteractionStart,
    this.onUserInteractionEnd,
    this.onReachedEnd,
    this.onOverscroll,
    this.onScrollBack,
    this.onTap,
    this.isMagnifying = false,
  });

  @override
  State<_ContinuousStripView> createState() => _ContinuousStripViewState();
}

class _ContinuousStripViewState extends State<_ContinuousStripView> with TickerProviderStateMixin {
  static const double _doubleTapScale = 2.5;

  late final ScrollController _scrollController;
  final TransformationController _transformationController = TransformationController();
  late final AnimationController _zoomAnimation;
  late final CurvedAnimation _zoomCurve;
  late final Ticker _autoScrollTicker;
  Duration _lastTick = Duration.zero;
  Matrix4Tween? _zoomTween;
  Offset? _doubleTapPosition;
  bool _zoomed = false;
  bool _multiTouch = false;
  int _pointers = 0;
  bool _updatingIndexFromScroll = false;
  bool _isScrollingToIndex = false;
  final Map<String, double> _aspects = {};
  int _aspectsVersion = 0;
  // cumulative item extents, so a scroll offset maps to an index in O(log n)
  // instead of walking every entry on each scroll event
  List<double>? _prefixSums;
  List<PurerEntry>? _prefixEntries;
  Axis? _prefixAxis;
  double _prefixCross = 0;
  int _prefixVersion = -1;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _zoomAnimation = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    _zoomCurve = CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeOutCubic)..addListener(_onZoomTick);
    _transformationController.addListener(_onTransformChanged);
    widget.indexNotifier.addListener(_onExternalIndexChanged);
    _autoScrollTicker = createTicker(_onAutoScrollTick);
    widget.autoScrollingNotifier.addListener(_onAutoScrollingChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.initialIndex > 0) {
        scrollToIndex(widget.initialIndex, animate: false);
      }
      if (widget.autoScrollingNotifier.value) {
        _onAutoScrollingChanged();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _ContinuousStripView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.entries, widget.entries)) {
      _aspects.clear();
      resetToStart();
    }
  }

  @override
  void dispose() {
    if (_zoomed || _multiTouch) {
      final notify = widget.onBlockPaging;
      WidgetsBinding.instance.addPostFrameCallback((_) => notify(false));
    }
    widget.indexNotifier.removeListener(_onExternalIndexChanged);
    widget.autoScrollingNotifier.removeListener(_onAutoScrollingChanged);
    _autoScrollTicker.dispose();
    _scrollController.dispose();
    _zoomCurve
      ..removeListener(_onZoomTick)
      ..dispose();
    _zoomAnimation.dispose();
    _transformationController.removeListener(_onTransformChanged);
    _transformationController.dispose();
    super.dispose();
  }

  void resetToStart() {
    _aspects.clear();
    _aspectsVersion++;
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    _updatingIndexFromScroll = true;
    widget.indexNotifier.value = 0;
    _updatingIndexFromScroll = false;
  }

  void _onAutoScrollTick(Duration elapsed) {
    if (!widget.autoScrollingNotifier.value || !_scrollController.hasClients) return;
    if (_lastTick == Duration.zero) {
      _lastTick = elapsed;
      return;
    }
    final dt = (elapsed - _lastTick).inMicroseconds / 1000000.0;
    _lastTick = elapsed;
    if (dt <= 0 || dt > 0.1) return;
    final speed = settings.cloudViewerAutoScrollSpeed * 60.0; // base speed 60 px/s
    final max = _scrollController.position.maxScrollExtent;
    final current = _scrollController.offset;
    if (current >= max - 0.5) {
      widget.onReachedEnd?.call();
      return;
    }
    final next = (current + speed * dt).clamp(0.0, max);
    _scrollController.jumpTo(next);
    _updateIndexFromOffset();
  }

  void _onAutoScrollingChanged() {
    if (widget.autoScrollingNotifier.value) {
      _lastTick = Duration.zero;
      if (!_autoScrollTicker.isActive) {
        _autoScrollTicker.start();
      }
    } else {
      if (_autoScrollTicker.isActive) {
        _autoScrollTicker.stop();
      }
      _lastTick = Duration.zero;
    }
  }

  double _aspectOf(PurerEntry entry) {
    final cached = _aspects[entry.uri];
    if (cached != null) return cached;
    if (entry.width > 0 && entry.height > 0) {
      return (entry.width / entry.height).clamp(0.2, 5.0);
    }
    final dim = settings.cloudImageDimensions(entry.uri);
    if (dim != null && dim.$1 > 0 && dim.$2 > 0) {
      return (dim.$1 / dim.$2).clamp(0.2, 5.0);
    }
    return (entry.isVideo ? 16 / 9 : 1.0);
  }

  void _onImageInfo(PurerEntry entry, ImageInfo info) {
    final w = info.image.width;
    final h = info.image.height;
    if (w > 0 && h > 0) {
      entry.width = w;
      entry.height = h;
      settings.setCloudImageDimensions(entry.uri, w, h);
      final aspect = (w / h).clamp(0.2, 5.0);
      if (_aspects[entry.uri] != aspect) {
        _aspects[entry.uri] = aspect;
        _aspectsVersion++;
        if (mounted) setState(() {});
      }
    }
  }

  List<double> _prefixSumsFor(double crossDim) {
    final cached = _prefixSums;
    if (cached != null &&
        identical(_prefixEntries, widget.entries) &&
        _prefixAxis == widget.direction &&
        _prefixCross == crossDim &&
        _prefixVersion == _aspectsVersion) {
      return cached;
    }
    final isVertical = widget.direction == Axis.vertical;
    final n = widget.entries.length;
    final sums = List<double>.filled(n, 0);
    var acc = 0.0;
    for (var i = 0; i < n; i++) {
      final aspect = _aspectOf(widget.entries[i]);
      acc += isVertical ? math.max(48.0, crossDim / aspect) : math.max(48.0, crossDim * aspect);
      sums[i] = acc;
    }
    _prefixSums = sums;
    _prefixEntries = widget.entries;
    _prefixAxis = widget.direction;
    _prefixCross = crossDim;
    _prefixVersion = _aspectsVersion;
    return sums;
  }

  void _onZoomTick() {
    final tween = _zoomTween;
    if (tween != null) {
      _transformationController.value = tween.evaluate(_zoomCurve);
    }
  }

  void _onTransformChanged() {
    final zoomed = _transformationController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) {
      if (mounted) {
        setState(() => _zoomed = zoomed);
      } else {
        _zoomed = zoomed;
      }
      _notify();
    }
  }

  void _setMultiTouch(bool value) {
    if (value == _multiTouch) return;
    _multiTouch = value;
    _notify();
  }

  void _notify() => widget.onBlockPaging(_zoomed || _multiTouch);

  void _onPointerDown(PointerDownEvent event) {
    if (widget.autoScrollingNotifier.value) {
      widget.onPauseAutoScroll?.call();
    }
    widget.onUserInteractionStart?.call();
    _pointers++;
    if (_pointers >= 2) {
      _setMultiTouch(true);
      if (_scrollController.hasClients) {
        _scrollController.position.hold(() {});
      }
      if (mounted) setState(() {});
    }
  }

  void _onPointerUp(PointerEvent event) {
    _pointers = math.max(0, _pointers - 1);
    if (_pointers == 0) {
      widget.onUserInteractionEnd?.call();
    }
    if (_pointers < 2) {
      _setMultiTouch(false);
      if (mounted) setState(() {});
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointers = 0;
    _setMultiTouch(false);
    widget.onUserInteractionEnd?.call();
    if (mounted) setState(() {});
  }

  void _handleDoubleTap() {
    final target = _zoomed ? Matrix4.identity() : _zoomMatrix(_doubleTapPosition ?? Offset.zero, _doubleTapScale);
    _zoomTween = Matrix4Tween(begin: _transformationController.value.clone(), end: target);
    _zoomAnimation.forward(from: 0);
  }

  Matrix4 _zoomMatrix(Offset focal, double scale) {
    final size = context.size ?? Size.zero;
    final maxX = math.max(0.0, size.width * (scale - 1));
    final maxY = math.max(0.0, size.height * (scale - 1));
    final tx = (-focal.dx * (scale - 1)).clamp(-maxX, 0.0);
    final ty = (-focal.dy * (scale - 1)).clamp(-maxY, 0.0);
    return Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _onExternalIndexChanged() {
    if (_updatingIndexFromScroll) return;
    scrollToIndex(widget.indexNotifier.value);
  }

  void scrollToIndex(int index, {bool animate = true}) {
    if (!_scrollController.hasClients || index < 0 || index >= widget.entries.length) return;
    final isVertical = widget.direction == Axis.vertical;
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final sums = _prefixSumsFor(isVertical ? viewportWidth : viewportHeight);
    final offset = index <= 0 ? 0.0 : sums[index - 1];
    final target = offset.clamp(0.0, _scrollController.position.maxScrollExtent);
    if (animate) {
      _isScrollingToIndex = true;
      _scrollController
          .animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut)
          .then((_) {
            _isScrollingToIndex = false;
            _updateIndexFromOffset();
          })
          .catchError((_) {
            _isScrollingToIndex = false;
            _updateIndexFromOffset();
          });
    } else {
      _scrollController.jumpTo(target);
      _updateIndexFromOffset();
    }
  }

  void flipPage({
    required double ratio,
    VoidCallback? onDone,
    VoidCallback? onReachedEnd,
  }) {
    if (!_scrollController.hasClients) {
      onDone?.call();
      return;
    }
    final max = _scrollController.position.maxScrollExtent;
    final current = _scrollController.offset;
    if (current >= max - 1.0) {
      onReachedEnd?.call();
      return;
    }
    final isVertical = widget.direction == Axis.vertical;
    final mainDimension = isVertical ? MediaQuery.sizeOf(context).height : MediaQuery.sizeOf(context).width;
    final delta = mainDimension * ratio;
    final target = (current + delta).clamp(0.0, max);
    if ((target - current).abs() < 1.0) {
      onReachedEnd?.call();
      return;
    }
    _scrollController
        .animateTo(
          target,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOutCubic,
        )
        .then((_) {
          _updateIndexFromOffset();
          onDone?.call();
        })
        .catchError((_) {
          _updateIndexFromOffset();
          onDone?.call();
        });
  }

  void _updateIndexFromOffset() {
    if (_isScrollingToIndex || !_scrollController.hasClients) return;
    final isVertical = widget.direction == Axis.vertical;
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final sums = _prefixSumsFor(isVertical ? viewportWidth : viewportHeight);
    if (sums.isEmpty) return;
    final center = _scrollController.offset + (isVertical ? viewportHeight : viewportWidth) / 2;
    // first cumulative extent past the centre of the viewport
    var lo = 0, hi = sums.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sums[mid] < center) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final centerIndex = lo;
    if (widget.indexNotifier.value != centerIndex) {
      _updatingIndexFromScroll = true;
      widget.indexNotifier.value = centerIndex;
      _updatingIndexFromScroll = false;
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is OverscrollNotification && notification.metrics.axis == widget.direction) {
      if (notification.overscroll > 0 && notification.metrics.extentAfter <= 0) {
        widget.onOverscroll?.call(notification.overscroll);
      }
    }
    if (notification is ScrollUpdateNotification && notification.metrics.extentAfter > 0) {
      widget.onScrollBack?.call();
    }
    if (notification is ScrollUpdateNotification) {
      _updateIndexFromOffset();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
        onDoubleTap: _handleDoubleTap,
        child: InteractiveViewer(
          transformationController: _transformationController,
          panEnabled: _zoomed && !widget.isMagnifying,
          minScale: 1.0,
          maxScale: 6.0,
          onInteractionStart: (details) {
            if (details.pointerCount >= 2) {
              _setMultiTouch(true);
              if (_scrollController.hasClients) {
                _scrollController.position.hold(() {});
              }
              if (mounted) setState(() {});
            }
          },
          onInteractionUpdate: (details) {
            if (details.pointerCount >= 2 && !_multiTouch) {
              _setMultiTouch(true);
              if (_scrollController.hasClients) {
                _scrollController.position.hold(() {});
              }
              if (mounted) setState(() {});
            }
          },
          onInteractionEnd: (details) {
            if (_pointers < 2 && _multiTouch) {
              _setMultiTouch(false);
              if (mounted) setState(() {});
            }
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: ListView.builder(
              controller: _scrollController,
              scrollDirection: widget.direction,
              scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
              physics: (_zoomed || _multiTouch || _pointers >= 2 || widget.isMagnifying) ? const NeverScrollableScrollPhysics() : _StripScrollPhysics(isLocked: () => _zoomed || _multiTouch || _pointers >= 2 || widget.isMagnifying),
              itemCount: widget.entries.length,
              itemBuilder: (context, index) {
                final entry = widget.entries[index];
                final aspect = _aspectOf(entry);
                if (widget.direction == Axis.vertical) {
                  final itemHeight = math.max(48.0, viewportWidth / aspect);
                  return SizedBox(
                    width: viewportWidth,
                    height: itemHeight,
                    child: _StripTile(
                      entry: entry,
                      onImageInfo: (info) => _onImageInfo(entry, info),
                    ),
                  );
                } else {
                  final itemWidth = math.max(48.0, viewportHeight * aspect);
                  return SizedBox(
                    height: viewportHeight,
                    width: itemWidth,
                    child: _StripTile(
                      entry: entry,
                      onImageInfo: (info) => _onImageInfo(entry, info),
                    ),
                  );
                }
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _StripTile extends StatelessWidget {
  final PurerEntry entry;
  final ValueChanged<ImageInfo>? onImageInfo;

  const new({required this.entry, this.onImageInfo});

  @override
  Widget build(BuildContext context) {
    if (!entry.isDecodingSupported) {
      return const Center(child: Icon(AIcons.error, color: Colors.white54, size: 48));
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: entry.bestCachedThumbnail,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, error, stack) => const SizedBox.shrink(),
        ),
        _CloudFullImage(entry: entry, onImageInfo: onImageInfo),
      ],
    );
  }
}

// Full resolution image of a cloud entry: shows the cached thumbnail behind it,
// a spinner while it downloads/decodes, and a retry action when the cached
// bytes cannot be decoded (instead of leaving the user with a bare error icon).
class _CloudFullImage extends StatefulWidget {
  final PurerEntry entry;
  // reports the decoded dimensions (continuous mode lays items out from them)
  final ValueChanged<ImageInfo>? onImageInfo;

  const new({required this.entry, this.onImageInfo});

  @override
  State<_CloudFullImage> createState() => _CloudFullImageState();
}

class _CloudFullImageState extends State<_CloudFullImage> {
  int _attempt = 0;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant _CloudFullImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.uri != widget.entry.uri) {
      _unsubscribe();
      _subscribe();
    }
  }

  void _subscribe() {
    final onImageInfo = widget.onImageInfo;
    if (onImageInfo == null || !widget.entry.isDecodingSupported) return;
    final stream = widget.entry.getFullImage().resolve(ImageConfiguration.empty);
    _stream = stream;
    _listener = ImageStreamListener(
      (info, _) => onImageInfo(info),
      onError: (error, stack) {},
    );
    stream.addListener(_listener!);
  }

  void _unsubscribe() {
    final listener = _listener;
    if (_stream != null && listener != null) _stream!.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  void _retry() {
    // the cached payload may be truncated/corrupt: drop it so the next resolve
    // downloads the file again
    PaintingBinding.instance.imageCache.evict(widget.entry.getFullImage());
    setState(() => _attempt++);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.entry.isDecodingSupported) {
      return const Center(child: Icon(AIcons.error, color: Colors.white54, size: 48));
    }
    return Image(
      key: ValueKey('cloud-full-${widget.entry.uri}@$_attempt'),
      image: widget.entry.getFullImage(),
      fit: BoxFit.contain,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 180),
              child: child,
            ),
            if (frame == null)
              const Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                ),
              ),
          ],
        );
      },
      errorBuilder: (context, error, stack) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(AIcons.error, color: Colors.white54, size: 48),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(context.l10n.webdavRefresh),
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}

// paging that needs a longer, more deliberate drag than the default, which
// avoids changing image when the user meant to pinch
class _ViewerPageScrollPhysics extends PageScrollPhysics {
  final bool Function()? isLocked;
  const new({super.parent, this.isLocked});

  @override
  _ViewerPageScrollPhysics applyTo(ScrollPhysics? ancestor) => _ViewerPageScrollPhysics(
    parent: buildParent(ancestor),
    isLocked: isLocked,
  );

  @override
  double get dragStartDistanceMotionThreshold => 40;

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    if (isLocked?.call() ?? false) return false;
    return super.shouldAcceptUserOffset(position);
  }
}

class _RemoteImagePage extends StatefulWidget {
  final PurerEntry entry;
  final ValueChanged<bool> onBlockPaging;
  final VoidCallback? onTap;
  final VoidCallback? onUserInteractionStart;
  final VoidCallback? onUserInteractionEnd;

  const new({
    required this.entry,
    required this.onBlockPaging,
    this.onTap,
    this.onUserInteractionStart,
    this.onUserInteractionEnd,
  });

  @override
  State<_RemoteImagePage> createState() => _RemoteImagePageState();
}

class _RemoteImagePageState extends State<_RemoteImagePage> with SingleTickerProviderStateMixin {
  static const double _doubleTapScale = 2.5;

  final TransformationController _transformationController = TransformationController();
  late final AnimationController _zoomAnimation;
  late final CurvedAnimation _zoomCurve;
  Matrix4Tween? _zoomTween;
  Offset? _doubleTapPosition;
  bool _zoomed = false;
  bool _multiTouch = false;
  int _pointers = 0;

  @override
  void initState() {
    super.initState();
    _zoomAnimation = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    _zoomCurve = CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeOutCubic)..addListener(_onZoomTick);
    _transformationController.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    if (_zoomed || _multiTouch) {
      final notify = widget.onBlockPaging;
      WidgetsBinding.instance.addPostFrameCallback((_) => notify(false));
    }
    _zoomCurve
      ..removeListener(_onZoomTick)
      ..dispose();
    _zoomAnimation.dispose();
    _transformationController.removeListener(_onTransformChanged);
    _transformationController.dispose();
    super.dispose();
  }

  void _onZoomTick() {
    final tween = _zoomTween;
    if (tween != null) {
      _transformationController.value = tween.evaluate(_zoomCurve);
    }
  }

  void _onTransformChanged() {
    final zoomed = _transformationController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) {
      if (mounted) {
        setState(() {
          _zoomed = zoomed;
        });
      } else {
        _zoomed = zoomed;
      }
      _notify();
    }
  }

  void _setMultiTouch(bool value) {
    if (value == _multiTouch) return;
    _multiTouch = value;
    _notify();
  }

  void _notify() => widget.onBlockPaging(_zoomed || _multiTouch);

  void _onPointerDown(PointerDownEvent event) {
    widget.onUserInteractionStart?.call();
    _pointers++;
    if (_pointers >= 2) {
      _setMultiTouch(true);
      if (mounted) setState(() {});
    }
  }

  void _onPointerUp(PointerEvent event) {
    _pointers = math.max(0, _pointers - 1);
    if (_pointers == 0) {
      widget.onUserInteractionEnd?.call();
    }
    if (_pointers < 2) {
      _setMultiTouch(false);
      if (mounted) setState(() {});
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointers = 0;
    _setMultiTouch(false);
    widget.onUserInteractionEnd?.call();
    if (mounted) setState(() {});
  }

  void _handleDoubleTap() {
    final target = _zoomed ? Matrix4.identity() : _zoomMatrix(_doubleTapPosition ?? Offset.zero, _doubleTapScale);
    _zoomTween = Matrix4Tween(begin: _transformationController.value.clone(), end: target);
    _zoomAnimation.forward(from: 0);
  }

  Matrix4 _zoomMatrix(Offset focal, double scale) {
    final size = context.size ?? Size.zero;
    final maxX = math.max(0.0, size.width * (scale - 1));
    final maxY = math.max(0.0, size.height * (scale - 1));
    final tx = (-focal.dx * (scale - 1)).clamp(-maxX, 0.0);
    final ty = (-focal.dy * (scale - 1)).clamp(-maxY, 0.0);
    return Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.entry.isDecodingSupported) {
      // still handle taps, so stopping the auto motion and revealing the
      // immersive controls keep working on a file that cannot be shown
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: const Center(child: Icon(AIcons.error, color: Colors.white54, size: 48)),
      );
    }
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
        onDoubleTap: _handleDoubleTap,
        child: InteractiveViewer(
          transformationController: _transformationController,
          panEnabled: _zoomed,
          minScale: 1,
          maxScale: 6,
          onInteractionStart: (details) {
            if (details.pointerCount >= 2) {
              _setMultiTouch(true);
              if (mounted) setState(() {});
            }
          },
          onInteractionUpdate: (details) {
            if (details.pointerCount >= 2 && !_multiTouch) {
              _setMultiTouch(true);
              if (mounted) setState(() {});
            }
          },
          onInteractionEnd: (details) {
            if (_pointers < 2 && _multiTouch) {
              _setMultiTouch(false);
              if (mounted) setState(() {});
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image(
                image: widget.entry.bestCachedThumbnail,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (context, error, stack) => const SizedBox.shrink(),
              ),
              _CloudFullImage(entry: widget.entry),
            ],
          ),
        ),
      ),
    );
  }
}

// strip of thumbnails used to jump quickly between nearby images (supports horizontal or vertical axis)
class _ThumbnailStrip extends StatefulWidget {
  final List<PurerEntry> entries;
  final ValueNotifier<int> index;
  final ValueChanged<int> onTap;
  final Axis axis;

  const new({
    required this.entries,
    required this.index,
    required this.onTap,
    this.axis = Axis.horizontal,
  });

  @override
  State<_ThumbnailStrip> createState() => _ThumbnailStripState();
}

class _ThumbnailStripState extends State<_ThumbnailStrip> {
  static const double _thumbSize = 52;
  static const double _itemExtent = 56;

  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _notCancellable = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    widget.index.addListener(_center);
    WidgetsBinding.instance.addPostFrameCallback((_) => _center());
  }

  @override
  void dispose() {
    widget.index.removeListener(_center);
    _scrollController.dispose();
    _notCancellable.dispose();
    super.dispose();
  }

  DateTime _lastCenterAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _center() {
    if (!_scrollController.hasClients) return;
    final viewport = _scrollController.position.viewportDimension;
    final target = (widget.index.value * _itemExtent - (viewport - _itemExtent) / 2).clamp(0.0, _scrollController.position.maxScrollExtent);
    // while scrolling continuously the index changes many times in a row:
    // restarting a 200ms animation each time made the strip lag behind. Only a
    // deliberate jump (a tap, a page flip) is animated.
    final now = DateTime.now();
    final animate = now.difference(_lastCenterAt) > const Duration(milliseconds: 300);
    _lastCenterAt = now;
    if (animate) {
      _scrollController.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    } else {
      _scrollController.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final isVertical = widget.axis == Axis.vertical;
    return ListView.builder(
      controller: _scrollController,
      scrollDirection: widget.axis,
      padding: EdgeInsets.symmetric(
        horizontal: isVertical ? 4 : 8,
        vertical: isVertical ? 8 : 4,
      ),
      itemCount: widget.entries.length,
      itemBuilder: (context, index) => ValueListenableBuilder<int>(
        valueListenable: widget.index,
        builder: (context, current, child) => GestureDetector(
          onTap: () => widget.onTap(index),
          child: Container(
            width: _thumbSize,
            height: _thumbSize,
            margin: EdgeInsets.symmetric(
              horizontal: isVertical ? 4 : 2,
              vertical: isVertical ? 2 : 10,
            ),
            decoration: BoxDecoration(
              border: Border.all(color: index == current ? Colors.white : Colors.white24, width: index == current ? 2 : 1),
            ),
            child: ThumbnailImage(
              entry: widget.entries[index],
              extent: _thumbSize,
              devicePixelRatio: dpr,
              fit: BoxFit.cover,
              cancellableNotifier: _notCancellable,
            ),
          ),
        ),
      ),
    );
  }
}

class _ImageProgressBar extends StatefulWidget {
  final int count;
  final ValueListenable<int> index;
  final ValueChanged<int> onIndexChanged;
  final Axis axis;

  const new({
    required this.count,
    required this.index,
    required this.onIndexChanged,
    this.axis = Axis.horizontal,
  });

  @override
  State<_ImageProgressBar> createState() => _ImageProgressBarState();
}

class _ImageProgressBarState extends State<_ImageProgressBar> {
  static const _textStyle = TextStyle(
    color: Colors.white,
    fontSize: 12,
    fontFeatures: [FontFeature.tabularFigures()],
    shadows: [
      Shadow(color: Colors.black87, blurRadius: 4, offset: Offset(0, 1)),
      Shadow(color: Colors.black54, blurRadius: 8),
    ],
  );
  int? _dragIndex;

  @override
  Widget build(BuildContext context) {
    if (widget.count <= 1) return const SizedBox.shrink();

    final isVertical = widget.axis == Axis.vertical;

    return ValueListenableBuilder<int>(
      valueListenable: widget.index,
      builder: (context, index, child) {
        final current = (_dragIndex ?? index).clamp(0, widget.count - 1);
        final max = (widget.count - 1).toDouble();

        final sliderTheme = SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            tickMarkShape: SliderTickMarkShape.noTickMark,
            activeTrackColor: Colors.white,
            inactiveTrackColor: Colors.white38,
            thumbColor: Colors.white,
            overlayColor: Colors.transparent,
          ),
          child: Slider(
            value: current.toDouble().clamp(0.0, max),
            min: 0,
            max: max,
            divisions: widget.count - 1,
            // dragging only previews the target: switching pages on every
            // step queued a full-size download for each picture passed over
            onChanged: (v) {
              final target = v.round().clamp(0, widget.count - 1);
              if (target != _dragIndex) setState(() => _dragIndex = target);
            },
            onChangeEnd: (v) {
              final target = v.round().clamp(0, widget.count - 1);
              widget.onIndexChanged(target);
              setState(() => _dragIndex = null);
            },
          ),
        );

        if (isVertical) {
          return Column(
            mainAxisSize: MainAxisSize.max,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text('${current + 1}\n/\n${widget.count}', style: _textStyle, textAlign: TextAlign.center),
              ),
              Expanded(
                child: RotatedBox(
                  quarterTurns: 1,
                  child: sliderTheme,
                ),
              ),
              const SizedBox(height: 8),
            ],
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(child: sliderTheme),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text('${current + 1}/${widget.count}', style: _textStyle),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NextAlbumHint extends StatelessWidget {
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
            return Positioned(
              right: 16,
              bottom: 96,
              child: SafeArea(
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xE6101010),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white24),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 2)),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.arrow_forward, color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 160),
                          child: Text(
                            context.l10n.cloudViewerNextAlbum(next.name),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 56,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: value.clamp(0.0, 1.0),
                              minHeight: 4,
                              backgroundColor: Colors.white24,
                              valueColor: const AlwaysStoppedAnimation(Colors.white),
                            ),
                          ),
                        ),
                      ],
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
