import 'dart:async';
import 'dart:convert';

import 'package:purer/model/device.dart';
import 'package:purer/model/settings/settings.dart';
import 'package:purer/ref/mime_types.dart';
import 'package:purer/services/common/services.dart';
import 'package:purer/services/log/purer_log.dart';
import 'package:purer/services/media/cloud_traffic.dart';
import 'package:purer/utils/file_utils.dart';
import 'package:purer/widgets/common/basic/scaffold.dart';
import 'package:purer/widgets/common/extensions/build_context.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

// The operation log: every network request, thumbnail extraction, scrape step
// and cache operation, colored by severity and filterable by level and
// category, so a problem can be traced without a debugger attached.
class CloudLogPage extends StatefulWidget {
  static const routeName = '/settings/log';

  const new({super.key});

  @override
  State<CloudLogPage> createState() => _CloudLogPageState();
}

class _CloudLogPageState extends State<CloudLogPage> {
  PurerLogLevel? _level;
  PurerLogCategory? _category;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    purerLog.revision.addListener(_onLogChanged);
  }

  @override
  void dispose() {
    purerLog.revision.removeListener(_onLogChanged);
    _refreshTimer?.cancel();
    super.dispose();
  }

  // a scrape/thumbnail storm logs many records per second: rebuild a few times
  // per second instead of once per record (and re-filter the whole list each time)
  void _onLogChanged() {
    if (_refreshTimer != null) return;
    _refreshTimer = Timer(const Duration(milliseconds: 400), () {
      _refreshTimer = null;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PurerScaffold(
      appBar: AppBar(
        title: Text(l10n.cloudLogTitle),
        actions: [
          IconButton(
            tooltip: l10n.cloudLogSave,
            icon: const Icon(Icons.save_alt_outlined),
            onPressed: () => _save(context),
          ),
          IconButton(
            tooltip: l10n.cloudLogCopy,
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () => _copy(context),
          ),
          IconButton(
            tooltip: l10n.cloudLogClear,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => _clear(context),
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          final records = _filtered();
          return Column(
            children: [
              const _TrafficPanel(),
              const Divider(height: 1),
              _buildHeader(context),
              const Divider(height: 1),
              Expanded(
                child: records.isEmpty
                    ? Center(child: Text(l10n.cloudLogEmpty))
                    : ListView.builder(
                        // newest first: the interesting records are the ones
                        // that just happened
                        reverse: true,
                        itemCount: records.length,
                        itemBuilder: (context, index) => _buildRecord(context, records[records.length - 1 - index]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<PurerLogRecord> _filtered() {
    final level = _level;
    final category = _category;
    // a copy: the live list is appended to while the page is open
    if (level == null && category == null) return List.of(purerLog.records);
    return [
      for (final record in purerLog.records)
        if ((level == null || record.level == level) && (category == null || record.category == category)) record,
    ];
  }

  Widget _buildHeader(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.receipt_long_outlined),
          title: Text(l10n.cloudLogEnable),
          subtitle: Text(l10n.cloudLogEnableDescription),
          value: settings.cloudLogEnabled,
          onChanged: (value) => setState(() => settings.cloudLogEnabled = value),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Row(
            children: [
              _chip(context, label: l10n.cloudScrapeFilterAll, selected: _level == null, onSelected: () => setState(() => _level = null)),
              for (final level in PurerLogLevel.values)
                _chip(
                  context,
                  label: level.label,
                  selected: _level == level,
                  color: _levelColor(context, level),
                  onSelected: () => setState(() => _level = _level == level ? null : level),
                ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(
            children: [
              _chip(context, label: l10n.cloudLogCategoryAll, selected: _category == null, onSelected: () => setState(() => _category = null)),
              for (final category in PurerLogCategory.values)
                _chip(
                  context,
                  label: category.label,
                  selected: _category == category,
                  onSelected: () => setState(() => _category = _category == category ? null : category),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text(
            l10n.cloudLogCount(purerLog.records.length),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _chip(BuildContext context, {required String label, required bool selected, Color? color, required VoidCallback onSelected}) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: FilterChip(
        label: Text(label, style: color == null ? null : TextStyle(color: color)),
        selected: selected,
        onSelected: (_) => onSelected(),
      ),
    );
  }

  Widget _buildRecord(BuildContext context, PurerLogRecord record) {
    final theme = Theme.of(context);
    final color = _levelColor(context, record.level);
    return InkWell(
      // a log line can be much wider than the screen; swiping it sideways
      // shows the rest, and a long press copies the whole line
      onLongPress: () => _copyRecord(context, record),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 78,
              child: Text(
                record.timeText,
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: Text(
                record.level.key.padRight(5),
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: color, fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: Text(
                record.category.label,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  record.message,
                  softWrap: false,
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _levelColor(BuildContext context, PurerLogLevel level) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return switch (level) {
      PurerLogLevel.debug => scheme.onSurfaceVariant,
      PurerLogLevel.info => scheme.primary,
      PurerLogLevel.success => isDark ? Colors.green.shade300 : Colors.green.shade700,
      PurerLogLevel.warn => isDark ? Colors.orange.shade300 : Colors.orange.shade800,
      PurerLogLevel.error => scheme.error,
    };
  }

  // Saves the complete log (disk history + this session) through the system
  // file picker. `createFile` adds the extension from the MIME type.
  Future<void> _save(BuildContext context) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final text = await purerLog.exportCompleteText(header: _diagnosticsHeader());
    final basename = 'purer-log-${_timestampForFileName(DateTime.now())}';
    final result = await storageService.createFile(
      basename: basename,
      mimeType: MimeTypes.plainText,
      bytes: Uint8List.fromList(utf8.encode(text)),
    );
    if (result == null) return; // the user cancelled the picker
    messenger?.showSnackBar(
      SnackBar(content: Text(result ? l10n.cloudLogSaved : l10n.genericFailureFeedback)),
    );
  }

  static String _timestampForFileName(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}-${two(time.hour)}${two(time.minute)}${two(time.second)}';
  }

  // What the log alone cannot tell: which build produced it, and what was
  // running when it was saved (a transfer still in flight is usually the
  // reason the user is exporting the log).
  String _diagnosticsHeader() {
    final buffer = StringBuffer()
      ..writeln('===== Purer 诊断信息 =====')
      ..writeln('导出时间: ${DateTime.now()}')
      ..writeln('版本: ${device.packageVersion}')
      ..writeln('日志记录: ${settings.cloudLogEnabled ? '开启' : '关闭'}');
    final active = cloudTraffic.active;
    buffer.writeln('正在传输: ${active.length} 项');
    for (final transfer in active) {
      final bytes = transfer.bytes > 0 ? '${transfer.bytes} 字节' : '大小未知';
      buffer.writeln('  ${transfer.op} ${PurerLog.redactUrl(transfer.url)} $bytes ${transfer.elapsed.inSeconds}s');
    }
    buffer.writeln('本次会话累计传输: ${cloudTraffic.sessionBytes} 字节');
    return buffer.toString();
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: purerLog.exportText()));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.cloudLogCopied)));
  }

  Future<void> _copyRecord(BuildContext context, PurerLogRecord record) async {
    await Clipboard.setData(ClipboardData(text: record.toLine()));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.cloudLogCopied)));
  }

  Future<void> _clear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.cloudLogClear),
        content: Text(context.l10n.cloudLogClearConfirmation),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.webdavActionCancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l10n.cloudLogClear)),
        ],
      ),
    );
    if (confirmed ?? false) {
      purerLog.clear();
      setState(() {});
    }
  }
}

// Live view of the remote transfers the app is running right now.
//
// It answers "what is using the network" without waiting for a log record: a
// transfer is listed from the moment its socket opens until it really closes,
// including the ones whose UI request already failed (the platform video
// retriever cannot be cancelled from Dart, so its read can outlive the tile
// that started it). That is how an unexplained transfer gets a name.
class _TrafficPanel extends StatefulWidget {
  const new();

  @override
  State<_TrafficPanel> createState() => _TrafficPanelState();
}

class _TrafficPanelState extends State<_TrafficPanel> {
  Timer? _ticker;
  bool _expanded = true;
  // at most this many rows: the rest is summarized, so the log list below
  // stays reachable
  static const int _maxRows = 6;

  @override
  void initState() {
    super.initState();
    cloudTraffic.revision.addListener(_onTrafficChanged);
    _syncTicker();
  }

  @override
  void dispose() {
    cloudTraffic.revision.removeListener(_onTrafficChanged);
    _ticker?.cancel();
    super.dispose();
  }

  void _onTrafficChanged() {
    if (!mounted) return;
    setState(() {});
    _syncTicker();
  }

  // elapsed times and throughput keep moving even when no chunk arrives, so a
  // transfer stalled on the server is visible instead of looking finished
  void _syncTicker() {
    if (cloudTraffic.activeCount > 0) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        cloudTraffic.forgetStale();
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final locale = settings.purerLocale;
    final active = cloudTraffic.active;
    final speed = cloudTraffic.bytesPerSecond;
    final speedText = speed > 0 ? '${formatFileSize(locale, speed.round(), round: 0)}/s' : null;
    final muted = theme.colorScheme.onSurfaceVariant;
    final summary = [
      active.isEmpty ? l10n.cloudTrafficIdle : l10n.cloudTrafficActive(active.length),
      ?speedText,
      l10n.cloudTrafficSession(formatFileSize(locale, cloudTraffic.sessionBytes, round: 0)),
    ].join(' · ');
    // a short (landscape) screen must keep room for the log itself
    final maxRows = MediaQuery.sizeOf(context).height < 520 ? 2 : _maxRows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
            child: Row(
              children: [
                Icon(
                  active.isEmpty ? Icons.wifi_tethering_off_outlined : Icons.swap_vert_circle_outlined,
                  color: active.isEmpty ? muted : theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.cloudTrafficTitle, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(summary, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                    ],
                  ),
                ),
                if (active.isNotEmpty) Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: muted),
              ],
            ),
          ),
        ),
        if (_expanded)
          for (final transfer in active.take(maxRows)) _buildTransfer(context, transfer),
        if (_expanded && active.length > maxRows)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 6),
            child: Text('+${active.length - maxRows}', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ),
      ],
    );
  }

  Widget _buildTransfer(BuildContext context, CloudTransfer transfer) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final size = transfer.bytes > 0 ? formatFileSize(settings.purerLocale, transfer.bytes, round: 0) : context.l10n.cloudTrafficUnknownSize;
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(color: muted);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              transfer.op,
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSecondaryContainer, fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              PurerLog.redactUrl(transfer.url),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: secondaryStyle,
            ),
          ),
          const SizedBox(width: 8),
          Text('$size · ${transfer.elapsed.inSeconds}s', style: secondaryStyle),
        ],
      ),
    );
  }
}
