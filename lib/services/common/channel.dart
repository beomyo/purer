import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:streams_channel/streams_channel.dart';

class PurerMethodChannel extends MethodChannel {
  static bool kDebug = false;

  const new(super.name);

  @override
  Future<T?> invokeMethod<T>(String method, [arguments]) {
    if (kDebug) {
      debugPrint('$runtimeType platform call channel=$name method=$method arguments=$arguments');
    }
    return super.invokeMethod(method, arguments);
  }
}

class PurerStreamsChannel extends StreamsChannel {
  new(super.name);

  @override
  Stream receiveBroadcastStream([arguments]) {
    if (PurerMethodChannel.kDebug) {
      debugPrint('$runtimeType platform call channel=$name arguments=$arguments');
    }
    return super.receiveBroadcastStream(arguments);
  }
}
