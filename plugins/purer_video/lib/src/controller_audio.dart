import 'dart:async';

import 'package:purer_model/purer_model.dart';
import 'package:purer_utils/purer_utils.dart';
import 'package:purer_video/purer_video.dart';
import 'package:flutter/foundation.dart';
import 'package:leak_tracker/leak_tracker.dart';

abstract class PurerAudioControllerFactory {
  void init();

  PurerAudioController buildController(PurerEntryBase entry);
}

abstract class PurerAudioController(final PurerEntryBase entry) extends Disposer {
  bool _disposed = false;

  this {
    if (kFlutterMemoryAllocationsEnabled) {
      LeakTracking.dispatchObjectCreated(
        library: 'purer',
        className: '$PurerAudioController',
        object: this,
      );
    }
  }

  @override
  Future<void> dispose() async {
    assert(!_disposed);
    _disposed = true;
    if (kFlutterMemoryAllocationsEnabled) {
      LeakTracking.dispatchObjectDisposed(object: this);
    }
    super.dispose();
  }

  Future<void> enableLoop(bool enabled);

  Future<void> play();

  Future<void> pause();

  PlaybackStatus get status;

  Stream<PlaybackStatus> get statusStream;

  bool get isReady;

  Future<void> get untilReady {
    if (isReady) return Future.value();

    final completer = Completer();
    late StreamSubscription<PlaybackStatus> sub;
    sub = statusStream.where((_) => isReady).listen((_) {
      sub.cancel();
      completer.complete();
    });
    return completer.future;
  }

  bool get isPlaying => status == .playing;
}
