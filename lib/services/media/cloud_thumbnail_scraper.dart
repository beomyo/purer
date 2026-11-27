import 'dart:async';
import 'dart:math' as math;

import 'package:purer/model/settings/settings.dart';
import 'package:purer/model/source/cloud/cloud_resource.dart';
import 'package:purer/ref/mime_types.dart';
import 'package:purer/services/common/cloud_registry.dart';
import 'package:purer/services/common/services.dart';
import 'package:purer/services/log/purer_log.dart';
import 'package:purer/services/media/cloud_client.dart';
import 'package:purer/services/media/cloud_fetch_service.dart';
import 'package:purer/services/media/cloud_media_cache.dart';
import 'package:purer/services/media/cloud_mime.dart';
import 'package:flutter/foundation.dart';

enum CloudScrapePhase {
  idle('空闲'),
  scanning('读取文件夹'),
  scraping('生成缩略图'),
  finished('已完成');

  final String label;

  new(this.label);
}

enum CloudScrapeItemState {
  pending('待处理'),
  running('处理中'),
  generated('已生成'),
  cached('已存在'),
  failed('失败'),
  // the failure of an earlier run is recorded in the cache folder, so this run
  // skipped the video without reading it; an individual retry is still offered
  skipped('已跳过');

  final String label;

  new(this.label);
}

class CloudScrapeItem {
  final String url;
  final String name;
  final String folderUrl;
  final CloudScrapeItemState state;
  // why it failed, shown in the result list
  final String? reason;
  final String? detail;
  final int attempts;
  final int? durationMillis;
  final double? percent;

  const new({
    required this.url,
    required this.name,
    required this.folderUrl,
    this.state = CloudScrapeItemState.pending,
    this.reason,
    this.detail,
    this.attempts = 0,
    this.durationMillis,
    this.percent,
  });

  CloudScrapeItem copyWith({
    CloudScrapeItemState? state,
    String? reason,
    String? detail,
    bool clearReason = false,
    bool clearDetail = false,
    int? attempts,
    int? durationMillis,
    double? percent,
  }) {
    return CloudScrapeItem(
      url: url,
      name: name,
      folderUrl: folderUrl,
      state: state ?? this.state,
      reason: clearReason ? null : (reason ?? this.reason),
      detail: clearDetail ? null : (detail ?? this.detail),
      attempts: attempts ?? this.attempts,
      durationMillis: durationMillis ?? this.durationMillis,
      percent: percent ?? this.percent,
    );
  }
}

// Everything the scrape page shows: what is being processed right now, the
// running counts, and what each video ended up as (with the reason of the
// failing ones).
class CloudScrapeProgress {
  final bool running;
  // a run already ended (completed, stopped, or failed): lets the settings
  // page report an empty folder too, not only folders with videos
  final bool finished;
  // the run was stopped by the user before it drained the queue
  final bool stopped;
  // the stopped run still has work left, so it can be continued instead of
  // starting over
  final bool canResume;
  final CloudScrapePhase phase;
  // the run works through folders as they are listed, so the total is unknown
  // until it ends; only a retry of a fixed failure list knows it up front
  final bool totalKnown;
  // the run only retries the failed items of the previous run
  final bool retrying;
  final int foldersScanned;
  final int foldersDone;
  // folders that could not be listed (permissions, network, server error)
  final int foldersFailed;
  // videos found so far
  final int discovered;
  final int processed;
  final int generated;
  final int cached;
  final int failed;
  // videos skipped because an earlier failure was recorded in the cache folder
  final int skipped;
  final String currentFolder;
  final String? error;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final List<CloudScrapeItem> items;
  // the item list is bounded: a huge library is counted but not all kept
  final bool itemsTruncated;

  const new({
    this.running = false,
    this.finished = false,
    this.stopped = false,
    this.canResume = false,
    this.phase = CloudScrapePhase.idle,
    this.totalKnown = false,
    this.retrying = false,
    this.foldersScanned = 0,
    this.foldersDone = 0,
    this.foldersFailed = 0,
    this.discovered = 0,
    this.processed = 0,
    this.generated = 0,
    this.cached = 0,
    this.failed = 0,
    this.skipped = 0,
    this.currentFolder = '',
    this.error,
    this.startedAt,
    this.finishedAt,
    this.items = const [],
    this.itemsTruncated = false,
  });

  int get pending => math.max(0, discovered - processed);

  // null while a full run is still working through unknown folders, so the
  // bar can animate instead of showing a made up percentage. Once the run
  // stopped or finished, the value is fixed: an idle or completed page must
  // not keep an indeterminate progress bar moving forever.
  double? get fraction {
    if (!running) {
      if (discovered <= 0) return finished ? 1.0 : 0.0;
      return (processed / discovered).clamp(0.0, 1.0);
    }
    if (!totalKnown) return null;
    if (discovered <= 0) return 0.0;
    return (processed / discovered).clamp(0.0, 1.0);
  }

  Duration? get elapsed {
    final start = startedAt;
    if (start == null) return null;
    return (finishedAt ?? DateTime.now()).difference(start);
  }

  CloudScrapeProgress copyWith({
    bool? running,
    bool? finished,
    bool? stopped,
    bool? canResume,
    CloudScrapePhase? phase,
    bool? totalKnown,
    bool? retrying,
    int? foldersScanned,
    int? foldersDone,
    int? foldersFailed,
    int? discovered,
    int? processed,
    int? generated,
    int? cached,
    int? failed,
    int? skipped,
    String? currentFolder,
    String? error,
    bool clearError = false,
    DateTime? startedAt,
    DateTime? finishedAt,
    bool clearFinishedAt = false,
    List<CloudScrapeItem>? items,
    bool? itemsTruncated,
  }) {
    return CloudScrapeProgress(
      running: running ?? this.running,
      finished: finished ?? this.finished,
      stopped: stopped ?? this.stopped,
      canResume: canResume ?? this.canResume,
      phase: phase ?? this.phase,
      totalKnown: totalKnown ?? this.totalKnown,
      retrying: retrying ?? this.retrying,
      foldersScanned: foldersScanned ?? this.foldersScanned,
      foldersDone: foldersDone ?? this.foldersDone,
      foldersFailed: foldersFailed ?? this.foldersFailed,
      discovered: discovered ?? this.discovered,
      processed: processed ?? this.processed,
      generated: generated ?? this.generated,
      cached: cached ?? this.cached,
      failed: failed ?? this.failed,
      skipped: skipped ?? this.skipped,
      currentFolder: currentFolder ?? this.currentFolder,
      error: clearError ? null : (error ?? this.error),
      startedAt: startedAt ?? this.startedAt,
      finishedAt: clearFinishedAt ? null : (finishedAt ?? this.finishedAt),
      items: items ?? this.items,
      itemsTruncated: itemsTruncated ?? this.itemsTruncated,
    );
  }
}

class _PendingVideo {
  final String url;
  final String name;
  final String folderUrl;
  final String mimeType;

  const new(this.url, this.name, this.folderUrl, this.mimeType);
}

// mutable counters of a run, mirrored into the immutable progress snapshot
class _RunCounters {
  int foldersScanned = 0;
  int foldersDone = 0;
  int foldersFailed = 0;
  int discovered = 0;
  int processed = 0;
  int generated = 0;
  int cached = 0;
  int failed = 0;
  int skipped = 0;
  // a video was discovered but could not be kept in the bounded item list
  bool itemsTruncated = false;
}

// State of one scrape, kept across a stop so the run can be continued exactly
// where it stopped: the folder queue, the videos of the folder in progress,
// and the counters already reported.
class _ScrapeRun {
  final bool retrying;
  final _RunCounters counters = _RunCounters();
  // for a normal run: every discovered video; for a retry: the failed items
  final List<CloudScrapeItem> items = [];
  final Map<String, int> durations = {};
  final Set<String> visited = {};
  final List<String> stack = [];
  // normal run: the folder whose videos are being processed
  String? folder;
  List<_PendingVideo> videos = const [];
  Map<String, CloudCachedFrame> frames = const {};
  // recordings of failed videos of the folder in progress, keyed by video name
  Map<String, CloudFailedVideo> failures = const {};
  int folderStartIndex = 0;
  int nextVideo = 0;
  // retry run: index into `items`
  int nextRetryItem = 0;
  bool cancelled = false;
  Future<void>? driving;

  new({required this.retrying});

  bool get hasRemainingWork => retrying ? nextRetryItem < items.length : nextVideo < videos.length || stack.isNotEmpty;
}

// Walks a remote folder and builds missing video thumbnails in the background,
// at the same rate limit as the thumbnails requested while browsing.
//
// Folders are listed and scraped as they are reached (depth first), so the work
// starts with the first folder instead of after a long scan of the whole tree.
// The frames are stored in the local disk cache and, when configured, in the
// shared WebDAV cache, which mirrors the remote tree and puts the duration in
// the file name (`00.10.00_vid.mp4.jpg`). A folder's mirror is listed once per
// scrape, so videos that already have a frame are skipped without reading the
// video or requesting anything per video.
class CloudThumbnailScraper {
  static const int _maxItems = 20000;
  // the scrape feeds the same extraction budget as browsing: a few workers,
  // and the shared semaphore/rate limiter inside the service decide when a
  // request may actually start
  static const int _scrapeConcurrency = 4;

  final ValueNotifier<CloudScrapeProgress> progress = ValueNotifier(const CloudScrapeProgress());
  _ScrapeRun? _run;
  // a single-video retry is not a run: it edits one item in place, so it is
  // keyed by a token instead of a `_ScrapeRun`
  Object? _retryToken;
  CloudScrapeProgress? _retryBase;
  int? _retryItemIndex;
  CloudScrapeItem? _retryItemOriginal;

  bool get isRunning => progress.value.running;

  // `folderUrl` is a collection of any configured cloud service, typically the
  // one currently browsed. Subfolders are scraped recursively.
  Future<void> start(String folderUrl) async {
    if (isRunning || folderUrl.isEmpty) return;
    final cloudService = _cloudService();
    if (cloudService == null) {
      _run = null;
      progress.value = const CloudScrapeProgress(finished: true, phase: CloudScrapePhase.finished, error: '媒体服务不可用');
      return;
    }

    final run = _ScrapeRun(retrying: false);
    run.stack.add(folderUrl);
    _run = run;
    progress.value = CloudScrapeProgress(
      running: true,
      phase: CloudScrapePhase.scanning,
      currentFolder: folderUrl,
      startedAt: DateTime.now(),
    );
    purerLog.info(PurerLogCategory.scrape, '开始刮削 ${PurerLog.redactUrl(folderUrl)} 起始文件夹限速=${settings.cloudThumbnailRateForFolder(folderUrl)}/s');

    run.driving = _drive(run);
    await run.driving;
  }

  // continues a stopped run from the folder/video it reached, keeping the
  // counters and item states already reported
  Future<void> resume() async {
    final run = _run;
    if (run == null || isRunning) return;
    final current = progress.value;
    if (!current.stopped || !run.hasRemainingWork) return;
    // the stopped run may still have a video in flight: let it settle before
    // the same state is driven again
    await run.driving;
    if (!identical(_run, run) || isRunning) return;
    run.cancelled = false;
    progress.value = progress.value.copyWith(
      running: true,
      finished: false,
      stopped: false,
      canResume: false,
      phase: run.folder != null ? CloudScrapePhase.scraping : CloudScrapePhase.scanning,
      clearFinishedAt: true,
      clearError: true,
    );
    purerLog.info(PurerLogCategory.scrape, '继续刮削 processed=${run.counters.processed}');
    run.driving = _drive(run);
    await run.driving;
  }

  // runs again only the videos whose last attempt failed
  Future<void> retryFailed() async {
    if (isRunning) return;
    final previous = progress.value;
    final failed = previous.items.where((i) => i.state == CloudScrapeItemState.failed).toList();
    if (failed.isEmpty) return;
    final cloudService = _cloudService();
    if (cloudService == null) return;

    final run = _ScrapeRun(retrying: true);
    run.items.addAll(failed);
    run.counters.discovered = failed.length;
    _run = run;
    progress.value = CloudScrapeProgress(
      running: true,
      phase: CloudScrapePhase.scraping,
      totalKnown: true,
      retrying: true,
      discovered: failed.length,
      currentFolder: failed.first.folderUrl,
      startedAt: DateTime.now(),
      items: failed,
    );
    purerLog.info(PurerLogCategory.scrape, '重试失败项 count=${failed.length}');

    run.driving = _drive(run);
    await run.driving;
  }

  // Retries one video on its own and keeps it in place in the result list:
  // the per-item action of the scrape page, and the only way to try a video
  // whose earlier failure was recorded in the cache folder and is therefore
  // skipped by the folder runs. The rest of the finished run is preserved, so
  // a stopped run can still be resumed afterwards.
  Future<void> retryItem(CloudScrapeItem item) async {
    if (isRunning) return;
    final cloudService = _cloudService();
    if (cloudService == null) return;
    // a stopped run may still have a video in flight: let it settle, so its
    // final publish does not overwrite the item this retry is working on
    final stoppedRun = _run;
    if (stoppedRun != null) await stoppedRun.driving;
    if (isRunning) return;
    final base = progress.value;
    final index = base.items.indexWhere((i) => i.url == item.url);
    if (index < 0) return;

    final token = Object();
    _retryToken = token;
    _retryBase = base;
    _retryItemIndex = index;
    _retryItemOriginal = base.items[index];
    final items = List<CloudScrapeItem>.of(base.items);
    items[index] = items[index].copyWith(state: CloudScrapeItemState.running, clearReason: true, clearDetail: true);
    progress.value = base.copyWith(
      running: true,
      finished: false,
      stopped: false,
      canResume: false,
      retrying: true,
      totalKnown: true,
      phase: CloudScrapePhase.scraping,
      currentFolder: item.folderUrl,
      startedAt: DateTime.now(),
      clearFinishedAt: true,
      clearError: true,
      items: items,
    );
    purerLog.info(PurerLogCategory.scrape, '单项重试 ${PurerLog.redactUrl(item.url)}');

    CloudScrapeItem updated = items[index];
    try {
      // the user asks for this video again: the recorded failure must not make
      // the attempt answer from the old record
      await cloudMediaCache.clearFailure(item.url);
      await cloudService.waitForFrameUploads(item.folderUrl);
      final listing = await cloudMediaCache.listing(item.folderUrl, refresh: true);
      final known = listing.frames[item.name];
      if (known != null) {
        updated = _settledItem(
          item,
          CloudScrapeItemState.cached,
          durationMillis: known.durationMillis ?? settings.cloudVideoDuration(item.url),
        );
        final duration = known.durationMillis;
        if (duration != null) settings.mergeCloudVideoDurations({item.url: duration});
      } else {
        final result = await cloudService.scrapeVideoThumbnail(item.url, mimeType: cloudMimeForName(item.name), ignoreCooldown: true);
        final duration = result.durationMillis ?? settings.cloudVideoDuration(item.url);
        if (duration != null) settings.mergeCloudVideoDurations({item.url: duration});
        if (result.cached) {
          updated = _settledItem(item, CloudScrapeItemState.cached, durationMillis: duration, percent: result.percent);
        } else if (result.ok) {
          updated = _settledItem(item, CloudScrapeItemState.generated, durationMillis: duration, percent: result.percent, attempts: result.attempts);
        } else {
          updated = item.copyWith(
            state: CloudScrapeItemState.failed,
            reason: result.failure?.label ?? CloudVideoThumbnailFailure.unknown.label,
            detail: result.message,
            attempts: result.attempts,
            durationMillis: duration,
          );
          await _recordFailure(item.url, result);
        }
      }
      if (!identical(_retryToken, token)) return;
      items[index] = updated;
    } catch (error) {
      if (!identical(_retryToken, token)) return;
      items[index] = item.copyWith(
        state: CloudScrapeItemState.failed,
        reason: CloudVideoThumbnailFailure.unknown.label,
        detail: '$error',
        attempts: item.attempts + 1,
      );
      purerLog.error(PurerLogCategory.scrape, '单项重试失败 ${PurerLog.redactUrl(item.url)} error=$error');
    } finally {
      if (identical(_retryToken, token)) {
        _retryToken = null;
        _retryBase = null;
        _retryItemIndex = null;
        _retryItemOriginal = null;
        // a stopped run keeps its own list and counters: write the retried item
        // there too, so a later resume publishes the same result
        final run = _run;
        if (run != null && identical(run.items, base.items)) {
          run.items[index] = items[index];
          _applyStateChangeToCounters(run.counters, item.state, items[index].state);
        }
        progress.value = _countsForTransition(base, item.state, items[index].state).copyWith(
          running: false,
          finished: true,
          stopped: base.stopped,
          canResume: base.canResume,
          retrying: base.retrying,
          totalKnown: base.totalKnown,
          phase: CloudScrapePhase.finished,
          currentFolder: base.currentFolder,
          items: items,
        );
        purerLog.info(PurerLogCategory.scrape, '单项重试结束 ${PurerLog.redactUrl(item.url)} state=${items[index].state.name}');
      }
    }
  }

  // a settled item of a single-video retry: a fresh entry, so a previous
  // failure reason never sticks to an item that succeeded
  static CloudScrapeItem _settledItem(
    CloudScrapeItem item,
    CloudScrapeItemState state, {
    int? durationMillis,
    double? percent,
    int attempts = 0,
  }) {
    return CloudScrapeItem(
      url: item.url,
      name: item.name,
      folderUrl: item.folderUrl,
      state: state,
      attempts: attempts,
      durationMillis: durationMillis,
      percent: percent,
    );
  }

  // a progress snapshot with one item moving from one state to another: the
  // per-video retry changes its outcome, so the result counts follow
  static CloudScrapeProgress _countsForTransition(CloudScrapeProgress p, CloudScrapeItemState from, CloudScrapeItemState to) {
    if (from == to) return p;
    var generated = p.generated;
    var cached = p.cached;
    var failed = p.failed;
    var skipped = p.skipped;
    void adjust(CloudScrapeItemState state, int delta) {
      switch (state) {
        case CloudScrapeItemState.generated:
          generated = math.max(0, generated + delta);
        case CloudScrapeItemState.cached:
          cached = math.max(0, cached + delta);
        case CloudScrapeItemState.failed:
          failed = math.max(0, failed + delta);
        case CloudScrapeItemState.skipped:
          skipped = math.max(0, skipped + delta);
        case CloudScrapeItemState.pending:
        case CloudScrapeItemState.running:
          break;
      }
    }

    adjust(from, -1);
    adjust(to, 1);
    return p.copyWith(generated: generated, cached: cached, failed: failed, skipped: skipped);
  }

  // a run's counters after one item moved from one state to another
  static void _applyStateChangeToCounters(_RunCounters counters, CloudScrapeItemState from, CloudScrapeItemState to) {
    void adjust(CloudScrapeItemState state, int delta) {
      switch (state) {
        case CloudScrapeItemState.generated:
          counters.generated = math.max(0, counters.generated + delta);
        case CloudScrapeItemState.cached:
          counters.cached = math.max(0, counters.cached + delta);
        case CloudScrapeItemState.failed:
          counters.failed = math.max(0, counters.failed + delta);
        case CloudScrapeItemState.skipped:
          counters.skipped = math.max(0, counters.skipped + delta);
        case CloudScrapeItemState.pending:
        case CloudScrapeItemState.running:
          break;
      }
    }

    adjust(from, -1);
    adjust(to, 1);
  }

  // `CloudVideoThumbnailFailure.name` as stored in a failure marker, back to
  // the failure it describes (the page shows its label)
  static CloudVideoThumbnailFailure? _failureFromToken(String? token) {
    if (token == null || token.isEmpty) return null;
    final lower = token.toLowerCase();
    for (final failure in CloudVideoThumbnailFailure.values) {
      if (failure.name.toLowerCase() == lower) return failure;
    }
    return null;
  }

  // A failure worth remembering across runs. Network, rate limit, auth and
  // cooldown failures are temporary: recording them would keep the video
  // skipped even after the cause is gone, so only a file that cannot be
  // decoded or that is gone is recorded.
  static bool _recordsFailure(CloudVideoThumbnailFailure? failure) {
    return failure == CloudVideoThumbnailFailure.noFrame || failure == CloudVideoThumbnailFailure.notFound;
  }

  Future<void> _recordFailure(String url, CloudVideoThumbnailResult result) async {
    final failure = result.failure;
    if (failure == null || !_recordsFailure(failure)) return;
    await cloudMediaCache.recordFailure(url, reason: failure.name, detail: result.message);
  }

  Future<void> _drive(_ScrapeRun run) async {
    try {
      final cloudService = _cloudService();
      if (cloudService == null) {
        if (identical(_run, run)) progress.value = progress.value.copyWith(error: '媒体服务不可用');
        return;
      }
      if (run.retrying) {
        await _driveRetry(run, cloudService);
      } else {
        await _driveScrape(run, cloudService);
      }
    } catch (error) {
      if (identical(_run, run)) progress.value = progress.value.copyWith(error: cloudErrorText(error));
      purerLog.error(PurerLogCategory.scrape, '刮削中断 error=$error');
    } finally {
      if (identical(_run, run)) _finish(run);
    }
  }

  Future<void> _driveScrape(_ScrapeRun run, CloudAwareMediaFetchService cloudService) async {
    final counters = run.counters;
    final items = run.items;
    while (true) {
      if (run.cancelled) return;

      // continue the folder a stopped run was working on before moving on
      if (run.folder != null) {
        if (run.nextVideo < run.videos.length) {
          await _processFolderVideos(run, cloudService);
          _flushDurations(run);
          if (run.cancelled) return;
        }
        final folder = run.folder!;
        counters.foldersDone++;
        run.folder = null;
        run.videos = const [];
        run.frames = const {};
        run.failures = const {};
        run.folderStartIndex = 0;
        run.nextVideo = 0;
        _publish(run, phase: CloudScrapePhase.scraping, currentFolder: folder);
        continue;
      }

      if (run.stack.isEmpty) return;
      final folder = run.stack.removeLast();
      if (!run.visited.add(folder)) continue;
      // never scrape the thumbnail cache itself, or a mirror would be built
      // inside the cache for folders that only hold cached frames
      if (cloudMediaCache.isCacheFolder(folder)) continue;
      counters.foldersScanned = run.visited.length;
      _publish(run, phase: CloudScrapePhase.scanning, currentFolder: folder);

      final client = cloudRegistry.clientForUrl(folder);
      if (client == null) {
        purerLog.warn(PurerLogCategory.scrape, '没有可用的服务 ${PurerLog.redactUrl(folder)}');
        counters.foldersFailed++;
        _publish(run, phase: CloudScrapePhase.scanning, currentFolder: folder);
        continue;
      }
      List<CloudResource> resources;
      try {
        resources = await client.list(folder);
      } catch (error) {
        purerLog.error(PurerLogCategory.scrape, '列目录失败 ${PurerLog.redactUrl(folder)} error=$error');
        counters.foldersFailed++;
        _publish(run, phase: CloudScrapePhase.scanning, currentFolder: folder);
        continue;
      }

      // subfolders are queued, this folder's videos are processed right away
      final videos = <_PendingVideo>[];
      for (final resource in resources) {
        if (resource.isCollection) {
          if (!cloudMediaCache.isCacheFolder(resource.url)) run.stack.add(resource.url);
          continue;
        }
        final mimeType = cloudMimeForResource(resource);
        if (!MimeTypes.isVideo(mimeType)) continue;
        videos.add(_PendingVideo(resource.url, resource.name, folder, mimeType));
      }
      if (videos.isEmpty) {
        counters.foldersDone++;
        _publish(run, phase: CloudScrapePhase.scanning, currentFolder: folder);
        continue;
      }

      // uploads started while browsing this folder are part of the scrape:
      // let them finish so the mirror listing sees them
      await cloudService.waitForFrameUploads(folder);
      // one listing of the mirrored cache folder tells which videos already
      // have a frame (and their duration), and which ones failed in a way that
      // is recorded there, so neither is read or requested again
      final listing = await cloudMediaCache.listing(folder, refresh: true);
      final startIndex = items.length;
      for (final video in videos) {
        counters.discovered++;
        if (items.length < _maxItems) {
          items.add(CloudScrapeItem(url: video.url, name: video.name, folderUrl: folder));
        } else {
          counters.itemsTruncated = true;
        }
      }
      run.folder = folder;
      run.videos = videos;
      run.frames = listing.frames;
      run.failures = listing.failures;
      run.folderStartIndex = startIndex;
      run.nextVideo = 0;
      _publish(run, phase: CloudScrapePhase.scraping, currentFolder: folder);
    }
  }

  // processes the folder set on `run` with a few workers, starting at
  // `run.nextVideo`; on a stop the index marks exactly what is left, so a
  // later resume continues instead of extracting the same frames again
  Future<void> _processFolderVideos(_ScrapeRun run, CloudAwareMediaFetchService cloudService) async {
    final counters = run.counters;
    final items = run.items;
    final videos = run.videos;
    final frames = run.frames;
    final failures = run.failures;
    final startIndex = run.folderStartIndex;
    final folder = run.folder ?? '';

    Future<void> processNextVideo() async {
      while (!run.cancelled) {
        final i = run.nextVideo++;
        if (i >= videos.length) return;
        final video = videos[i];
        final itemIndex = startIndex + i;
        final hasItem = itemIndex < items.length;
        final item = hasItem ? items[itemIndex] : null;
        final known = frames[video.name];
        if (known != null) {
          // a frame always wins over a recorded failure: drop a stale marker so
          // the folder listing and the scrape agree
          if (failures.containsKey(video.name)) await cloudMediaCache.clearFailure(video.url);
          counters.processed++;
          counters.cached++;
          if (item != null) {
            items[itemIndex] = item.copyWith(
              state: CloudScrapeItemState.cached,
              durationMillis: known.durationMillis,
            );
          }
          if (known.durationMillis != null) run.durations[video.url] = known.durationMillis!;
          _publish(run, phase: CloudScrapePhase.scraping, currentFolder: folder);
          continue;
        }

        // an earlier run recorded that this video cannot be scraped: skip the
        // extraction instead of repeating the same failure, and offer the
        // per-item retry on the page
        final recorded = failures[video.name];
        if (recorded != null) {
          counters.processed++;
          counters.skipped++;
          if (item != null) {
            final reason = _failureFromToken(recorded.reason);
            items[itemIndex] = item.copyWith(
              state: CloudScrapeItemState.skipped,
              reason: reason?.label,
              clearReason: reason == null,
              clearDetail: true,
              durationMillis: settings.cloudVideoDuration(video.url),
            );
          }
          _publish(run, phase: CloudScrapePhase.scraping, currentFolder: folder);
          continue;
        }

        if (item != null) {
          items[itemIndex] = item.copyWith(state: CloudScrapeItemState.running);
          _publish(run, phase: CloudScrapePhase.scraping, currentFolder: folder);
        }
        final result = await cloudService.scrapeVideoThumbnail(video.url, mimeType: video.mimeType);
        counters.processed++;
        final duration = result.durationMillis ?? settings.cloudVideoDuration(video.url);
        if (duration != null) run.durations[video.url] = duration;
        if (result.cached) {
          counters.cached++;
          if (item != null) {
            items[itemIndex] = item.copyWith(
              state: CloudScrapeItemState.cached,
              durationMillis: duration,
              percent: result.percent,
              clearReason: true,
              clearDetail: true,
            );
          }
        } else if (result.ok) {
          counters.generated++;
          if (item != null) {
            items[itemIndex] = item.copyWith(
              state: CloudScrapeItemState.generated,
              clearReason: true,
              clearDetail: true,
              attempts: result.attempts,
              durationMillis: duration,
              percent: result.percent,
            );
          }
        } else {
          counters.failed++;
          if (item != null) {
            items[itemIndex] = item.copyWith(
              state: CloudScrapeItemState.failed,
              reason: result.failure?.label ?? CloudVideoThumbnailFailure.unknown.label,
              detail: result.message,
              attempts: result.attempts,
            );
          }
          // the video stays in the failed list of this run, but the next runs
          // skip it unless the user retries it explicitly
          await _recordFailure(video.url, result);
        }
        _publish(run, phase: CloudScrapePhase.scraping, currentFolder: folder);
        // yield so browsing stays responsive; the service itself paces the
        // extractions at the folder's configured rate
        await Future<void>.delayed(Duration.zero);
      }
    }

    await Future.wait(List.generate(math.min(_scrapeConcurrency, videos.length), (_) => processNextVideo()));
  }

  Future<void> _driveRetry(_ScrapeRun run, CloudAwareMediaFetchService cloudService) async {
    final counters = run.counters;
    final items = run.items;
    final listingFutures = <String, Future<CloudFolderListing>>{};
    Future<CloudFolderListing> listingFor(String folder) async {
      await cloudService.waitForFrameUploads(folder);
      return cloudMediaCache.listing(folder, refresh: true);
    }

    Future<void> processNextItem() async {
      while (!run.cancelled) {
        final i = run.nextRetryItem++;
        if (i >= items.length) return;
        final item = items[i];
        // the previous attempt may have failed after a partial upload: list
        // the mirrored folder (once per folder) so the result reflects it
        final listing = await (listingFutures[item.folderUrl] ??= listingFor(item.folderUrl));
        final known = listing.frames[item.name];
        if (known != null) {
          // the frame appeared (another device, a slow upload): the record is
          // stale and must not make a later run skip the video
          await cloudMediaCache.clearFailure(item.url);
          items[i] = CloudScrapeItem(
            url: item.url,
            name: item.name,
            folderUrl: item.folderUrl,
            state: CloudScrapeItemState.cached,
            durationMillis: known.durationMillis ?? settings.cloudVideoDuration(item.url),
          );
          counters.processed++;
          counters.cached++;
          if (known.durationMillis != null) run.durations[item.url] = known.durationMillis!;
          _publish(run, phase: CloudScrapePhase.scraping, currentFolder: item.folderUrl);
          continue;
        }
        items[i] = item.copyWith(state: CloudScrapeItemState.running);
        _publish(run, phase: CloudScrapePhase.scraping, currentFolder: item.folderUrl);
        final result = await cloudService.scrapeVideoThumbnail(item.url, mimeType: cloudMimeForName(item.name), ignoreCooldown: true);
        counters.processed++;
        final duration = result.durationMillis ?? settings.cloudVideoDuration(item.url);
        if (duration != null) run.durations[item.url] = duration;
        if (result.cached) {
          counters.cached++;
          await cloudMediaCache.clearFailure(item.url);
          items[i] = CloudScrapeItem(
            url: item.url,
            name: item.name,
            folderUrl: item.folderUrl,
            state: CloudScrapeItemState.cached,
            durationMillis: duration,
            percent: result.percent,
          );
        } else if (result.ok) {
          counters.generated++;
          await cloudMediaCache.clearFailure(item.url);
          // a fresh item: the previous failure reason must not stay attached
          items[i] = CloudScrapeItem(
            url: item.url,
            name: item.name,
            folderUrl: item.folderUrl,
            state: CloudScrapeItemState.generated,
            attempts: result.attempts,
            durationMillis: duration,
            percent: result.percent,
          );
        } else {
          counters.failed++;
          items[i] = item.copyWith(
            state: CloudScrapeItemState.failed,
            reason: result.failure?.label ?? CloudVideoThumbnailFailure.unknown.label,
            detail: result.message,
            attempts: result.attempts,
          );
          await _recordFailure(item.url, result);
        }
        _publish(run, phase: CloudScrapePhase.scraping, currentFolder: item.folderUrl);
        await Future<void>.delayed(Duration.zero);
      }
    }

    await Future.wait(List.generate(math.min(_scrapeConcurrency, items.length), (_) => processNextItem()));
    _flushDurations(run);
  }

  void _flushDurations(_ScrapeRun run) {
    if (run.durations.isEmpty) return;
    settings.mergeCloudVideoDurations(run.durations);
    run.durations.clear();
  }

  void _publish(_ScrapeRun run, {required CloudScrapePhase phase, required String currentFolder}) {
    // an in-flight video can finish after the user stopped the run: do not
    // flip the page back to "scraping" and leave the stopped state intact. A
    // newer run ignores the updates of an older one entirely.
    if (!identical(_run, run)) return;
    final counters = run.counters;
    final stopped = progress.value.stopped;
    progress.value = progress.value.copyWith(
      phase: stopped ? CloudScrapePhase.finished : phase,
      foldersScanned: counters.foldersScanned,
      foldersDone: counters.foldersDone,
      foldersFailed: counters.foldersFailed,
      discovered: counters.discovered,
      processed: counters.processed,
      generated: counters.generated,
      cached: counters.cached,
      failed: counters.failed,
      skipped: counters.skipped,
      currentFolder: currentFolder,
      // shared with the UI instead of copied on every video: a 20k item list
      // copied once per update was the dominant cost of a large scrape
      items: run.items,
      itemsTruncated: counters.itemsTruncated,
    );
  }

  void _finish(_ScrapeRun run) {
    final stopped = run.cancelled || progress.value.stopped;
    final remaining = run.hasRemainingWork;
    progress.value = progress.value.copyWith(
      running: false,
      finished: true,
      stopped: stopped,
      canResume: stopped && remaining,
      phase: CloudScrapePhase.finished,
      finishedAt: DateTime.now(),
      items: run.items,
    );
    purerLog.info(
      PurerLogCategory.scrape,
      '刮削结束 processed=${run.counters.processed} generated=${run.counters.generated} '
      'cached=${run.counters.cached} failed=${run.counters.failed} skipped=${run.counters.skipped} stopped=$stopped remaining=$remaining',
    );
    // a completed run has nothing to continue; a stopped one stays until it is
    // resumed or replaced by a new run
    if (!stopped) _run = null;
  }

  void cancel() {
    // a single-video retry is not part of a run: stop it on its own, keeping
    // the finished/stopped run underneath as it was
    if (_retryToken != null) {
      _retryToken = null;
      final base = _retryBase ?? progress.value;
      final original = _retryItemOriginal;
      final index = _retryItemIndex;
      _retryBase = null;
      _retryItemIndex = null;
      _retryItemOriginal = null;
      final items = List<CloudScrapeItem>.of(progress.value.items);
      if (original != null && index != null && index < items.length) items[index] = original;
      progress.value = base.copyWith(running: false, finished: true, items: items);
      purerLog.info(PurerLogCategory.scrape, '请求停止单项重试');
      return;
    }
    final run = _run;
    if (run == null || !progress.value.running) return;
    run.cancelled = true;
    progress.value = progress.value.copyWith(
      running: false,
      finished: true,
      stopped: true,
      canResume: run.hasRemainingWork,
      phase: CloudScrapePhase.finished,
      finishedAt: DateTime.now(),
    );
    purerLog.info(PurerLogCategory.scrape, '请求停止刮削');
  }

  static CloudAwareMediaFetchService? _cloudService() {
    final service = mediaFetchService;
    return service is CloudAwareMediaFetchService ? service : null;
  }
}

final cloudThumbnailScraper = CloudThumbnailScraper();
