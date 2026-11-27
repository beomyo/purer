import 'dart:async';
import 'dart:typed_data';

import 'package:purer/model/source/cloud/cloud_resource.dart';
import 'package:purer/model/source/cloud/cloud_server.dart';
import 'package:purer/services/log/purer_log.dart';
import 'package:purer/services/media/cloud_client.dart';
import 'package:purer/services/media/cloud_traffic.dart';
import 'package:smb_connect/smb_connect.dart';

// SMB/CIFS backend built on the pure Dart `smb_connect` client.
//
// URL scheme used for entries and folders: `smb://host/share/sub/folder`
// (a trailing slash marks a collection).
class SmbClient implements CloudClient {
  static const _readChunkSize = 256 * 1024;
  static const _listTimeout = Duration(seconds: 60);
  static const _readTimeout = Duration(seconds: 120);
  static const _deleteTimeout = Duration(seconds: 120);

  final CloudServer server;

  SmbConnect? _connect;
  bool _closed = false;

  new(this.server);

  static void _log(String op, String url, {int? count, int? bytes, Duration? elapsed, Object? error}) {
    final target = PurerLog.redactUrl(url);
    final elapsedMs = elapsed?.inMilliseconds;
    if (error != null) {
      final code = error is CloudException && error.statusCode != null ? ' status=${error.statusCode}' : '';
      purerLog.error(PurerLogCategory.network, '$op $target$code error=$error');
    } else {
      final parts = [
        '$op $target',
        if (count != null) 'count=$count',
        if (bytes != null) 'bytes=$bytes',
        if (elapsedMs != null) '${elapsedMs}ms',
      ];
      purerLog.info(PurerLogCategory.network, parts.join(' '));
    }
  }

  String get _host => server.uri?.host ?? server.url;

  // SMB resources are only reachable through the loopback HTTP bridge, which
  // carries the credentials in the connection itself, so no header is needed.
  @override
  Map<String, String> get requestHeaders => const {};

  Future<SmbConnect> _sureConnect() async {
    final existing = _connect;
    if (existing != null) return existing;
    final connect = await SmbConnect.connectAuth(
      host: _host,
      username: server.username,
      password: server.password,
      domain: server.domain,
      onDisconnect: (_) => _connect = null,
    );
    _connect = connect;
    return connect;
  }

  void _reset() {
    final connect = _connect;
    _connect = null;
    try {
      connect?.close();
    } catch (_) {
      // ignore
    }
  }

  @override
  void close() {
    _closed = true;
    _reset();
  }

  // generic retry: drop the (possibly stale) connection and reconnect once
  Future<T> _withRetry<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (error) {
      if (error is CloudException) rethrow;
      if (error is CloudAbortException) rethrow;
      // a deadline is not a stale session: retrying would just wait again
      if (error is TimeoutException) rethrow;
      if (_closed) rethrow;
      // a stale SMB session usually raises a plain error/string; retry once
      _reset();
      try {
        return await action();
      } catch (retryError) {
        if (retryError is CloudAbortException) rethrow;
        if (retryError is TimeoutException) rethrow;
        throw CloudException(_describe(retryError));
      }
    }
  }

  static String _describe(Object error) {
    if (error is CloudException) return error.message;
    final text = error.toString();
    if (text.contains('Access denied') || text.contains('NT_STATUS_ACCESS_DENIED')) {
      return '没有访问权限，请检查用户名、密码和共享权限';
    }
    if (text.contains('NT_STATUS_LOGON_FAILURE') || text.contains('Logon failure')) {
      return '认证失败，请检查用户名和密码';
    }
    if (text.contains('NT_STATUS_BAD_NETWORK_NAME') || text.contains('Object Name Not Found')) {
      return '找不到共享目录';
    }
    return text;
  }

  // `smb://host/share/sub/folder` -> `/share/sub/folder`. Shared with the
  // registry and the loopback bridge, so every caller derives the same path.
  static String pathOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '/';
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? '/' : '/${segments.join('/')}';
  }

  String _smbPath(String url) => pathOf(url);

  static String urlForPath(String host, String smbPath, {required bool isCollection}) {
    final uri = Uri(scheme: 'smb', host: host, path: smbPath);
    var value = uri.toString();
    if (isCollection && !value.endsWith('/')) value = '$value/';
    return value;
  }

  String _urlForPath(String smbPath, {required bool isCollection}) => urlForPath(_host, smbPath, isCollection: isCollection);

  @override
  Future<List<CloudResource>> list(String url) {
    final path = _smbPath(url);
    final started = DateTime.now();
    final transfer = cloudTraffic.begin('LIST', url);
    return _withRetry(() async {
      final connect = await _sureConnect();
      return (path == '/') ? _listShares(connect) : _listFolder(connect, path);
    }).timeout(_listTimeout).then(
      (resources) {
        _log('LIST', url, count: resources.length, elapsed: DateTime.now().difference(started));
        return resources;
      },
      onError: (Object error) {
        _log('LIST', url, elapsed: DateTime.now().difference(started), error: error);
        throw error;
      },
    ).whenComplete(() => cloudTraffic.finish(transfer));
  }

  Future<List<CloudResource>> _listShares(SmbConnect connect) async {
    final shares = await connect.listShares();
    final resources = <CloudResource>[];
    for (final share in shares) {
      if (share.name.isEmpty) continue;
      resources.add(
        CloudResource(
          url: _urlForPath('/${share.name}', isCollection: true),
          name: share.name,
          isCollection: true,
        ),
      );
    }
    return resources;
  }

  Future<List<CloudResource>> _listFolder(SmbConnect connect, String path) async {
    final folder = await connect.file(path);
    if (!folder.isExists) {
      throw const CloudException('文件夹不存在', statusCode: 404);
    }
    if (!folder.isDirectory()) {
      throw const CloudException('该路径不是文件夹', statusCode: 400);
    }
    final files = await connect.listFiles(folder);
    final resources = <CloudResource>[];
    for (final file in files) {
      final name = file.name;
      if (name.isEmpty || name == '.' || name == '..') continue;
      final isDirectory = file.isDirectory();
      final modified = file.lastModified;
      resources.add(
        CloudResource(
          url: _urlForPath(file.path, isCollection: isDirectory),
          name: name,
          isCollection: isDirectory,
          sizeBytes: isDirectory ? null : file.size,
          dateModifiedMillis: modified > 0 ? modified : null,
        ),
      );
    }
    return resources;
  }

  // `SmbConnect.delete` removes a directory recursively, which is what a
  // long-press on a folder is expected to do
  @override
  Future<void> delete(String url) {
    final started = DateTime.now();
    final transfer = cloudTraffic.begin('DELETE', url);
    return _withRetry(() async {
      final connect = await _sureConnect();
      final file = await connect.file(_smbPath(url));
      if (!file.isExists) return;
      await connect.delete(file);
    }).timeout(_deleteTimeout).then(
      (_) => _log('DELETE', url, elapsed: DateTime.now().difference(started)),
      onError: (Object error) {
        _log('DELETE', url, elapsed: DateTime.now().difference(started), error: error);
        throw error;
      },
    ).whenComplete(() => cloudTraffic.finish(transfer));
  }

  @override
  Future<Uint8List> getBytes(String url, {CloudAbort? abort}) {
    // the deadline aborts the transfer itself, so a stalled read does not keep
    // the session busy for the whole timeout
    final deadline = CloudAbort();
    final timer = Timer(_readTimeout, deadline.abort);
    final started = DateTime.now();
    final transfer = cloudTraffic.begin('READ', url);
    return _readRange(url, abort: abort, deadline: deadline, transfer: transfer).whenComplete(timer.cancel).then(
      (bytes) {
        _log('READ', url, bytes: bytes.length, elapsed: DateTime.now().difference(started));
        return bytes;
      },
      onError: (Object error) {
        if (error is CloudAbortException) {
          purerLog.debug(PurerLogCategory.network, 'READ ${PurerLog.redactUrl(url)} aborted');
          throw error;
        }
        _log('READ', url, elapsed: DateTime.now().difference(started), error: error);
        throw error;
      },
    ).whenComplete(() => cloudTraffic.finish(transfer));
  }

  // reads the file (optionally the leading `maxBytes`) through a random access
  // handle, so the data is fetched in large chunks instead of the tiny packets
  // used by the streaming API
  Future<Uint8List> _readRange(String url, {int? maxBytes, CloudAbort? abort, CloudAbort? deadline, int? transfer}) {
    final path = _smbPath(url);
    return _withRetry(() async {
      final connect = await _sureConnect();
      final file = await connect.file(path);
      if (!file.isExists) {
        throw const CloudException('file not found', statusCode: 404);
      }
      final total = file.size;
      final target = maxBytes == null ? total : (maxBytes < total ? maxBytes : total);
      final handle = await connect.open(file);
      final builder = BytesBuilder();
      try {
        if (target > 0) {
          await handle.setPosition(0);
          final buffer = Uint8List(_readChunkSize);
          var remaining = target;
          while (remaining > 0) {
            if (abort?.aborted ?? false) {
              throw const CloudAbortException();
            }
            if (deadline?.aborted ?? false) {
              throw TimeoutException('transfer deadline exceeded');
            }
            final wanted = remaining < _readChunkSize ? remaining : _readChunkSize;
            final read = await handle.readInto(buffer, 0, wanted);
            if (read <= 0) break;
            builder.add(read == buffer.length ? buffer : Uint8List.view(buffer.buffer, 0, read));
            if (transfer != null) cloudTraffic.addBytes(transfer, read);
            remaining -= read;
          }
        }
      } finally {
        try {
          await handle.close();
        } catch (_) {
          // ignore
        }
      }
      return builder.takeBytes();
    });
  }

  @override
  Future<void> testConnection() async {
    purerLog.info(PurerLogCategory.network, '测试连接 ${PurerLog.redactUrl(server.url)} (SMB)');
    await list(server.url).timeout(_listTimeout);
  }

  Future<int> fileSize(String url) async {
    return _withRetry(() async {
      final connect = await _sureConnect();
      final file = await connect.file(_smbPath(url));
      if (!file.isExists) {
        throw const CloudException('file not found', statusCode: 404);
      }
      return file.size;
    }).timeout(_readTimeout);
  }

  // streams a byte range of a file, used by the loopback bridge that feeds the
  // video player. The handle is closed when the stream ends or is cancelled.
  Stream<Uint8List> openRange(String url, {int start = 0, int? length}) async* {
    final path = _smbPath(url);
    final transfer = cloudTraffic.begin('STREAM', url);
    try {
      final connect = await _sureConnect();
      final file = await connect.file(path);
      if (!file.isExists) {
        throw const CloudException('file not found', statusCode: 404);
      }
      final total = file.size;
      var remaining = length ?? (total - start);
      final handle = await connect.open(file);
      try {
        if (start > 0) {
          await handle.setPosition(start);
        }
        final buffer = Uint8List(_readChunkSize);
        while (remaining > 0) {
          final wanted = remaining < _readChunkSize ? remaining : _readChunkSize;
          final read = await handle.readInto(buffer, 0, wanted);
          if (read <= 0) break;
          remaining -= read;
          cloudTraffic.addBytes(transfer, read);
          yield read == buffer.length ? Uint8List.fromList(buffer) : Uint8List.fromList(Uint8List.view(buffer.buffer, 0, read));
        }
      } finally {
        try {
          await handle.close();
        } catch (_) {
          // ignore
        }
      }
    } finally {
      cloudTraffic.finish(transfer);
    }
  }
}
