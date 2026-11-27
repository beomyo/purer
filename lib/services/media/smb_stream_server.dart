import 'dart:async';
import 'dart:io';

import 'package:purer/model/settings/settings.dart';
import 'package:purer/model/source/cloud/cloud_server.dart';
import 'package:purer/services/media/cloud_mime.dart';
import 'package:purer/services/media/smb_client.dart';
import 'package:flutter/foundation.dart';

// Loopback HTTP bridge that exposes SMB files over HTTP so that consumers that
// only speak HTTP (the mpv based video player) can stream them. Byte ranges are
// supported, which lets the player seek.
class SmbStreamServer {
  HttpServer? _server;
  int? _port;

  // separate SMB sessions dedicated to streaming, so that long lived video
  // reads do not contend with thumbnail downloads
  final Map<String, SmbClient> _clients = {};

  Future<int?> _ensureStarted() async {
    if (_server != null) return _port;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      _port = server.port;
      server.listen(_handle, onError: (Object error) => debugPrint('smb stream server error=$error'));
      return _port;
    } catch (error) {
      debugPrint('smb stream server failed to start error=$error');
      return null;
    }
  }

  Future<String?> urlFor(String serverId, String smbPath) async {
    final port = await _ensureStarted();
    if (port == null) return null;
    return 'http://127.0.0.1:$port/smb?server=${Uri.encodeComponent(serverId)}&path=${Uri.encodeComponent(smbPath)}';
  }

  CloudServer? _serverFor(String serverId) {
    for (final candidate in settings.cloudServers) {
      if (candidate.id == serverId) return candidate;
    }
    return null;
  }

  SmbClient? _clientFor(String serverId) {
    final server = _serverFor(serverId);
    if (server == null || !server.isSmb) {
      closeServer(serverId);
      return null;
    }
    final cached = _clients[serverId];
    // a streaming session is opened with the credentials of its server: an
    // edited configuration must not keep playing through the old one
    if (cached != null && cached.server == server) return cached;
    cached?.close();
    final client = SmbClient(server);
    _clients[serverId] = client;
    return client;
  }

  void closeServer(String serverId) {
    _clients.remove(serverId)?.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final serverId = request.uri.queryParameters['server'];
      final smbPath = request.uri.queryParameters['path'];
      final client = serverId == null ? null : _clientFor(serverId);
      if (client == null || smbPath == null || smbPath.isEmpty) {
        response.statusCode = HttpStatus.badRequest;
        await response.close();
        return;
      }

      final url = SmbClient.urlForPath(Uri.parse(client.server.url).host, smbPath, isCollection: false);
      final size = await client.fileSize(url);

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      var start = 0;
      var end = size - 1;
      var partial = false;
      if (rangeHeader != null) {
        final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(rangeHeader);
        if (match != null) {
          final rawStart = match.group(1);
          final rawEnd = match.group(2);
          if ((rawStart == null || rawStart.isEmpty) && rawEnd != null && rawEnd.isNotEmpty) {
            // suffix range: `bytes=-500` means the last 500 bytes
            final suffix = int.tryParse(rawEnd) ?? 0;
            if (suffix > 0) {
              start = size > suffix ? size - suffix : 0;
              end = size - 1;
            }
          } else {
            if (rawStart != null && rawStart.isNotEmpty) {
              start = int.tryParse(rawStart) ?? 0;
            }
            if (rawEnd != null && rawEnd.isNotEmpty) {
              end = int.tryParse(rawEnd) ?? end;
            }
          }
          if (end >= size) end = size - 1;
          if (start < 0) start = 0;
          if (start > end) {
            response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
            await response.close();
            return;
          }
          partial = true;
        }
      }

      final length = end - start + 1;
      response.headers.contentType = ContentType.parse(cloudMimeForName(smbPath));
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentLengthHeader, '$length');
      if (partial) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$size');
      }

      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      await response.addStream(client.openRange(url, start: start, length: length));
      await response.close();
    } catch (error) {
      debugPrint('smb stream failed error=$error');
      try {
        if (response.statusCode == HttpStatus.ok) {
          response.statusCode = HttpStatus.internalServerError;
          await response.close();
        }
      } catch (_) {
        // response already closed
      }
    }
  }

}

final smbStreamServer = SmbStreamServer();
