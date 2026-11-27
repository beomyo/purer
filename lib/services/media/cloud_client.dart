import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:purer/model/source/cloud/cloud_resource.dart';

class CloudException implements Exception {
  final String message;
  final int? statusCode;

  const new(this.message, {this.statusCode});

  bool get isAuthError => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'CloudException($statusCode): $message';
}

// thrown when a transfer is dropped because nobody wants it any more (the
// folder was left) or because it exceeded its budget
class CloudAbortException implements Exception {
  const new();
}

// lets the caller drop a transfer that is no longer useful, so its connection
// and bandwidth are freed for the next listing instead of being held for up to
// two minutes
class CloudAbort {
  bool _aborted = false;

  bool get aborted => _aborted;

  void abort() => _aborted = true;
}

// A user facing, Simplified Chinese description of a cloud failure. The
// backends throw localized messages themselves; this also maps the status codes
// of generic wrappers and the few non-cloud errors that can reach the UI.
String cloudErrorText(Object error) {
  if (error is CloudException) {
    final status = error.statusCode;
    return switch (status) {
      401 => '认证失败，请检查用户名和密码',
      403 => '没有访问权限',
      404 => '路径不存在，请检查地址',
      405 => '该地址不是 WebDAV 服务，请检查地址',
      408 => '服务器响应超时',
      429 => '服务器限流，请稍后再试',
      final s? when s >= 500 => '服务器错误（$s）',
      _ => error.message.isEmpty ? '请求失败' : error.message,
    };
  }
  if (error is TimeoutException) return '服务器响应超时';
  if (error is SocketException) return '连接失败：${error.message}';
  return '$error';
}

// common contract implemented by every remote service backend (WebDAV)
abstract class CloudClient {
  // headers a consumer must send to fetch a resource directly from this
  // backend (e.g. WebDAV Basic auth)
  Map<String, String> get requestHeaders;

  // lists the entries of a folder
  Future<List<CloudResource>> list(String url);

  // reads a whole file. `abort` lets the caller drop the transfer when the
  // entry is no longer on screen
  Future<Uint8List> getBytes(String url, {CloudAbort? abort});

  // deletes a file, or a folder and everything it contains
  Future<void> delete(String url);

  // moves a file, or a folder and everything it contains. A rename is a move
  // inside the same parent.
  Future<void> move(String fromUrl, String toUrl, {bool overwrite = false});

  // verifies that the server can be reached and browsed
  Future<void> testConnection();

  void close();
}
