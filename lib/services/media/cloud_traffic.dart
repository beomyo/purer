import 'package:flutter/foundation.dart';

// One remote transfer the app is running right now (or has just finished), as
// shown by the live traffic panel of the log page.
//
// Transfers are opened by the network backends themselves (WebDAV, SMB, the
// loopback video bridge) and by the video frame extraction, so the panel covers
// everything that can pull bytes from a server, including the requests that
// outlive the UI request that started them.
class CloudTransfer {
  final int id;
  // short operation token: GET, PROPFIND, PUT, READ, STREAM, 抽帧...
  final String op;
  final String url;
  final DateTime started;
  // bytes received/sent so far; 0 while the size is not known (native video
  // extraction does not report a length)
  int bytes;

  new({
    required this.id,
    required this.op,
    required this.url,
    required this.started,
    this.bytes = 0,
  });

  Duration get elapsed => DateTime.now().difference(started);
}

// Process wide registry of the remote transfers in flight.
//
// The log page listens to `revision` and renders `active`, which is what makes
// unexpected network activity visible without attaching a debugger: a transfer
// still running after its tile failed stays listed, with its elapsed time and
// the bytes it pulled, until the socket really closes.
class CloudTrafficMonitor {
  // a burst of thumbnail downloads must not grow this without bound; only the
  // transfers still running are kept, so this is a safety net
  static const int _maxActive = 64;

  final ValueNotifier<int> revision = ValueNotifier(0);
  final Map<int, CloudTransfer> _active = {};
  int _nextId = 1;
  // bytes moved by every transfer started since the app came up
  int _sessionBytes = 0;
  // short window used for the throughput display
  DateTime _windowStart = DateTime.now();
  int _windowBytes = 0;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  List<CloudTransfer> get active => _active.values.toList();

  int get activeCount => _active.length;

  int get sessionBytes => _sessionBytes;

  // bytes per second over the last window, or 0 when nothing moved recently
  double get bytesPerSecond {
    final now = DateTime.now();
    final elapsed = now.difference(_windowStart);
    if (elapsed < const Duration(milliseconds: 500)) return 0;
    return _windowBytes / (elapsed.inMilliseconds / 1000);
  }

  int begin(String op, String url) {
    final id = _nextId++;
    _active[id] = CloudTransfer(id: id, op: op, url: url, started: DateTime.now());
    if (_active.length > _maxActive) {
      // drop the oldest finished-looking entry (there should be none, but a
      // backend that forgot to finish a transfer must not accumulate here)
      _active.remove(_active.keys.first);
    }
    _notify(force: true);
    return id;
  }

  void addBytes(int id, int count) {
    if (count <= 0) return;
    final transfer = _active[id];
    if (transfer == null) {
      // the transfer already finished: still count the bytes, so the session
      // total stays right
      _sessionBytes += count;
      _windowBytes += count;
      return;
    }
    transfer.bytes += count;
    _sessionBytes += count;
    final now = DateTime.now();
    if (now.difference(_windowStart) >= const Duration(seconds: 1)) {
      _windowStart = now;
      _windowBytes = 0;
    }
    _windowBytes += count;
    _notify();
  }

  // closes a transfer, optionally recording a size known only at the end
  void finish(int id, {int? totalBytes}) {
    if (totalBytes != null) addBytes(id, totalBytes);
    _active.remove(id);
    _notify(force: true);
  }

  // drops the entries that have been running for absurdly long (a native
  // request the app cannot cancel): the panel should not claim forever that a
  // transfer is active long after its future was abandoned
  void forgetStale({Duration olderThan = const Duration(minutes: 30)}) {
    final now = DateTime.now();
    final before = _active.length;
    _active.removeWhere((_, transfer) => now.difference(transfer.started) > olderThan);
    if (_active.length != before) _notify(force: true);
  }

  // updates are throttled: a download reports every chunk, and rebuilding the
  // log page for each of them would cost more than the transfer itself
  void _notify({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastNotify) < const Duration(milliseconds: 250)) return;
    _lastNotify = now;
    revision.value++;
  }
}

final cloudTraffic = CloudTrafficMonitor();
