import 'package:purer_model/purer_model.dart';
import 'package:purer_video/purer_video.dart';
import 'package:purer_video_mpv/purer_video_mpv.dart';
import 'package:purer_video_mpv/src/controller_audio.dart';
import 'package:media_kit/media_kit.dart';

class MpvAudioControllerFactory extends PurerAudioControllerFactory {
  @override
  void init() => MediaKit.ensureInitialized();

  @override
  PurerAudioController buildController(PurerEntryBase entry) => MpvAudioController(entry);
}

class MpvVideoControllerFactory extends PurerVideoControllerFactory {
  @override
  void init() => MediaKit.ensureInitialized();

  @override
  PurerVideoController buildController(
    PurerEntryBase entry, {
    required PlaybackStateHandler playbackStateHandler,
    required VideoSettings settings,
    int startMillis = 0,
  }) => MpvVideoController(
    entry,
    playbackStateHandler: playbackStateHandler,
    settings: settings,
    startMillis: startMillis,
  );
}
