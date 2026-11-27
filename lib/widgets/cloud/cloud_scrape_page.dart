import 'dart:async';

import 'package:purer/model/settings/settings.dart';
import 'package:purer/model/source/cloud/cloud_server.dart';
import 'package:purer/services/media/cloud_thumbnail_scraper.dart';
import 'package:purer/theme/format.dart';
import 'package:purer/widgets/cloud/cloud_folder_display.dart';
import 'package:purer/widgets/cloud/cloud_folder_picker.dart';
import 'package:purer/widgets/common/basic/scaffold.dart';
import 'package:purer/widgets/common/extensions/build_context.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

// Detailed view of a background thumbnail scrape: what is being scanned or
// extracted right now, how far along the run is, and why individual videos
// failed. The settings page only links here, so it stays a compact entry.
class CloudScrapePage extends StatefulWidget {
  static const routeName = '/settings/scrape';

  const new({super.key});

  @override
  State<CloudScrapePage> createState() => _CloudScrapePageState();
}

enum _ItemFilter { all, failed, skipped, generated, cached, pending }

class _CloudScrapePageState extends State<CloudScrapePage> {
  _ItemFilter _filter = _ItemFilter.all;

  // filtering the whole result list on every progress publish (several per
  // video, up to 20k items) was wasted work: the outcome only changes when the
  // counters do
  List<CloudScrapeItem>? _filteredCache;
  List<CloudScrapeItem>? _filteredSource;
  _ItemFilter? _filteredFilter;
  int _filteredSignature = 0;

  @override
  Widget build(BuildContext context) {
    return PurerScaffold(
      appBar: AppBar(
        title: Text(context.l10n.cloudScrapeTitle),
        actions: [
          IconButton(
            tooltip: context.l10n.cloudScrapeSelectFolder,
            icon: const Icon(Icons.folder_open),
            onPressed: cloudThumbnailScraper.isRunning ? null : () => _pickFolder(context),
          ),
        ],
      ),
      body: ValueListenableBuilder<CloudScrapeProgress>(
        valueListenable: cloudThumbnailScraper.progress,
        builder: (context, progress, child) {
          final items = _filteredItems(progress);
          final showEmpty = items.isEmpty && progress.items.isNotEmpty;
          final headerCount = 2 + (showEmpty ? 1 : 0);
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: headerCount + items.length,
            itemBuilder: (context, index) {
              if (index == 0) return _buildStatusCard(context, progress);
              if (index == 1) return _buildFilterBar(context, progress);
              if (showEmpty && index == 2) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(child: Text(context.l10n.cloudScrapeEmptyItems, style: Theme.of(context).textTheme.bodyMedium)),
                );
              }
              return _buildItem(context, items[index - headerCount]);
            },
          );
        },
      ),
    );
  }

  List<CloudScrapeItem> _filteredItems(CloudScrapeProgress progress) {
    final signature = progress.processed * 1000003 +
        progress.generated * 10007 +
        progress.cached * 1009 +
        progress.failed * 101 +
        progress.skipped * 17 +
        progress.items.length;
    final cached = _filteredCache;
    if (cached != null && identical(_filteredSource, progress.items) && _filteredFilter == _filter && _filteredSignature == signature) {
      return cached;
    }
    final result = _computeFilteredItems(progress);
    _filteredCache = result;
    _filteredSource = progress.items;
    _filteredFilter = _filter;
    _filteredSignature = signature;
    return result;
  }

  List<CloudScrapeItem> _computeFilteredItems(CloudScrapeProgress progress) {
    return switch (_filter) {
      _ItemFilter.all => progress.items.where((i) => i.state != CloudScrapeItemState.pending).toList(),
      _ItemFilter.failed => progress.items.where((i) => i.state == CloudScrapeItemState.failed).toList(),
      _ItemFilter.skipped => progress.items.where((i) => i.state == CloudScrapeItemState.skipped).toList(),
      _ItemFilter.generated => progress.items.where((i) => i.state == CloudScrapeItemState.generated).toList(),
      _ItemFilter.cached => progress.items.where((i) => i.state == CloudScrapeItemState.cached).toList(),
      _ItemFilter.pending => progress.items.where((i) => i.state == CloudScrapeItemState.pending || i.state == CloudScrapeItemState.running).toList(),
    };
  }

  Widget _buildStatusCard(BuildContext context, CloudScrapeProgress progress) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final target = settings.cloudScrapeFolderUrl;
    final running = progress.running;

    final headline = switch (progress.phase) {
      CloudScrapePhase.scanning => l10n.cloudScrapePhaseScanning,
      CloudScrapePhase.scraping => progress.retrying ? l10n.cloudScrapeRetrying : l10n.cloudScrapePhaseScraping,
      CloudScrapePhase.finished => progress.stopped ? l10n.cloudScrapeStopped : l10n.cloudScrapeCompleted,
      CloudScrapePhase.idle => l10n.cloudScrapeIdle,
    };

    final details = <String>[
      // the total is only known when retrying a fixed failure list; a full run
      // works through folders as it lists them
      if (progress.totalKnown && progress.discovered > 0)
        l10n.cloudScrapeProgressStatus(progress.processed, progress.discovered)
      else if (progress.discovered > 0 || progress.processed > 0)
        l10n.cloudScrapeDiscoveredStatus(progress.processed, progress.discovered),
      if (running) l10n.cloudScrapeFoldersStatus(progress.foldersScanned, progress.foldersDone),
      if (progress.processed > 0) l10n.cloudScrapeResultCounts(progress.generated, progress.cached, progress.failed),
      if (progress.skipped > 0) l10n.cloudScrapeSkippedStatus(progress.skipped),
      if (progress.foldersFailed > 0) l10n.cloudScrapeFoldersFailed(progress.foldersFailed),
      if (progress.elapsed != null) l10n.cloudScrapeElapsed(formatFriendlyDuration(progress.elapsed!)),
      if (progress.itemsTruncated) l10n.cloudScrapeItemsTruncated(progress.items.length),
    ];

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (running)
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  Icon(
                    progress.stopped
                        ? Icons.pause_circle_outline
                        : progress.failed > 0
                        ? Icons.warning_amber
                        : Icons.task_alt,
                    color: progress.stopped
                        ? theme.colorScheme.primary
                        : progress.failed > 0
                        ? Colors.orange
                        : theme.colorScheme.primary,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    headline,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (running)
                  TextButton(
                    onPressed: cloudThumbnailScraper.cancel,
                    child: Text(l10n.cloudScrapeStop),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // only a running or finished run has progress to show: an idle
            // page used to keep an indeterminate bar animating forever
            if (progress.running || progress.finished) ...[
              LinearProgressIndicator(value: progress.fraction),
              const SizedBox(height: 10),
            ],
            for (final detail in details)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(detail, style: secondaryStyle),
              ),
            if (progress.currentFolder.isNotEmpty && running)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.cloudScrapeCurrentFolder(cloudFolderDisplay(progress.currentFolder)),
                  style: secondaryStyle,
                ),
              ),
            if (progress.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(progress.error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            if (!running && target != null && target.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.cloudScrapeLastTarget(cloudFolderDisplay(target)),
                  style: secondaryStyle,
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (!running && progress.canResume)
                  FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: Text(l10n.cloudScrapeResume),
                    onPressed: () => unawaited(cloudThumbnailScraper.resume()),
                  ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.folder_open),
                  label: Text(progress.discovered > 0 || progress.finished ? l10n.cloudScrapeRestart : l10n.cloudScrapeSelectFolder),
                  onPressed: running ? null : () => _pickFolder(context),
                ),
                if (!running && progress.failed > 0)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.replay),
                    label: Text(l10n.cloudScrapeRetryFailed),
                    onPressed: () => unawaited(cloudThumbnailScraper.retryFailed()),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterBar(BuildContext context, CloudScrapeProgress progress) {
    final l10n = context.l10n;
    final chips = <(_ItemFilter, String, int)>[
      (_ItemFilter.all, l10n.cloudScrapeFilterAll, progress.processed),
      (_ItemFilter.failed, l10n.cloudScrapeFilterFailed, progress.failed),
      (_ItemFilter.skipped, l10n.cloudScrapeFilterSkipped, progress.skipped),
      (_ItemFilter.generated, l10n.cloudScrapeFilterGenerated, progress.generated),
      (_ItemFilter.cached, l10n.cloudScrapeFilterCached, progress.cached),
      (_ItemFilter.pending, l10n.cloudScrapeFilterPending, progress.pending),
    ];
    if (progress.items.isEmpty) {
      // nothing ran yet: show the short explanation instead of filters
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(context.l10n.cloudScrapeDescription, style: Theme.of(context).textTheme.bodySmall),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          for (final (value, label, count) in chips)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: ChoiceChip(
                label: Text('$label $count'),
                selected: _filter == value,
                onSelected: (selected) {
                  if (!selected) return;
                  setState(() => _filter = value);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, CloudScrapeItem item) {
    final theme = Theme.of(context);
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final (icon, color) = switch (item.state) {
      CloudScrapeItemState.pending => (Icons.schedule, theme.colorScheme.onSurfaceVariant),
      CloudScrapeItemState.running => (Icons.autorenew, theme.colorScheme.primary),
      CloudScrapeItemState.generated => (Icons.check_circle, Colors.green),
      CloudScrapeItemState.cached => (Icons.cloud_done, Colors.teal),
      CloudScrapeItemState.failed => (Icons.error, theme.colorScheme.error),
      CloudScrapeItemState.skipped => (Icons.skip_next, Colors.orange),
    };
    final extra = <String>[
      item.state.label,
      if (item.reason != null) context.l10n.cloudScrapeReason(item.reason!),
      if (item.attempts > 1) context.l10n.cloudScrapeAttempts(item.attempts),
      if (item.percent != null) context.l10n.cloudScrapePercent(item.percent!.toStringAsFixed(0)),
      if (item.durationMillis != null && item.durationMillis! > 0) context.l10n.cloudScrapeDurationLine(formatFriendlyDuration(Duration(milliseconds: item.durationMillis!))),
    ];
    // a failed or recorded-failure video can be tried again on its own,
    // without rerunning the whole folder
    final retryable = item.state == CloudScrapeItemState.failed || item.state == CloudScrapeItemState.skipped;
    return ListTile(
      dense: true,
      // the details can be long: no clipping, and a long press copies them
      onLongPress: () => _copyItem(context, item),
      leading: Icon(icon, color: color),
      trailing: retryable
          ? IconButton(
              tooltip: context.l10n.cloudScrapeRetryItem,
              icon: const Icon(Icons.replay),
              onPressed: cloudThumbnailScraper.isRunning ? null : () => unawaited(cloudThumbnailScraper.retryItem(item)),
            )
          : null,
      title: Text(item.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(extra.join(' · '), style: secondaryStyle),
          if (item.detail != null)
            Text(
              item.detail!,
              style: secondaryStyle?.copyWith(color: color),
            ),
          Text(
            cloudFolderDisplay(item.folderUrl),
            style: secondaryStyle,
          ),
        ],
      ),
    );
  }

  Future<void> _copyItem(BuildContext context, CloudScrapeItem item) async {
    final lines = <String>[
      item.name,
      item.state.label,
      if (item.reason != null) context.l10n.cloudScrapeReason(item.reason!),
      if (item.attempts > 1) context.l10n.cloudScrapeAttempts(item.attempts),
      if (item.percent != null) context.l10n.cloudScrapePercent(item.percent!.toStringAsFixed(0)),
      if (item.durationMillis != null && item.durationMillis! > 0) context.l10n.cloudScrapeDurationLine(formatFriendlyDuration(Duration(milliseconds: item.durationMillis!))),
      if (item.detail != null) item.detail!,
      cloudFolderDisplay(item.folderUrl),
      item.url,
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.cloudScrapeCopied)));
  }

  Future<void> _pickFolder(BuildContext context) async {
    final picked = await Navigator.push<(CloudServer, String)>(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: CloudFolderPickerPage.routeName),
        builder: (context) => CloudFolderPickerPage(
          title: context.l10n.cloudScrapePickFolder,
        ),
      ),
    );
    if (picked == null) return;
    final (_, folder) = picked;
    if (folder.isEmpty || cloudThumbnailScraper.isRunning) return;
    settings.cloudScrapeFolderUrl = folder;
    unawaited(cloudThumbnailScraper.start(folder));
  }
}
