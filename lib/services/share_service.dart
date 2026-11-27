import 'package:purer/services/common/channel.dart';
import 'package:purer/services/common/services.dart';
import 'package:flutter/services.dart';

// Shares a remote file through the system chooser. The file is streamed into
// the app cache by the platform, so a large video never has to be held in
// memory on the Dart side.
abstract class ShareService {
  // `transferId` identifies the transfer so `cancelShare` can stop the
  // download while the user waits
  Future<bool?> shareRemoteFile({
    required String url,
    required Map<String, String> headers,
    required String name,
    required String mimeType,
    String? transferId,
  });

  // stops an in-flight `shareRemoteFile` identified by its transfer id
  Future<void> cancelShare(String transferId);
}

class PlatformShareService implements ShareService {
  static const _platform = PurerMethodChannel('io.github.beomyo/purer/share');

  @override
  Future<bool?> shareRemoteFile({
    required String url,
    Map<String, String> headers = const {},
    required String name,
    required String mimeType,
    String? transferId,
  }) async {
    try {
      return await _platform.invokeMethod<bool>('shareUrl', <String, Object?>{
        'url': url,
        'headers': headers,
        'name': name,
        'mimeType': mimeType,
        'transferId': transferId,
      });
    } on PlatformException catch (e, stack) {
      await reportService.recordError(e, stack);
    }
    return false;
  }

  @override
  Future<void> cancelShare(String transferId) async {
    try {
      await _platform.invokeMethod('cancelShare', <String, Object?>{'id': transferId});
    } on PlatformException catch (e, stack) {
      await reportService.recordError(e, stack);
    }
  }
}
