import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:purer_model/purer_model.dart';
import 'package:purer_video/purer_video.dart';
import 'package:purer_video_mpv/purer_video_mpv.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class MpvVideoMetadataFetcher extends PurerVideoMetadataFetcher {
  static const mpvTypeAudio = 'audio';
  static const mpvTypeVideo = 'video';
  static const mpvTypeSub = 'sub';

  static const probeTimeoutImage = 500;
  // remote containers (AVI/WMV in particular) need several range requests
  // before libavformat knows the video parameters
  static const probeTimeoutVideo = 8000;

  @override
  void init() => MediaKit.ensureInitialized();

  Future<Player?> _openBackgroundPlayer({required String uri, required String mimeType, Map<String, String>? httpHeaders}) async {
    final player = Player(
      configuration: PlayerConfiguration(
        logLevel: .warn,
        protocolWhitelist: MpvVideoController.protocolWhitelist,
      ),
    );
    final platform = player.platform;
    if (platform is! NativePlayer) {
      throw Exception('Platform player ${platform.runtimeType} does not support property retrieval');
    }

    // We need to enable video decoding to retrieve video params,
    // but it is disabled by default unless a `VideoController` is attached.
    // Attaching a `VideoController` is problematic, because `player.open()` may not return
    // unless a new frame is rendered, and triggering fails from a background service.
    // It is simpler to enable the video track via properties.
    await platform.setProperty('vid', 'auto');

    // deselect audio track to prevent triggering Android audio sessions
    await platform.setProperty('aid', 'no');

    final videoDecodedCompleter = Completer();
    StreamSubscription? subscription;
    subscription = player.stream.videoParams.listen((v) {
      // some containers (AVI/WMV) report no pixel aspect ratio, so the video
      // size is what tells that the stream is decoded
      if (v.par != null || v.w != null || v.dw != null) {
        subscription?.cancel();
        videoDecodedCompleter.complete();
      }
    });

    await player.open(Media(uri, httpHeaders: httpHeaders), play: false);

    final timeoutMillis = mimeType.startsWith('image') ? probeTimeoutImage : probeTimeoutVideo;
    await Future.any([videoDecodedCompleter.future, Future.delayed(Duration(milliseconds: timeoutMillis))]);

    final videoParams = player.state.videoParams;
    if (videoParams.par == null && videoParams.w == null && videoParams.dw == null) {
      debugPrint('failed to probe video metadata within $timeoutMillis ms for uri=$uri, mimeType=$mimeType');
      await player.dispose();
      return null;
    }

    return player;
  }

  @override
  Future<Map<String, Object?>> getMetadata({required String uri, required String mimeType}) async {
    final player = await _openBackgroundPlayer(uri: uri, mimeType: mimeType);
    if (player == null) return {};

    final fields = await _describeAllMetadataFields(player);

    await player.dispose();
    return fields;
  }

  // mpv properties: https://mpv.io/manual/stable/#property-list
  static const _propertyChapterList = 'chapter-list';
  static const _propertyDurationFull = 'duration/full';
  static const _propertyMetadata = 'metadata';
  static const _propertyTrackList = 'track-list';

  static Future<Map<String, Object?>> _describeAllMetadataFields(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) {
      throw Exception('Platform player ${platform.runtimeType} does not support property retrieval');
    }

    final fields = <String, Object?>{};

    // mpv doc: "duration with milliseconds"
    final durationSecs = await platform.getProperty(_propertyDurationFull);
    if (durationSecs.isNotEmpty) {
      fields[Keys.duration] = durationSecs;
    }

    // mpv doc: "metadata key/value pairs"
    // note: seems to match FFprobe "format" > "tags" fields
    final metadata = await platform.getProperty(_propertyMetadata);
    if (metadata.isNotEmpty) {
      try {
        final jsonMap = jsonDecode(metadata) as Map<String, Object?>;
        jsonMap.forEach((key, value) {
          fields[key] = value;
        });
      } catch (error) {
        debugPrint('failed to parse metadata=$metadata with error=$error');
      }
    }

    final tracks = await platform.getProperty(_propertyTrackList);
    if (tracks.isNotEmpty) {
      try {
        final tracksJson = jsonDecode(tracks);
        if (tracksJson is List && tracksJson.isNotEmpty) {
          final videoParams = player.state.videoParams;
          fields[Keys.streams] = tracksJson.whereType<Map>().map((track) {
            return _normalizeTrack(track.cast<String, Object?>(), videoParams);
          }).toList();
        }
      } catch (error) {
        debugPrint('failed to parse tracks=$tracks with error=$error');
      }
    }

    final chapters = await platform.getProperty(_propertyChapterList);
    if (chapters.isNotEmpty) {
      try {
        final chaptersJson = jsonDecode(chapters);
        if (chaptersJson is List && chaptersJson.isNotEmpty) {
          final chapterMaps = chaptersJson.whereType<Map>().toList();
          if (chapterMaps.isNotEmpty) {
            fields[Keys.chapters] = chapterMaps;
          }
        }
      } catch (error) {
        debugPrint('failed to parse chapters=$chapters with error=$error');
      }
    }

    return fields;
  }

  static Map<String, Object?> _normalizeTrack(Map<String, Object?> stream, VideoParams videoParams) {
    void replaceKey(String k1, String k2) {
      final v = stream.remove(k1);
      if (v != null) {
        stream[k2] = v;
      }
    }

    void removeIfFalse(String k) {
      if (stream[k] == false) {
        stream.remove(k);
      }
    }

    stream.remove('id');
    stream.remove('decoder-desc');
    stream.remove('main-selection');
    stream.remove('selected');
    stream.remove('src-id');
    replaceKey('ff-index', Keys.index);
    replaceKey('codec', Keys.codecName);
    replaceKey('lang', Keys.language);
    replaceKey('demux-bitrate', Keys.bitrate);
    replaceKey('demux-channel-count', Keys.audioChannels);
    replaceKey('demux-fps', Keys.fps);
    replaceKey('demux-samplerate', Keys.sampleRate);
    replaceKey('hearing-impaired', Keys.hearingImpaired);
    replaceKey('visual-impaired', Keys.visualImpaired);

    stream.removeWhere((k, v) => k.startsWith('demux-'));
    removeIfFalse('albumart');
    removeIfFalse('default');
    removeIfFalse('dependent');
    removeIfFalse('external');
    removeIfFalse('forced');
    removeIfFalse(Keys.hearingImpaired);
    removeIfFalse(Keys.visualImpaired);

    final isImage = stream.remove('image');
    switch (stream.remove('type')) {
      case mpvTypeAudio:
        stream[Keys.streamType] = MediaStreamTypes.audio;
      case mpvTypeVideo:
        stream[Keys.streamType] = MediaStreamTypes.video;
        if (isImage is bool && isImage) {
          stream.remove(Keys.fps);
        }

        // Some video properties are not in the video track props but accessible via `video-params` (or `video-out-params`).
        // These parameters are already stored in the player state, as `videoParams`.
        // Parameters `sigPeak` and `averageBpp` are ignored.
        final videoParamsTags = <String, Object?>{
          Keys.alpha: videoParams.alpha,
          Keys.chromaLocation: videoParams.chromaLocation,
          Keys.codecPixelFormat: videoParams.pixelformat,
          Keys.colorLevels: videoParams.colorlevels,
          Keys.colorMatrix: videoParams.colormatrix,
          Keys.colorPrimaries: videoParams.primaries,
          Keys.dar: videoParams.aspect,
          Keys.decoderHeight: videoParams.dh,
          Keys.decoderWidth: videoParams.dw,
          Keys.gamma: videoParams.gamma,
          Keys.hwPixelFormat: videoParams.hwPixelformat,
          Keys.light: videoParams.light,
          Keys.par: videoParams.par,
          Keys.rotate: videoParams.rotate,
          Keys.stereo3dMode: videoParams.stereoIn,
          Keys.videoHeight: videoParams.h,
          Keys.videoWidth: videoParams.w,
        }..removeWhere((k, v) => v == null);
        stream.addAll(videoParamsTags);
      case mpvTypeSub:
        stream[Keys.streamType] = MediaStreamTypes.subtitle;
    }
    return stream;
  }

  static Future<double?> _getPlaybackDurationSecs(Player player) async {
    final platform = player.platform;
    if (platform is NativePlayer) {
      final durationString = await platform.getProperty(_propertyDurationFull);
      return _toDoubleValue(durationString);
    }
    return null;
  }

  static Future<Map<String, Object?>> _getFields(
    Player player,
    Set<String> keys,
    Future<Map<String, Object?>> Function(NativePlayer platform) toJsonMap,
  ) async {
    final result = <String, Object?>{};
    final platform = player.platform;
    if (platform is NativePlayer) {
      final jsonMap = await toJsonMap(platform);
      result.addAll(
        Map.fromEntries(
          keys.map((key) {
            Object? value = jsonMap[key];
            switch (key) {
              case Keys.androidCaptureFramerate:
              case Keys.demuxFps:
                value = _toDoubleValue(value);
              case Keys.xiaomiSlowMoment:
                if (value is String) {
                  value = value == '1';
                }
            }
            return MapEntry(key, value);
          }),
        ),
      );
    }
    return result;
  }

  static Future<Map<String, Object?>> _getMetadataFields(Player player, Set<String> keys) async {
    return _getFields(player, keys, (platform) async {
      final metadata = await platform.getProperty(_propertyMetadata);
      if (metadata.isNotEmpty) {
        try {
          return jsonDecode(metadata) as Map<String, Object?>;
        } catch (error) {
          debugPrint('failed to parse metadata=$metadata with error=$error');
        }
      }
      return {};
    });
  }

  static Future<Map<String, Object?>> _getVideoTrackFields(Player player, Set<String> keys) async {
    return _getFields(player, keys, (platform) async {
      final tracks = await platform.getProperty(_propertyTrackList);
      if (tracks.isNotEmpty) {
        try {
          final tracksJson = jsonDecode(tracks);
          if (tracksJson is List && tracksJson.isNotEmpty) {
            final videoTrack = tracksJson.whereType<Map>().map((track) => track.cast<String, Object?>()).firstWhereOrNull((kv) => kv['type'] == mpvTypeVideo);
            return videoTrack ?? {};
          }
        } catch (error) {
          debugPrint('failed to parse tracks=$tracks with error=$error');
        }
      }
      return {};
    });
  }

  static double? _toDoubleValue(Object? value) {
    if (value is String) {
      return double.tryParse(value);
    } else if (value is num) {
      return value.toDouble();
    }
    return null;
  }

  @override
  Future<(int, int?)> computeSlowMotionFactorAndDuration({required String uri, required String mimeType}) async {
    final player = await _openBackgroundPlayer(uri: uri, mimeType: mimeType);
    if (player == null) return (1, null);

    final playbackFps = (await _getVideoTrackFields(player, {Keys.demuxFps}))[Keys.demuxFps];

    int? slowMotionFactor;
    if (playbackFps is double) {
      slowMotionFactor = await computeSlowMotionFactor(player, playbackFps);
    }
    if (slowMotionFactor == null) return (1, null);

    final playbackDurationSecs = await _getPlaybackDurationSecs(player);
    await player.dispose();

    int? captureDurationMillis;
    if (playbackDurationSecs is double) {
      captureDurationMillis = (playbackDurationSecs * 1000 / slowMotionFactor).round();
    }
    return (slowMotionFactor, captureDurationMillis);
  }

  static Future<int> computeSlowMotionFactor(Player player, double? playbackFps) async {
    int slowMotionFactor = 1;

    if (playbackFps != null && playbackFps != 0) {
      final result = await _getMetadataFields(player, {
        Keys.androidCaptureFramerate,
        Keys.xiaomiSlowMoment,
      });
      final captureFps = result[Keys.androidCaptureFramerate];
      if (captureFps is double && captureFps != 0) {
        slowMotionFactor = (captureFps / playbackFps).round();
        if (slowMotionFactor == 1) {
          // Xiaomi slow motion videos set both FPS to 120
          final slowMoment = result[Keys.xiaomiSlowMoment];
          if (slowMoment is bool && slowMoment) {
            slowMotionFactor = (captureFps / SlowMotionMixin.fallbackPlaybackFps).round();
          }
        }
      }
    }
    return slowMotionFactor.isFinite && slowMotionFactor != 0 ? slowMotionFactor : 1;
  }

  @override
  Future<ui.ImageDescriptor?> getThumbnailDescriptor({
    required String uri,
    required String mimeType,
    required double targetExtentDip,
    required List<VideoThumbnailMethod> methods,
    Map<String, String>? httpHeaders,
    double? previewFraction,
    String? tempDirectory,
    void Function(int durationMillis)? onDuration,
    void Function(String reason)? onFailure,
  }) async {
    if (targetExtentDip == 0) return null;
    String? reason;
    final descriptor = await _extractWithImageVo(
      uri: uri,
      mimeType: mimeType,
      targetExtentDip: targetExtentDip,
      methods: methods,
      httpHeaders: httpHeaders,
      previewFraction: previewFraction,
      tempDirectory: tempDirectory,
      onDuration: onDuration,
      onFailure: (r) => reason = r,
    );
    if (descriptor != null) return descriptor;
    // the image output produced no frame: fall back to the same video output
    // (and the same screenshot command) the in-app player uses
    final fallback = await _extractWithVideoController(
      uri: uri,
      targetExtentDip: targetExtentDip,
      methods: methods,
      httpHeaders: httpHeaders,
      previewFraction: previewFraction,
      onDuration: onDuration,
      onFailure: (r) => reason ??= r,
    );
    if (fallback == null) onFailure?.call(reason ?? '没有取到画面');
    return fallback;
  }

  Future<ui.ImageDescriptor?> _extractWithImageVo({
    required String uri,
    required String mimeType,
    required double targetExtentDip,
    required List<VideoThumbnailMethod> methods,
    Map<String, String>? httpHeaders,
    double? previewFraction,
    String? tempDirectory,
    void Function(int durationMillis)? onDuration,
    void Function(String reason)? onFailure,
  }) async {
    final fraction = previewFraction ?? PurerVideoMetadataFetcher.defaultPreviewTimeFraction;
    final wanted = methods.isEmpty ? const [VideoThumbnailMethod.preview] : methods;

    Directory? outDir;
    Player? player;
    try {
      outDir = await _createThumbnailDirectory(tempDirectory);
      player = await _openThumbnailPlayer(uri: uri, httpHeaders: httpHeaders, outDir: outDir, onFailure: onFailure);
      if (player == null) return null;

      final duration = await _waitForDuration(player);
      if (duration.inMilliseconds > 0) onDuration?.call(duration.inMilliseconds);
      final previewTime = getPreviewThumbnailTime(duration, fraction: fraction);
      for (final method in wanted) {
        if (method == VideoThumbnailMethod.embedded) continue;
        final time = method == VideoThumbnailMethod.first ? Duration.zero : previewTime;
        final capture = await _captureThumbnailFrame(player, outDir, time);
        if (duration == Duration.zero) {
          final learned = player.state.duration;
          if (learned.inMilliseconds > 0) onDuration?.call(learned.inMilliseconds);
        }
        if (capture == null) continue;
        final descriptor = capture.encoded
            ? await _descriptorFromEncoded(capture.bytes, targetExtentDip)
            : await _descriptorFromBgra(capture.bytes, player.state.videoParams, targetExtentDip);
        if (descriptor != null) return descriptor;
      }
      onFailure?.call('视频已打开，但 image 输出没有写出画面');
      return null;
    } catch (error) {
      debugPrint('libmpv thumbnail extraction failed for uri=$uri error=$error');
      onFailure?.call('image 输出异常: $error');
      return null;
    } finally {
      try {
        await player?.dispose();
      } catch (_) {
        // already disposed
      }
      try {
        await outDir?.delete(recursive: true);
      } catch (_) {
        // best effort
      }
    }
  }

  // Last resort: attach the same video output the player uses. Some Android
  // libmpv builds cannot use the `image` output, but the `gpu`/`libmpv`
  // output used by the player keeps a frame that `screenshot-raw` can read.
  Future<ui.ImageDescriptor?> _extractWithVideoController({
    required String uri,
    required double targetExtentDip,
    required List<VideoThumbnailMethod> methods,
    Map<String, String>? httpHeaders,
    double? previewFraction,
    void Function(int durationMillis)? onDuration,
    void Function(String reason)? onFailure,
  }) async {
    final fraction = previewFraction ?? PurerVideoMetadataFetcher.defaultPreviewTimeFraction;
    final wanted = methods.isEmpty ? const [VideoThumbnailMethod.preview] : methods;

    Player? player;
    VideoController? controller;
    try {
      player = Player(
        configuration: PlayerConfiguration(
          logLevel: .warn,
          protocolWhitelist: MpvVideoController.protocolWhitelist,
        ),
      );
      final platform = player.platform;
      if (platform is! NativePlayer) return null;

      await platform.setProperty('vid', 'auto');
      await platform.setProperty('aid', 'no');
      await platform.setProperty('cache', 'yes');
      await platform.setProperty('cache-on-disk', 'no');
      await platform.setProperty('demuxer-lavf-analyzeduration', '1');
      await platform.setProperty('demuxer-lavf-probesize', '${1024 * 1024}');
      await platform.setProperty('network-timeout', '10');

      controller = VideoController(player);
      final firstFrame = controller.waitUntilFirstFrameRendered;
      await player.open(Media(uri, httpHeaders: httpHeaders), play: true);
      await Future.any([firstFrame, Future.delayed(const Duration(seconds: 10))]);

      final duration = await _waitForDuration(player);
      if (duration.inMilliseconds > 0) onDuration?.call(duration.inMilliseconds);
      final previewTime = getPreviewThumbnailTime(duration, fraction: fraction);
      for (final method in wanted) {
        if (method == VideoThumbnailMethod.embedded) continue;
        final time = method == VideoThumbnailMethod.first ? Duration.zero : previewTime;
        if (time > Duration.zero) {
          try {
            await player.seek(time);
          } catch (error) {
            debugPrint('video-controller seek failed for time=$time error=$error');
          }
        }
        await Future.delayed(const Duration(milliseconds: 350));
        final bgra = await _screenshot(player);
        if (bgra == null) continue;
        final descriptor = await _descriptorFromBgra(bgra, player.state.videoParams, targetExtentDip);
        if (descriptor != null) return descriptor;
      }
      onFailure?.call('播放器输出也没有读到画面');
      return null;
    } catch (error) {
      debugPrint('libmpv video-controller fallback failed for uri=$uri error=$error');
      onFailure?.call('播放器输出异常: $error');
      return null;
    } finally {
      try {
        controller?.dispose();
      } catch (_) {
        // already disposed
      }
      try {
        await player?.dispose();
      } catch (_) {
        // already disposed
      }
    }
  }

  // The default `vo=null` keeps no frame, so `screenshot-raw` returns nothing
  // and the libmpv fallback never produced a thumbnail. The `image` video
  // output keeps the current frame and also writes every displayed frame to a
  // file, giving the extractor two independent ways to read it.
  Future<Player?> _openThumbnailPlayer({
    required String uri,
    required Map<String, String>? httpHeaders,
    required Directory outDir,
    void Function(String reason)? onFailure,
  }) async {
    final player = Player(
      configuration: PlayerConfiguration(
        logLevel: .warn,
        protocolWhitelist: MpvVideoController.protocolWhitelist,
      ),
    );
    final platform = player.platform;
    if (platform is! NativePlayer) {
      onFailure?.call('不是原生 libmpv 后端');
      await player.dispose();
      return null;
    }

    await platform.setProperty('vid', 'auto');
    await platform.setProperty('aid', 'no');
    // set the output directory before selecting the VO, so the image output
    // uses it from its first frame
    await platform.setProperty('vo-image-outdir', outDir.path);
    await platform.setProperty('vo', 'image');
    // network streams: start decoding quickly, keep the demuxer cache in memory
    await platform.setProperty('cache', 'yes');
    await platform.setProperty('cache-on-disk', 'no');
    await platform.setProperty('demuxer-lavf-analyzeduration', '1');
    await platform.setProperty('demuxer-lavf-probesize', '${1024 * 1024}');
    await platform.setProperty('network-timeout', '10');

    final ready = Completer<bool>();
    final subscription = player.stream.videoParams.listen((v) {
      // some containers (AVI/WMV) report no pixel aspect ratio
      if (v.par != null || v.w != null || v.dw != null) {
        if (!ready.isCompleted) ready.complete(true);
      }
    });
    try {
      await player.open(Media(uri, httpHeaders: httpHeaders), play: true);
      final ok = await Future.any([
        ready.future,
        Future.delayed(const Duration(seconds: 10), () => false),
      ]);
      if (!ok) {
        debugPrint('libmpv did not report video parameters within 10s for uri=$uri');
        onFailure?.call('10 秒内没有识别出视频参数');
        await player.dispose();
        return null;
      }
    } finally {
      await subscription.cancel();
    }
    // stop the stream until the frame position is known
    await player.pause();
    return player;
  }

  Future<Duration> _waitForDuration(Player player) async {
    var duration = player.state.duration;
    for (var i = 0; i < 30 && duration == Duration.zero; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      duration = player.state.duration;
    }
    return duration;
  }

  Future<_FrameCapture?> _captureThumbnailFrame(Player player, Directory outDir, Duration time) async {
    final known = {for (final file in await _thumbnailFiles(outDir)) file.path};
    if (time > Duration.zero) {
      try {
        await player.seek(time);
      } catch (error) {
        debugPrint('libmpv seek failed for time=$time error=$error');
      }
    }

    // the seek may have decoded the frame while paused: try the fast path first
    await Future.delayed(const Duration(milliseconds: 250));
    final direct = await _screenshot(player);
    if (direct != null) return _FrameCapture(direct, encoded: false);

    // no frame retained without playback: let the image VO write one
    try {
      await player.play();
    } catch (error) {
      debugPrint('libmpv play failed error=$error');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    try {
      while (DateTime.now().isBefore(deadline)) {
        final fresh = (await _thumbnailFiles(outDir)).where((file) => !known.contains(file.path)).toList();
        if (fresh.isNotEmpty) {
          // stop writing frames while the file is read
          await player.pause();
          final bytes = await _readNewest(fresh);
          if (bytes != null) return _FrameCapture(bytes, encoded: true);
          try {
            await player.play();
          } catch (_) {
            // eof or disposed
          }
        }
        final bgra = await _screenshot(player);
        if (bgra != null) return _FrameCapture(bgra, encoded: false);
        await Future.delayed(const Duration(milliseconds: 80));
      }
    } finally {
      await player.pause();
    }

    // playback produced no useful frame file: keep whatever was written
    final files = await _thumbnailFiles(outDir);
    final bytes = files.isEmpty ? null : await _readNewest(files);
    return bytes == null ? null : _FrameCapture(bytes, encoded: true);
  }

  static Future<Uint8List?> _screenshot(Player player) async {
    try {
      final bytes = await player.screenshot(format: null);
      if (bytes != null && bytes.isNotEmpty) return bytes;
    } catch (error) {
      debugPrint('libmpv screenshot failed error=$error');
    }
    return null;
  }

  static Future<Directory> _createThumbnailDirectory(String? base) async {
    final root = (base != null && base.isNotEmpty) ? base : Directory.systemTemp.path;
    final dir = Directory('$root/purer-mpv-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 20)}');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<List<File>> _thumbnailFiles(Directory dir) async {
    try {
      return await dir.list().where((entity) => entity is File).cast<File>().toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<Uint8List?> _readNewest(List<File> files) async {
    File? newest;
    DateTime? newestTime;
    for (final file in files) {
      try {
        final stat = await file.stat();
        if (stat.size <= 0) continue;
        if (newestTime == null || stat.modified.isAfter(newestTime)) {
          newest = file;
          newestTime = stat.modified;
        }
      } catch (_) {
        // removed while scanning
      }
    }
    if (newest == null) return null;
    try {
      // the image VO writes the file while we poll: wait until its size stops
      // growing, otherwise a truncated frame cannot be decoded
      for (var attempt = 0; attempt < 4; attempt++) {
        final before = await newest.length();
        if (before <= 0) return null;
        await Future.delayed(const Duration(milliseconds: 80));
        final after = await newest.length();
        if (after > 0 && after == before) {
          final bytes = await newest.readAsBytes();
          return bytes.isEmpty ? null : bytes;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<ui.ImageDescriptor?> _descriptorFromBgra(Uint8List bgra, VideoParams videoParams, double targetExtentDip) async {
    final videoWidth = videoParams.dw ?? videoParams.w;
    final videoHeight = videoParams.dh ?? videoParams.h;
    if (videoWidth == null || videoHeight == null) return null;

    final devicePixelRatio = PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1;
    final input = _ThumbnailByteInput(
      bytes: bgra,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      videoRotationDegrees: videoParams.rotate ?? 0,
      targetWidth: (targetExtentDip * devicePixelRatio).round(),
      targetHeight: (targetExtentDip * devicePixelRatio).round(),
    );
    final output = await compute(_getThumbnailBytes, input);
    if (output == null) return null;

    final buffer = await ui.ImmutableBuffer.fromUint8List(output.bytes);
    return ui.ImageDescriptor.raw(
      buffer,
      width: output.width,
      height: output.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
  }

  // the image VO writes encoded frames: bound their size before handing the
  // descriptor to the caller, which decodes it at its full dimensions
  Future<ui.ImageDescriptor?> _descriptorFromEncoded(Uint8List bytes, double targetExtentDip) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final devicePixelRatio = PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1;
    final target = (targetExtentDip * devicePixelRatio).round();
    final longest = max(descriptor.width, descriptor.height);
    if (target <= 0 || longest <= target) return descriptor;

    ui.Codec? codec;
    ui.Image? image;
    try {
      final scale = target / longest;
      final width = max(1, (descriptor.width * scale).round());
      final height = max(1, (descriptor.height * scale).round());
      codec = await descriptor.instantiateCodec(targetWidth: width, targetHeight: height);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      final png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final pngBuffer = await ui.ImmutableBuffer.fromUint8List(png);
      return await ui.ImageDescriptor.encoded(pngBuffer);
    } catch (error) {
      debugPrint('failed to scale libmpv frame error=$error');
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor.dispose();
    }
  }

}

@immutable
class _FrameCapture {
  final Uint8List bytes;
  // true when the image VO wrote an encoded file, false for a raw BGRA frame
  final bool encoded;

  const new(this.bytes, {required this.encoded});
}

@immutable
class const _ThumbnailByteInput({
  required final Uint8List bytes,
  required final int videoWidth,
  required final int videoHeight,
  required final int videoRotationDegrees,
  required final int targetWidth,
  required final int targetHeight,
});

@immutable
class const _ThumbnailByteOutput({
  required final Uint8List bytes,
  required final int width,
  required final int height,
});

const double _rescaleReductionThreshold = .15;

_ThumbnailByteOutput? _getThumbnailBytes(_ThumbnailByteInput input) {
  final bgra = input.bytes;
  final videoWidth = input.videoWidth;
  final videoHeight = input.videoHeight;
  final videoRotationDegrees = input.videoRotationDegrees;
  final targetWidth = input.targetWidth;
  final targetHeight = input.targetHeight;

  var sampleSize = 1;
  if (videoWidth > targetWidth || videoHeight > targetHeight) {
    while (videoHeight / (sampleSize * 2) >= targetHeight && videoWidth / (sampleSize * 2) >= targetWidth) {
      sampleSize *= 2;
    }
  }

  // normally, `stride = videoWidth * bpp`, but it can differ,
  // so we use the more reliable `stride = byte count / videoHeight` instead
  // cf https://mpv.io/manual/stable/#command-interface-screenshot-raw
  final stride = (bgra.lengthInBytes / videoHeight).round();

  final sampledWidth = (videoWidth / sampleSize).ceil();
  final sampledHeight = (videoHeight / sampleSize).ceil();
  var targetImage = img.Image(
    width: sampledWidth,
    height: sampledHeight,
    format: img.Format.uint8,
    // only 3 channels are necessary to store an opaque image,
    // but 4 allows usage as `ImageDescriptor` raw format
    numChannels: 4,
  );

  const bpp = 4;
  final xFactor = bpp * sampleSize;
  final yFactor = stride * sampleSize;
  for (var x = 0; x < sampledWidth; x++) {
    final ix = x * xFactor;
    for (var y = 0; y < sampledHeight; y++) {
      final i = y * yFactor + ix;
      targetImage.setPixelRgba(x, y, bgra[i + 2], bgra[i + 1], bgra[i], bgra[i + 3]);
    }
  }

  if (sampledWidth > targetWidth && sampledHeight > targetHeight) {
    // rescale when the resulting image is larger than requested
    final scalingFactor = min(sampledWidth / targetWidth, sampledHeight / targetHeight);
    final dstWidth = (sampledWidth / scalingFactor).round();
    final dstHeight = (sampledHeight / scalingFactor).round();
    final reduction = 1 - (dstWidth * dstHeight).toDouble() / (sampledWidth * sampledHeight);
    if (reduction > _rescaleReductionThreshold) {
      debugPrint(
        'rescale thumbnail for width=$targetWidth height=$targetHeight'
        ', with bitmap byteCount=${targetImage.lengthInBytes} size=${sampledWidth}x$sampledHeight, to target=${dstWidth}x$dstHeight'
        ', reduced by ${((reduction) * 100).round()}%)',
      );
      targetImage = img.copyResize(targetImage, width: dstWidth, height: dstHeight);
    }
  }

  if (videoRotationDegrees > 0) {
    targetImage = img.copyRotate(targetImage, angle: videoRotationDegrees);
  }

  return _ThumbnailByteOutput(
    bytes: targetImage.toUint8List(),
    width: targetImage.width,
    height: targetImage.height,
  );
}
