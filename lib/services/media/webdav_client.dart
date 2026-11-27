import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:purer/model/source/cloud/cloud_resource.dart';
import 'package:purer/model/source/cloud/cloud_server.dart';
import 'package:purer/services/log/purer_log.dart';
import 'package:purer/services/media/cloud_client.dart';
import 'package:purer/services/media/cloud_traffic.dart';
import 'package:purer/utils/cloud_url.dart';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:xml/xml.dart';

// a network level failure (as opposed to a server response): these are the ones
// worth a retry, because the usual cause is a pooled keep-alive connection the
// server already closed, and a fresh attempt succeeds at once
class _TransportError implements Exception {
  final Object cause;
  // HTTP status when the failure is a server response worth retrying (429/5xx),
  // or 408 for a timeout, so the caller can classify the failure
  final int? statusCode;
  // `Retry-After` of a rate limited response, when the server sent one
  final Duration? retryAfter;

  const new(this.cause, {this.statusCode, this.retryAfter});
}

class WebDavClient implements CloudClient {
  static const _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<D:propfind xmlns:D="DAV:">'
      '<D:prop>'
      '<D:resourcetype/>'
      '<D:getcontenttype/>'
      '<D:getcontentlength/>'
      '<D:getlastmodified/>'
      '</D:prop>'
      '</D:propfind>';

  static const _listTimeout = Duration(seconds: 45);
  static const _getTimeout = Duration(seconds: 120);
  static const _deleteTimeout = Duration(seconds: 120);

  final CloudServer server;

  // normalized base URL, always ending with a separator
  late final Uri baseUri;
  late final http.Client _client;

  new(this.server) {
    var url = server.url.trim();
    if (!url.endsWith('/')) {
      url = '$url/';
    }
    baseUri = Uri.parse(url);
    // an explicit HTTP client, so that an unreachable host or a half open
    // connection cannot hold a request open for minutes, and so that pooled
    // connections are dropped early (reusing one the server already closed is
    // the usual reason a request hangs instead of failing)
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 8);
    if (server.ignoreTlsErrors) {
      httpClient.badCertificateCallback = ((cert, host, port) => true);
    }
    _client = IOClient(httpClient);
  }

  @override
  void close() => _client.close();

  // one line per request, with what a diagnosis needs: operation, target,
  // response status, size and duration (credentials are redacted)
  static void _log(String op, String url, {int? status, int? bytes, int? count, Duration? elapsed, Object? error}) {
    final target = PurerLog.redactUrl(url);
    final elapsedMs = elapsed?.inMilliseconds;
    if (error != null) {
      final code = error is CloudException && error.statusCode != null ? ' status=${error.statusCode}' : '';
      purerLog.error(PurerLogCategory.network, '$op $target$code error=$error');
    } else {
      final parts = [
        '$op $target',
        if (status != null) 'status=$status',
        if (count != null) 'count=$count',
        if (bytes != null) 'bytes=$bytes',
        if (elapsedMs != null) '${elapsedMs}ms',
      ];
      purerLog.info(PurerLogCategory.network, parts.join(' '));
    }
  }

  // retries a network level failure once: the first attempt may have used a
  // stale pooled connection, the second one opens a fresh one
  Future<T> _withRetry<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on _TransportError catch (error) {
      // respect a rate limit's `Retry-After` (bounded: making the user wait
      // minutes would be worse than surfacing the failure), otherwise pause
      // briefly so the server/connection can stabilize
      final retryAfter = error.retryAfter;
      final delay = retryAfter == null
          ? const Duration(milliseconds: 500)
          : (retryAfter > const Duration(seconds: 10) ? const Duration(seconds: 10) : retryAfter);
      await Future<void>.delayed(delay);
      try {
        return await action();
      } on _TransportError catch (retryError) {
        throw CloudException(_describeTransport(retryError), statusCode: retryError.statusCode);
      } on CloudAbortException {
        rethrow;
      } on CloudException {
        rethrow;
      } catch (retryError) {
        throw CloudException('请求失败：$retryError');
      }
    }
  }

  // `Retry-After` is either a number of seconds or an HTTP date
  static Duration? _retryAfterOf(http.BaseResponse response) {
    final value = response.headers['retry-after'];
    if (value == null || value.isEmpty) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return seconds > 0 ? Duration(seconds: seconds) : null;
    try {
      final delta = HttpDate.parse(value).difference(DateTime.now());
      return delta > Duration.zero ? delta : null;
    } catch (_) {
      return null;
    }
  }

  static String _describeTransport(_TransportError error) {
    final status = error.statusCode;
    if (status == 408) return '服务器响应超时';
    if (status != null) return '服务器错误（$status）';
    final cause = error.cause;
    if (cause is SocketException) return '连接失败：${cause.message}';
    if (cause is HandshakeException) return 'TLS 握手失败：${cause.message}';
    if (cause is TimeoutException) return '服务器响应超时';
    return '连接失败：$cause';
  }

  @override
  Map<String, String> get requestHeaders {
    if (server.username.isEmpty && server.password.isEmpty) return const {};
    final token = base64Encode(utf8.encode('${server.username}:${server.password}'));
    return {'Authorization': 'Basic $token'};
  }

  Uri resolve(String url) {
    final uri = Uri.parse(url);
    if (uri.hasScheme) return uri;
    return baseUri.resolveUri(uri);
  }

  @override
  Future<void> testConnection() async {
    purerLog.info(PurerLogCategory.network, '测试连接 ${PurerLog.redactUrl(server.url)} (WebDAV)');
    await list(baseUri.toString());
  }

  @override
  Future<List<CloudResource>> list(String url) async {
    final requestUrl = resolve(url);
    // a request object can only be finalized once, so a retry needs a fresh one
    http.Request build() => http.Request('PROPFIND', requestUrl)
      ..headers.addAll({
        ...requestHeaders,
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      })
      ..bodyBytes = utf8.encode(_propfindBody);

    final started = DateTime.now();
    try {
      final body = await _send(build, op: 'PROPFIND', url: requestUrl.toString(), timeout: _listTimeout);
      // a folder with thousands of entries produces a multi-megabyte XML
      // document; parsing large ones off the UI isolate keeps the grid smooth.
      final resources = body.length > 128 * 1024
          ? await _parseOffThread(body, requestUrl.path, baseUri)
          : _parseMultiStatus(body, requestUrl.path, baseUri);
      _log('PROPFIND', requestUrl.toString(), status: 207, count: resources.length, elapsed: DateTime.now().difference(started));
      return resources;
    } catch (error) {
      _log('PROPFIND', requestUrl.toString(), elapsed: DateTime.now().difference(started), error: error);
      rethrow;
    }
  }

  @override
  Future<Uint8List> getBytes(String url, {CloudAbort? abort}) {
    final requestUrl = resolve(url);
    final started = DateTime.now();
    // deadline is scoped per attempt so a retry gets a fresh timeout instead of inheriting an aborted deadline
    return _withRetry(() {
      final deadline = CloudAbort();
      final timer = Timer(_getTimeout, deadline.abort);
      return _download(requestUrl, abort, deadline).whenComplete(timer.cancel);
    }).then(
      (bytes) {
        _log('GET', requestUrl.toString(), status: 200, bytes: bytes.length, elapsed: DateTime.now().difference(started));
        return bytes;
      },
      onError: (Object error) {
        // a transfer dropped on purpose (the folder was left) is not a failure
        if (error is CloudAbortException) {
          purerLog.debug(PurerLogCategory.network, 'GET ${PurerLog.redactUrl(requestUrl.toString())} aborted');
          throw error;
        }
        _log('GET', requestUrl.toString(), elapsed: DateTime.now().difference(started), error: error);
        throw error;
      },
    );
  }

  Future<Uint8List> _download(Uri requestUrl, CloudAbort? caller, CloudAbort deadline) async {
    // registered with the traffic monitor so the log page can show a transfer
    // even after the tile that asked for it gave up
    final transfer = cloudTraffic.begin('GET', requestUrl.toString());
    try {
      return await _downloadTracked(requestUrl, caller, deadline, transfer);
    } finally {
      cloudTraffic.finish(transfer);
    }
  }

  Future<Uint8List> _downloadTracked(Uri requestUrl, CloudAbort? caller, CloudAbort deadline, int transfer) async {
    final request = http.Request('GET', requestUrl)..headers.addAll(requestHeaders);
    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(_getTimeout);
    } on SocketException catch (e) {
      throw _TransportError(e);
    } on HandshakeException catch (e) {
      throw _TransportError(e);
    } on HttpException catch (e) {
      throw _TransportError(e);
    } on http.ClientException catch (e) {
      throw _TransportError(e);
    } on TimeoutException catch (e) {
      throw _TransportError(e, statusCode: 408);
    }
    if (response.statusCode >= 400) {
      if (response.statusCode == 429 || (response.statusCode >= 500 && response.statusCode <= 504)) {
        throw _TransportError(
          HttpException('server error ${response.statusCode}', uri: requestUrl),
          statusCode: response.statusCode,
          retryAfter: _retryAfterOf(response),
        );
      }
      throw CloudException('下载失败', statusCode: response.statusCode);
    }

    final builder = BytesBuilder(copy: false);
    try {
      // leaving this loop (including by throwing) cancels the subscription,
      // which closes the connection; timeout on chunks prevents silent socket stall
      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        if (caller?.aborted ?? false) {
          throw const CloudAbortException();
        }
        if (deadline.aborted) {
          // not a stale connection: do not let the retry wrapper start the
          // whole transfer again
          throw const CloudException('服务器响应超时', statusCode: 408);
        }
        builder.add(chunk);
        cloudTraffic.addBytes(transfer, chunk.length);
      }
    } on TimeoutException catch (e) {
      throw _TransportError(e, statusCode: 408);
    } on SocketException catch (e) {
      throw _TransportError(e);
    } on HandshakeException catch (e) {
      throw _TransportError(e);
    } on HttpException catch (e) {
      throw _TransportError(e);
    } on http.ClientException catch (e) {
      throw _TransportError(e);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> delete(String url) {
    final requestUrl = resolve(url);
    final started = DateTime.now();
    final transfer = cloudTraffic.begin('DELETE', requestUrl.toString());
    return _withRetry(() async {
      http.Response response;
      try {
        response = await _client.delete(requestUrl, headers: requestHeaders).timeout(_deleteTimeout);
      } on SocketException catch (e) {
        throw _TransportError(e);
      } on HandshakeException catch (e) {
        throw _TransportError(e);
      } on HttpException catch (e) {
        throw _TransportError(e);
      } on http.ClientException catch (e) {
        throw _TransportError(e);
      }
      // a missing resource is already in the desired state
      _log('DELETE', requestUrl.toString(), status: response.statusCode, elapsed: DateTime.now().difference(started));
      if (response.statusCode >= 400 && response.statusCode != 404) {
        throw CloudException('删除失败', statusCode: response.statusCode);
      }
    }).catchError((Object error) {
      _log('DELETE', requestUrl.toString(), elapsed: DateTime.now().difference(started), error: error);
      throw error;
    }).whenComplete(() => cloudTraffic.finish(transfer));
  }

  // uploads a whole file, used by the shared video thumbnail cache. A missing
  // parent collection is reported to the caller (404/409), which can create it
  // with `makeDirectory` and retry.
  Future<void> putBytes(String url, Uint8List bytes, {String contentType = 'application/octet-stream'}) {
    final requestUrl = resolve(url);
    final started = DateTime.now();
    final transfer = cloudTraffic.begin('PUT', requestUrl.toString());
    return _withRetry(() async {
      final request = http.Request('PUT', requestUrl)
        ..headers.addAll({
          ...requestHeaders,
          'Content-Type': contentType,
        })
        ..bodyBytes = bytes;
      http.StreamedResponse response;
      try {
        response = await _client.send(request).timeout(_getTimeout);
        await response.stream.drain<void>();
      } on SocketException catch (e) {
        throw _TransportError(e);
      } on HandshakeException catch (e) {
        throw _TransportError(e);
      } on HttpException catch (e) {
        throw _TransportError(e);
      } on http.ClientException catch (e) {
        throw _TransportError(e);
      } on TimeoutException catch (e) {
        throw _TransportError(e, statusCode: 408);
      }
      final status = response.statusCode;
      if (status >= 200 && status < 300) {
        cloudTraffic.addBytes(transfer, bytes.length);
        _log('PUT', requestUrl.toString(), status: status, bytes: bytes.length, elapsed: DateTime.now().difference(started));
        return;
      }
      // a transient server failure is worth the retry the wrapper provides
      if (status == 429 || (status >= 500 && status <= 504)) {
        throw _TransportError(
          HttpException('server error $status', uri: requestUrl),
          statusCode: status,
          retryAfter: _retryAfterOf(response),
        );
      }
      throw CloudException('上传失败', statusCode: status);
    }).catchError((Object error) {
      _log('PUT', requestUrl.toString(), bytes: bytes.length, elapsed: DateTime.now().difference(started), error: error);
      throw error;
    }).whenComplete(() => cloudTraffic.finish(transfer));
  }

  // creates a collection. WebDAV answers 405 when it already exists on many
  // servers, which is the desired state anyway.
  Future<void> makeDirectory(String url) {
    final requestUrl = resolve(url);
    final transfer = cloudTraffic.begin('MKCOL', requestUrl.toString());
    return _withRetry(() async {
      final request = http.Request('MKCOL', requestUrl)..headers.addAll(requestHeaders);
      http.StreamedResponse response;
      try {
        response = await _client.send(request).timeout(_listTimeout);
        await response.stream.drain<void>();
      } on SocketException catch (e) {
        throw _TransportError(e);
      } on HandshakeException catch (e) {
        throw _TransportError(e);
      } on HttpException catch (e) {
        throw _TransportError(e);
      } on http.ClientException catch (e) {
        throw _TransportError(e);
      } on TimeoutException catch (e) {
        throw _TransportError(e, statusCode: 408);
      }
      final status = response.statusCode;
      if ((status >= 200 && status < 300) || status == 405) {
        purerLog.debug(PurerLogCategory.network, 'MKCOL ${PurerLog.redactUrl(requestUrl.toString())} status=$status');
        return;
      }
      if (status == 429 || (status >= 500 && status <= 504)) {
        throw _TransportError(
          HttpException('server error $status', uri: requestUrl),
          statusCode: status,
          retryAfter: _retryAfterOf(response),
        );
      }
      throw CloudException('创建文件夹失败', statusCode: status);
    }).whenComplete(() => cloudTraffic.finish(transfer));
  }

  Future<String> _send(http.Request Function() build, {required String op, required String url, required Duration timeout}) {
    return _withRetry(() async {
      // listings have no progress of their own: the transfer is registered so
      // a multi-megabyte PROPFIND shows up (and completes) in the traffic view
      final transfer = cloudTraffic.begin(op, url);
      try {
        final response = await _exchange(build, timeout: timeout);
        cloudTraffic.addBytes(transfer, response.bodyBytes.length);
        return _decodeStatus(response);
      } finally {
        cloudTraffic.finish(transfer);
      }
    });
  }

  // sends one request (following a single redirect) and maps transport errors
  Future<http.Response> _exchange(http.Request Function() build, {required Duration timeout}) async {
    final request = build();
    http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request)).timeout(timeout);
    } on SocketException catch (e) {
      throw _TransportError(e);
    } on HandshakeException catch (e) {
      throw _TransportError(e);
    } on HttpException catch (e) {
      throw _TransportError(e);
    } on http.ClientException catch (e) {
      throw _TransportError(e);
    } on TimeoutException catch (e) {
      // a half open connection never answers: a fresh attempt usually does
      throw _TransportError(e, statusCode: 408);
    }

    // follow a single redirect if the server moved the collection
    if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
      final location = response.headers['location'];
      if (location != null) {
        final redirectRequest = http.Request(request.method, resolve(location))
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
        response = await http.Response.fromStream(await _client.send(redirectRequest)).timeout(timeout);
      }
    }
    return response;
  }

  static String _decodeStatus(http.Response response) {
    switch (response.statusCode) {
      case 200:
      case 207:
        return _decodeBody(response);
      case 401:
        throw const CloudException('认证失败，请检查用户名和密码', statusCode: 401);
      case 403:
        throw const CloudException('没有访问权限', statusCode: 403);
      case 404:
        throw const CloudException('路径不存在，请检查地址（例如 AList 需要以 /dav 结尾）', statusCode: 404);
      case 405:
        throw const CloudException('该地址不是 WebDAV 服务，请检查地址（例如 AList 需要以 /dav 结尾）', statusCode: 405);
      default:
        throw CloudException('服务器返回了意外的响应（${response.statusCode}）', statusCode: response.statusCode);
    }
  }

  // Parses a large listing in a separate isolate.
  //
  // The closure is built in this static scope on purpose: `Isolate.run` sends
  // the closure together with the context object of the scope it was created
  // in. Inside `list` that context is shared with the local `build` function,
  // which captures `this` (and through it the HTTP client, with its sockets,
  // pools and pending futures), so on folders with a large listing the send
  // failed with `Illegal argument in isolate message: object is unsendable`.
  // Here the context only holds the string, the path and the base URI.
  static Future<List<CloudResource>> _parseOffThread(String body, String requestedPath, Uri base) {
    return Isolate.run(() => _parseMultiStatus(body, requestedPath, base));
  }

  // XML is UTF-8 unless it declares otherwise, but `http`'s `Response.body`
  // falls back to latin1 when the server omits a charset, which garbles any
  // non-ASCII name a server puts raw into its PROPFIND hrefs.
  static String _decodeBody(http.Response response) {
    final contentType = response.headers['content-type'] ?? '';
    final charset = RegExp(r'charset\s*=\s*"?([^;"\s]+)', caseSensitive: false).firstMatch(contentType)?.group(1)?.toLowerCase();
    if (charset != null && charset != 'utf-8' && charset != 'utf8') {
      final encoding = Encoding.getByName(charset);
      if (encoding != null) return encoding.decode(response.bodyBytes);
    }
    var text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    return text;
  }

  // `package:xml` name matching is namespace-prefix sensitive
  // (`findAllElements('response')` does NOT match `<D:response>`),
  // so all lookups go through local-name comparisons.
  static Iterable<XmlElement> _childElements(XmlElement element, String localName) => element.childElements.where((e) => e.name.local == localName);

  static List<CloudResource> _parseMultiStatus(String body, String requestedPath, Uri base) {
    final resources = <CloudResource>[];
    final document = XmlDocument.parse(body);

    for (final response in document.descendantElements.where((e) => e.name.local == 'response')) {
      final hrefElement = _childElements(response, 'href').firstOrNull;
      if (hrefElement == null) continue;
      final href = hrefElement.innerText.trim();
      if (href.isEmpty) continue;

      final parsed = Uri.parse(href);
      final resolved = parsed.hasScheme ? parsed : base.resolveUri(parsed);
      // `Uri.path` keeps percent-encoding, so compare on the raw path
      final rawPath = resolved.path;
      final rawRequestedPath = requestedPath;
      if (rawPath == rawRequestedPath || '$rawPath/' == rawRequestedPath) continue;

      final prop = _findProp(response);
      final resourceType = prop == null ? null : _childElements(prop, 'resourcetype').firstOrNull;
      final isCollection = resourceType != null && _childElements(resourceType, 'collection').isNotEmpty;

      final mimeType = _text(prop, 'getcontenttype')?.split(';').first.trim();
      final sizeBytes = int.tryParse(_text(prop, 'getcontentlength') ?? '');
      final lastModified = _text(prop, 'getlastmodified');

      // last path segment, percent-decoded for display
      final trimmedRaw = rawPath.endsWith('/') ? rawPath.substring(0, rawPath.length - 1) : rawPath;
      final slash = trimmedRaw.lastIndexOf('/');
      final name = decodeCloudSegment(trimmedRaw.substring(slash + 1));
      if (name.isEmpty) continue;

      resources.add(
        CloudResource(
          url: resolved.toString(),
          name: name,
          isCollection: isCollection,
          mimeType: (mimeType != null && mimeType.isNotEmpty) ? mimeType : null,
          sizeBytes: sizeBytes,
          dateModifiedMillis: lastModified != null ? _tryParseHttpDate(lastModified) : null,
        ),
      );
    }

    resources.sort((a, b) {
      if (a.isCollection != b.isCollection) return a.isCollection ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return resources;
  }

  static XmlElement? _findProp(XmlElement response) {
    for (final propstat in _childElements(response, 'propstat')) {
      final status = _childElements(propstat, 'status').firstOrNull?.innerText ?? '';
      if (status.contains(' 200 ') || status.isEmpty) {
        final prop = _childElements(propstat, 'prop').firstOrNull;
        if (prop != null) return prop;
      }
    }
    // fall back to any `prop`
    return _childElements(response, 'prop').firstOrNull;
  }

  static String? _text(XmlElement? prop, String localName) {
    final element = prop == null ? null : _childElements(prop, localName).firstOrNull;
    final text = element?.innerText.trim();
    return (text == null || text.isEmpty) ? null : text;
  }

  static int? _tryParseHttpDate(String value) {
    try {
      return HttpDate.parse(value).millisecondsSinceEpoch;
    } catch (_) {
      try {
        return DateTime.parse(value).millisecondsSinceEpoch;
      } catch (_) {
        return null;
      }
    }
  }
}
