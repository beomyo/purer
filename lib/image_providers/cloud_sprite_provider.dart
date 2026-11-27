import 'dart:async';
import 'dart:ui' as ui;

import 'package:purer/services/media/cloud_fetch_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

// The screen-space band in which sprite animations are allowed to play. The
// browser page keeps it up to date from the scroll position: it is a band
// centred on the visible list (narrow, by default 20% of the list), stretched
// towards the list start/end when the user is already there, so the first and
// last rows can play as well. `null` means no restriction (100%).
final ValueNotifier<Rect?> cloudSpritePlaybackBand = ValueNotifier(null);

// Playback progress (0..1) of the sheet animation of a video, shared with the
// tile overlay that draws the progress ring around the play icon. A sheet's
// animation is the only writer; every tile of that video listens to the same
// notifier, so the ring always matches the frame on screen.
final Map<String, ValueNotifier<double>> _spriteProgressNotifiers = {};

ValueNotifier<double> cloudSpriteProgressNotifier(String uri) {
  // the notifiers are never removed: a tile that is rebuilt (or a folder that
  // is revisited) must find the same instance the animation is writing to.
  // One double per video seen in the session is a negligible memo.
  return _spriteProgressNotifiers.putIfAbsent(uri, () => ValueNotifier<double>(0));
}

// A tile-sized looping animation of a cloud video, cut straight from its
// downloaded sprite sheet (one JPEG holding a `cols x rows` grid of frames).
//
// The sheet is decoded once, then every frame is drawn by a painter straight
// from it (`Canvas.drawImageRect`), so playing the animation allocates nothing
// and does not re-encode anything. The sheet and the ticker are owned by the
// widget, so scrolling a tile out of the list releases both: a sheet no longer
// on screen does not keep animating in the background.
class CloudSpriteAnimation extends StatefulWidget {
  final String uri;
  // cells are read row by row or column by column, matching how the sheet was
  // packed by the scraper
  final String order;
  // frames per second, independent of the video duration
  final double speed;
  // longest side of one cell in physical pixels: the sheet is decoded for the
  // size the tile is actually shown at, and nearby sizes share one decode
  final int cellDim;
  // percentage of the sheet to skip before the first played frame (0..100).
  // On a 5x5 sheet, 20 drops the first 5 cells and loops over cells 6-25.
  final int startPercent;
  final BoxFit fit;
  // called when the sheet cannot be decoded, so the tile can fall back to the
  // static frame
  final VoidCallback? onError;
  // called once the sheet is decoded with the width/height ratio of one cell,
  // so the mosaic can lay the video out at its real ratio (the sheet is the
  // only aspect information when no frame was extracted)
  final void Function(double aspect)? onCellAspect;

  const new({
    super.key,
    required this.uri,
    required this.order,
    required this.speed,
    required this.cellDim,
    this.startPercent = 0,
    this.fit = BoxFit.cover,
    this.onError,
    this.onCellAspect,
  });

  @override
  State<CloudSpriteAnimation> createState() => _CloudSpriteAnimationState();
}

class _CloudSpriteAnimationState extends State<CloudSpriteAnimation> {
  // shared, reference-counted decoded sheet (see `acquireCloudSpriteSheet`)
  CloudSpriteSheetHandle? _sheet;
  int _cols = 0;
  int _rows = 0;
  int _count = 0;
  // first played cell of the sheet and how many cells are played in a loop
  int _startIndex = 0;
  int _usable = 0;
  Timer? _timer;
  final ValueNotifier<int> _frame = ValueNotifier(0);
  bool _loading = true;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    // a tile rebuilt for a revisited video must not show the progress its
    // previous animation happened to stop at
    cloudSpriteProgressNotifier(widget.uri).value = 0;
    _restartTimer();
    _load();
  }

  // A periodic timer at the animation's own rate: a vsync ticker woke every
  // visible tile up on every display frame (60-120 Hz) even at the default 2 fps.
  void _restartTimer() {
    _timer?.cancel();
    final fps = widget.speed <= 0 ? 2.0 : widget.speed;
    final micros = (1000000 / fps).round();
    _timer = Timer.periodic(Duration(microseconds: micros < 1000 ? 1000 : micros), (_) => _tick());
  }

  void _tick() {
    if (_count <= 0 || _usable <= 0) return;
    // The tile may only advance while it is inside the playback band. The band
    // is updated synchronously by the page on every scroll, so a tile that
    // leaves stops before its next frame; a pinch/mosaic reflow moves tiles
    // without a scroll, hence the re-check on every tick rather than only on
    // band changes.
    if (!_isInPlaybackBand()) return;
    final next = (_frame.value + 1) % _usable;
    _frame.value = next;
    _notifyProgress(next);
  }

  bool _isInPlaybackBand() {
    final band = cloudSpritePlaybackBand.value;
    if (band == null) return true;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached || !renderObject.hasSize) return false;
    final rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    return rect.overlaps(band);
  }

  void _notifyProgress(int frame) {
    final usable = _usable;
    if (usable <= 0) return;
    cloudSpriteProgressNotifier(widget.uri).value = frame / usable;
  }

  void _computeRange() {
    if (_count <= 0) {
      _startIndex = 0;
      _usable = 0;
      return;
    }
    final percent = widget.startPercent.clamp(0, 100);
    _startIndex = (_count * percent / 100).floor().clamp(0, _count - 1);
    _usable = _count - _startIndex;
  }

  @override
  void didUpdateWidget(covariant CloudSpriteAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    // only reload when the decoded size class changes: a pinch changes the
    // extent continuously, and reloading per frame flashed the placeholder
    if (oldWidget.uri != widget.uri || cloudSpriteCellBucket(oldWidget.cellDim) != cloudSpriteCellBucket(widget.cellDim)) {
      _releaseSheet();
      _loading = true;
      _frame.value = 0;
      _load();
    } else if (oldWidget.speed != widget.speed || oldWidget.order != widget.order || oldWidget.startPercent != widget.startPercent) {
      _frame.value = 0;
      if (oldWidget.startPercent != widget.startPercent) {
        _computeRange();
      }
      _notifyProgress(0);
      if (oldWidget.speed != widget.speed) _restartTimer();
    }
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    final sheet = await acquireCloudSpriteSheet(widget.uri, cellDim: widget.cellDim);
    if (!mounted || token != _loadToken) {
      sheet?.release();
      return;
    }
    if (sheet == null) {
      setState(() => _loading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onError?.call();
      });
      return;
    }
    setState(() {
      _sheet = sheet;
      _cols = sheet.cols;
      _rows = sheet.rows;
      _count = sheet.cols * sheet.rows;
      _computeRange();
      _loading = false;
    });
    _frame.value = 0;
    _notifyProgress(0);
    // one cell's aspect ratio is the video's, as packed by the scraper: report
    // it so the mosaic lays the tile out at the real ratio instead of 16:9
    if (sheet.cols > 0 && sheet.rows > 0 && sheet.image.height > 0) {
      final cellW = sheet.image.width / sheet.cols;
      final cellH = sheet.image.height / sheet.rows;
      if (cellH > 0 && cellW > 0) {
        final aspect = cellW / cellH;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onCellAspect?.call(aspect);
        });
      }
    }
  }

  void _releaseSheet() {
    _sheet?.release();
    _sheet = null;
    _cols = 0;
    _rows = 0;
    _count = 0;
    _startIndex = 0;
    _usable = 0;
  }

  @override
  void dispose() {
    _loadToken++;
    _timer?.cancel();
    _timer = null;
    _releaseSheet();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sheet = _sheet;
    if (sheet == null) {
      // the parent already shows a spinner while the sheet is on its way; this
      // only covers the first frames after the tile was created
      return _loading ? const ColoredBox(color: Color(0xFF1E222A)) : const SizedBox.shrink();
    }
    return CustomPaint(
      painter: _SpritePainter(
        sheet: sheet.image,
        cols: _cols,
        rows: _rows,
        order: widget.order,
        frame: _frame,
        startIndex: _startIndex,
        frameCount: _usable,
        fit: widget.fit,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _SpritePainter extends CustomPainter {
  final ui.Image sheet;
  final int cols, rows;
  final String order;
  final ValueListenable<int> frame;
  final int startIndex;
  final int frameCount;
  final BoxFit fit;

  new({
    required this.sheet,
    required this.cols,
    required this.rows,
    required this.order,
    required this.frame,
    required this.startIndex,
    required this.frameCount,
    required this.fit,
  }) : super(repaint: frame);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || cols <= 0 || rows <= 0 || frameCount <= 0) return;
    final index = startIndex + frame.value % frameCount;
    final columnMajor = order == 'columnMajor';
    final col = columnMajor ? index ~/ rows : index % cols;
    final row = columnMajor ? index % rows : index ~/ cols;
    final cellW = sheet.width / cols;
    final cellH = sheet.height / rows;
    final src = Rect.fromLTWH(col * cellW, row * cellH, cellW, cellH);
    final fitted = applyBoxFit(fit, src.size, size);
    final srcRect = Alignment.center.inscribe(fitted.source, Offset.zero & src.size).shift(src.topLeft);
    final dstRect = Alignment.center.inscribe(fitted.destination, Offset.zero & size);
    canvas.drawImageRect(sheet, srcRect, dstRect, Paint()..filterQuality = FilterQuality.medium);
  }

  @override
  bool shouldRepaint(covariant _SpritePainter oldDelegate) =>
      oldDelegate.sheet != sheet || oldDelegate.cols != cols || oldDelegate.rows != rows || oldDelegate.order != order || oldDelegate.startIndex != startIndex || oldDelegate.frameCount != frameCount || oldDelegate.fit != fit;
}
