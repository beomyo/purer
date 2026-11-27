import 'package:purer_video/purer_video.dart';
import 'package:media_kit/media_kit.dart';

extension ExtraVideoTrack on VideoTrack {
  MediaTrackSummary toPurer(int index) {
    return MediaTrackSummary(
      type: MediaTrackType.video,
      index: index,
      codecName: null,
      language: language,
      title: title,
      width: null,
      height: null,
    );
  }
}

extension ExtraAudioTrack on AudioTrack {
  MediaTrackSummary toPurer(int index) {
    return MediaTrackSummary(
      type: MediaTrackType.audio,
      index: index,
      codecName: null,
      language: language,
      title: title,
      width: null,
      height: null,
    );
  }
}

extension ExtraSubtitleTrack on SubtitleTrack {
  MediaTrackSummary toPurer(int index) {
    return MediaTrackSummary(
      type: MediaTrackType.text,
      index: index,
      codecName: null,
      language: language,
      title: title ?? '$index ($codec)',
      width: null,
      height: null,
    );
  }
}
