import 'dart:async';
import 'dart:io';

import 'package:purer/model/settings/settings.dart';
import 'package:purer/services/common/services.dart';
import 'package:purer/utils/cloud_url.dart';
import 'package:flutter/foundation.dart';

// Severity of a log record. The log page colors the records by level, and the
// user can filter on them.
enum PurerLogLevel {
  debug('调试'),
  info('信息'),
  success('成功'),
  warn('警告'),
  error('错误');

  final String label;

  new(this.label);

  // the on-disk/plain text name, stable so logs can be grepped
  String get key => switch (this) {
    PurerLogLevel.debug => 'DEBUG',
    PurerLogLevel.info => 'INFO',
    PurerLogLevel.success => 'OK',
    PurerLogLevel.warn => 'WARN',
    PurerLogLevel.error => 'ERROR',
  };
}

// What a record is about, so the log page can filter on it (and the user can
// follow one kind of operation without the noise of the others).
enum PurerLogCategory {
  app('应用'),
  network('网络'),
  thumbnail('缩略图'),
  scrape('刮削'),
  cache('缓存'),
  video('视频');

  final String label;

  new(this.label);

  String get key => switch (this) {
    PurerLogCategory.app => 'APP',
    PurerLogCategory.network => 'NET',
    PurerLogCategory.thumbnail => 'THUMB',
    PurerLogCategory.scrape => 'SCRAPE',
    PurerLogCategory.cache => 'CACHE',
    PurerLogCategory.video => 'VIDEO',
  };
}

class PurerLogRecord {
  final DateTime time;
  final PurerLogLevel level;
  final PurerLogCategory category;
  final String message;

  const new(this.time, this.level, this.category, this.message);

  String get timeText => '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}.${time.millisecond.toString().padLeft(3, '0')}';

  String get dateTimeText => '${time.year}-${_two(time.month)}-${_two(time.day)} $timeText';

  String toLine() => '$dateTimeText ${level.key.padRight(5)} [${category.key.padRight(6)}] $message';

  static String _two(int value) => value.toString().padLeft(2, '0');
}

// In-memory ring buffer of the operations of the app, with an optional
// best-effort copy on disk so a problem can still be diagnosed after a restart.
//
// Every call is cheap when logging is turned off (`enabled` is read first), and
// the buffer is bounded, so the instrumentation can stay in the hot paths
// (network requests, thumbnail extraction) without growing memory over time.
class PurerLog {
  static const int maxRecords = 4000;
  // a crash/post-mortem copy, capped so it cannot grow without bound
  static const int maxFileBytes = 2 << 20;

  final List<PurerLogRecord> _records = [];
  final ValueNotifier<int> revision = ValueNotifier(0);

  final StringBuffer _pending = StringBuffer();
  Timer? _flushTimer;
  File? _file;
  bool _fileUnavailable = false;

  bool get enabled => settings.cloudLogEnabled;

  // oldest first, so the log page can show the newest at the top
  List<PurerLogRecord> get records => _records;

  void log(PurerLogLevel level, PurerLogCategory category, String message) {
    if (!enabled) return;
    final record = PurerLogRecord(DateTime.now(), level, category, message);
    _records.add(record);
    if (_records.length > maxRecords) {
      _records.removeRange(0, _records.length - maxRecords);
    }
    revision.value++;
    if (kDebugMode) {
      debugPrint('[${category.key}] ${level.key} $message');
    }
    _pending.writeln(record.toLine());
    _flushTimer ??= Timer(const Duration(seconds: 3), () {
      _flushTimer = null;
      unawaited(_flushToFile());
    });
  }

  void debug(PurerLogCategory category, String message) => log(PurerLogLevel.debug, category, message);

  void info(PurerLogCategory category, String message) => log(PurerLogLevel.info, category, message);

  void success(PurerLogCategory category, String message) => log(PurerLogLevel.success, category, message);

  void warn(PurerLogCategory category, String message) => log(PurerLogLevel.warn, category, message);

  void error(PurerLogCategory category, String message) => log(PurerLogLevel.error, category, message);

  void clear() {
    _records.clear();
    _pending.clear();
    revision.value++;
    unawaited(_truncateFile());
  }

  String exportText() => _records.map((r) => r.toLine()).join('\n');

  Future<File?> exportFile() async {
    final file = await _sureFile();
    if (file == null) return null;
    try {
      await file.writeAsString(exportText(), flush: true);
      return file;
    } catch (_) {
      return null;
    }
  }

  // The complete log for the user to save: the on-disk history (which outlives
  // the in-memory ring buffer, so it also holds what happened before the app
  // was restarted) plus anything still pending. `header` carries what a
  // diagnosis needs to identify the app, the device and the current transfers.
  Future<String> exportCompleteText({String? header}) async {
    await _flushToFile();
    final buffer = StringBuffer();
    if (header != null && header.trim().isNotEmpty) {
      buffer.writeln(header.trimRight());
      buffer.writeln();
    }
    var body = '';
    final file = _file;
    if (file != null) {
      try {
        if (await file.exists()) body = await file.readAsString();
      } catch (_) {
        // fall back to the in-memory records below
      }
    }
    if (body.trim().isEmpty) body = exportText();
    buffer.writeln(body.trimRight());
    return buffer.toString();
  }

  // hides credentials that may be embedded in a URL (`scheme://user:pass@host`),
  // and decodes the path so Chinese folder names are readable in the log
  static String redactUrl(String url) {
    final schemeEnd = url.indexOf('://');
    if (schemeEnd < 0) return decodeCloudUrl(url);
    final at = url.indexOf('@', schemeEnd + 3);
    if (at < 0) return decodeCloudUrl(url);
    // only redact when the `@` belongs to the authority, not to a path segment
    final authorityEnd = url.indexOf('/', schemeEnd + 3);
    if (authorityEnd >= 0 && at > authorityEnd) return decodeCloudUrl(url);
    return decodeCloudUrl('${url.substring(0, schemeEnd + 3)}***@${url.substring(at + 1)}');
  }

  Future<File?> _sureFile() async {
    final existing = _file;
    if (existing != null) return existing;
    if (_fileUnavailable) return null;
    try {
      final root = await storageService.getExternalCacheDirectory();
      final dir = Directory('$root/logs');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File('${dir.path}/purer.log');
      _file = file;
      return file;
    } catch (_) {
      _fileUnavailable = true;
      return null;
    }
  }

  Future<void> _flushToFile() async {
    if (_pending.isEmpty) return;
    final file = await _sureFile();
    if (file == null) {
      _pending.clear();
      return;
    }
    if (file.existsSync()) {
      try {
        if ((await file.length()) > maxFileBytes) {
          // keep the in-memory buffer as the new content, so the file does not
          // silently lose the recent history that matters for a diagnosis
          await file.writeAsString(exportText(), flush: true);
          _pending.clear();
          return;
        }
      } catch (_) {
        // continue and try to append
      }
    }
    final text = _pending.toString();
    _pending.clear();
    try {
      await file.writeAsString(text, mode: FileMode.append, flush: true);
    } catch (_) {
      _fileUnavailable = true;
    }
  }

  Future<void> _truncateFile() async {
    final file = _file;
    if (file == null) return;
    try {
      if (await file.exists()) await file.writeAsString('', flush: true);
    } catch (_) {
      // ignore
    }
  }
}

final purerLog = PurerLog();
