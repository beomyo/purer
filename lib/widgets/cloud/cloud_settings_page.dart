import 'dart:async';
import 'dart:math' as math;

import 'package:purer/model/settings/modules/cloud.dart';
import 'package:purer/model/settings/settings.dart';
import 'package:purer/model/source/cloud/cloud_server.dart';
import 'package:purer/services/log/purer_log.dart';
import 'package:purer/services/media/cloud_disk_cache.dart';
import 'package:purer/services/media/cloud_fetch_service.dart';
import 'package:purer/services/media/cloud_media_cache.dart';
import 'package:purer/services/media/cloud_thumbnail_scraper.dart';
import 'package:purer/theme/icons.dart';
import 'package:purer/utils/file_utils.dart';
import 'package:purer/widgets/cloud/cloud_folder_display.dart';
import 'package:purer/widgets/cloud/cloud_folder_picker.dart';
import 'package:purer/widgets/cloud/cloud_log_page.dart';
import 'package:purer/widgets/cloud/cloud_scrape_page.dart';
import 'package:purer/widgets/common/basic/scaffold.dart';
import 'package:purer/widgets/common/extensions/build_context.dart';
import 'package:purer_model/purer_model.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

class CloudSettingsPage extends StatelessWidget {
  static const routeName = '/settings';

  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final l10n = context.l10n;
    final themeBrightnessLabel = switch (settings.themeBrightness) {
      PurerThemeBrightness.system => l10n.settingsSystemDefault,
      PurerThemeBrightness.light => l10n.themeBrightnessLight,
      PurerThemeBrightness.dark => l10n.themeBrightnessDark,
      PurerThemeBrightness.black => l10n.themeBrightnessBlack,
    };
    final resumptionLabel = switch (settings.videoResumptionMode) {
      VideoResumptionMode.never => l10n.videoResumptionModeNever,
      VideoResumptionMode.ask => l10n.settingsAskEverytime,
      VideoResumptionMode.always => l10n.videoResumptionModeAlways,
    };

    return PurerScaffold(
      appBar: AppBar(
        title: Text(l10n.settingsPageTitle),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // tablets: a full width list stretches every control across the whole
          // screen; the settings keep a readable column, centred instead
          final side = math.max(0.0, (constraints.maxWidth - 720) / 2);
          return ListView(
            padding: EdgeInsets.fromLTRB(side, 0, side, 24),
            children: [
              _SectionHeader(text: l10n.settingsThemeBrightnessTile),
              ListTile(
                leading: const Icon(Icons.brightness_6_outlined),
                title: Text(l10n.settingsThemeBrightnessTile),
                subtitle: Text(themeBrightnessLabel),
                onTap: () => _pickThemeBrightness(context),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.palette_outlined),
                title: Text(l10n.settingsThemeEnableDynamicColor),
                value: settings.enableDynamicColor,
                onChanged: (value) => settings.enableDynamicColor = value,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.fullscreen),
                title: Text(l10n.settingsFullScreen),
                subtitle: Text(l10n.settingsFullScreenDescription),
                value: settings.hideSystemStatusBar,
                onChanged: (value) => settings.hideSystemStatusBar = value,
              ),
              const Divider(),
              _SectionHeader(text: l10n.settingsVideoResumptionModeDialogTitle),
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: Text(l10n.settingsVideoResumptionModeTile),
                subtitle: Text(resumptionLabel),
                onTap: () => _pickResumptionMode(context),
              ),
              ListTile(
                leading: const Icon(Icons.speed),
                title: Text(l10n.settingsVideoLongPressSpeed),
                subtitle: Text('${settings.videoLongPressSpeed}x'),
                onTap: () => _pickLongPressSpeed(context),
              ),
              const Divider(),
              // thumbnails and scraping belong together: the cache is what makes a
              // later scrape skip a video, and both live on the same settings page
              _SectionHeader(text: l10n.cloudThumbnailCacheAndScrapeSection),
              // browsing without thumbnails downloads nothing until a file is
              // opened: the option that a metered connection or a huge folder needs
              SwitchListTile(
                secondary: const Icon(Icons.image_outlined),
                title: Text(l10n.cloudShowThumbnails),
                subtitle: Text(l10n.cloudShowThumbnailsDescription),
                value: settings.cloudShowThumbnails,
                onChanged: (value) => settings.cloudShowThumbnails = value,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.movie_outlined),
                title: Text(l10n.cloudShowVideoThumbnails),
                subtitle: Text(l10n.cloudShowVideoThumbnailsDescription),
                value: settings.cloudVideoThumbnails,
                onChanged: (value) => settings.cloudVideoThumbnails = value,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.cloud_upload_outlined),
                title: Text(l10n.cloudThumbnailCacheEnable),
                subtitle: Text(l10n.cloudThumbnailCacheEnableDescription),
                value: settings.cloudThumbnailCacheEnabled,
                onChanged: (value) async {
                  if (!value) {
                    settings.cloudThumbnailCacheEnabled = false;
                    return;
                  }
                  if (settings.cloudThumbnailCacheConfigured) {
                    settings.cloudThumbnailCacheEnabled = true;
                    return;
                  }
                  // enabling for the first time: choose the destination folder,
                  // and stay disabled if the picker is dismissed
                  await Future<void>.delayed(const Duration(milliseconds: 100));
                  if (context.mounted) await _pickCacheFolder(context);
                },
              ),
              if (settings.cloudThumbnailCacheEnabled)
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(l10n.cloudThumbnailCacheFolder),
                  subtitle: Text(_cacheFolderText(context)),
                  onTap: () => _pickCacheFolder(context),
                ),
              ValueListenableBuilder<CloudScrapeProgress>(
                valueListenable: cloudThumbnailScraper.progress,
                builder: (context, progress, child) {
                  final running = progress.running;
                  final secondaryStyle = Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
                  return ListTile(
                    leading: running
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(progress.failed > 0 ? Icons.warning_amber : Icons.auto_awesome_motion_outlined),
                    title: Text(l10n.cloudScrapeTitle),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 2),
                        Text(_scrapeSummary(context, progress), style: secondaryStyle),
                        if (running && progress.fraction != null) ...[
                          const SizedBox(height: 6),
                          LinearProgressIndicator(value: progress.fraction),
                        ],
                      ],
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        settings: const RouteSettings(name: CloudScrapePage.routeName),
                        builder: (context) => const CloudScrapePage(),
                      ),
                    ),
                  );
                },
              ),
              const Divider(),
              // local cache settings: the decode budget, the disk budget (shared by
              // originals, video frames, sprite sheets and thumbnail copies)
              _SectionHeader(text: l10n.cloudLocalCacheSection),
              ListTile(
                leading: const Icon(Icons.memory_outlined),
                title: Text(l10n.cloudDecodeMemoryLimit),
                subtitle: Text(l10n.cloudDecodeMemoryLimitDescription),
                trailing: Text(_decodeMemoryLabel(context, settings.cloudDecodeMemoryLimitMb)),
                onTap: () => _pickDecodeMemoryLimit(context),
              ),
              ListTile(
                leading: const Icon(Icons.sd_storage_outlined),
                title: Text(l10n.cloudDiskCacheSize),
                subtitle: Text(l10n.cloudDiskCacheSizeDescription),
                trailing: Text(_sizeLabel(context, settings.cloudDiskCacheSizeMb)),
                onTap: () => _pickDiskCacheSize(context),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.photo_size_select_large_outlined),
                title: Text(l10n.cloudThumbnailDiskCache),
                subtitle: Text(l10n.cloudThumbnailDiskCacheDescription),
                value: settings.cloudThumbnailDiskCacheEnabled,
                onChanged: (value) => settings.cloudThumbnailDiskCacheEnabled = value,
              ),
              const _CacheUsageTile(),
              const Divider(),
              ListTile(
                leading: const Icon(AIcons.delete),
                title: Text(l10n.cloudClearProgress),
                onTap: () => _clearProgress(context),
              ),
              const Divider(),
              _SectionHeader(text: l10n.cloudDiagnosticsSection),
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text(l10n.cloudLogTitle),
                subtitle: Text(l10n.cloudLogEntrySubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    settings: const RouteSettings(name: CloudLogPage.routeName),
                    builder: (context) => const CloudLogPage(),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // one line for the settings entry: what the last run ended up as, or what is
  // running now (the detailed view is on its own page)
  String _scrapeSummary(BuildContext context, CloudScrapeProgress progress) {
    final l10n = context.l10n;
    if (progress.running) {
      if (progress.processed <= 0) return l10n.cloudScrapeEntrySubtitle;
      return l10n.cloudScrapeRunningSummary(progress.processed, progress.failed);
    }
    if (progress.finished) {
      return l10n.cloudScrapeResultCounts(progress.generated, progress.cached, progress.failed);
    }
    return l10n.cloudScrapeEntrySubtitle;
  }

  String _cacheFolderText(BuildContext context) {
    final server = settings.cloudThumbnailCacheServer;
    final folder = settings.cloudThumbnailCacheFolderUrl;
    if (server == null || folder == null || folder.isEmpty) return context.l10n.cloudThumbnailCacheFolderUnset;
    return cloudFolderDisplay(folder, showRootSlash: false);
  }

  Future<(CloudServer, String)?> _pickFolder(BuildContext context, {required String title, String? initialServerId, String? initialFolder}) {
    return Navigator.push<(CloudServer, String)>(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: CloudFolderPickerPage.routeName),
        builder: (context) => CloudFolderPickerPage(
          title: title,
          initialServerId: initialServerId,
          initialFolder: initialFolder,
        ),
      ),
    );
  }

  Future<void> _pickCacheFolder(BuildContext context) async {
    final picked = await _pickFolder(
      context,
      title: context.l10n.cloudThumbnailCachePickFolder,
      initialServerId: settings.cloudThumbnailCacheServerId,
      initialFolder: settings.cloudThumbnailCacheFolderUrl,
    );
    if (picked == null) return;
    final (server, folder) = picked;
    settings.cloudThumbnailCacheServerId = server.id;
    settings.cloudThumbnailCacheFolderUrl = folder;
    settings.cloudThumbnailCacheEnabled = true;
    // the layout memoizes folder setup: a new destination must be created again
    cloudMediaCache.reset();
    purerLog.info(PurerLogCategory.cache, '设置共用缓存文件夹 ${PurerLog.redactUrl(folder)}');
  }

  Future<void> _pickThemeBrightness(BuildContext context) async {
    final selected = await _showRadioDialog<PurerThemeBrightness>(
      context,
      title: context.l10n.settingsThemeBrightnessDialogTitle,
      values: PurerThemeBrightness.values,
      current: settings.themeBrightness,
      label: (value) => switch (value) {
        PurerThemeBrightness.system => context.l10n.settingsSystemDefault,
        PurerThemeBrightness.light => context.l10n.themeBrightnessLight,
        PurerThemeBrightness.dark => context.l10n.themeBrightnessDark,
        PurerThemeBrightness.black => context.l10n.themeBrightnessBlack,
      },
    );
    if (selected != null) settings.themeBrightness = selected;
  }

  Future<void> _pickResumptionMode(BuildContext context) async {
    final selected = await _showRadioDialog<VideoResumptionMode>(
      context,
      title: context.l10n.settingsVideoResumptionModeDialogTitle,
      values: VideoResumptionMode.values,
      current: settings.videoResumptionMode,
      label: (value) => switch (value) {
        VideoResumptionMode.never => context.l10n.videoResumptionModeNever,
        VideoResumptionMode.ask => context.l10n.settingsAskEverytime,
        VideoResumptionMode.always => context.l10n.videoResumptionModeAlways,
      },
    );
    if (selected != null) settings.videoResumptionMode = selected;
  }

  Future<void> _pickLongPressSpeed(BuildContext context) async {
    const speeds = [1.5, 2.0, 3.0, 5.0, 8.0];
    final selected = await _showRadioDialog<double>(
      context,
      title: context.l10n.settingsVideoLongPressSpeed,
      values: speeds,
      current: settings.videoLongPressSpeed,
      label: (value) => '${value}x',
    );
    if (selected != null) settings.videoLongPressSpeed = selected;
  }

  // `0` is the 'no budget' choice, which the label spells out instead of
  // showing a meaningless "0 MB"
  static String _decodeMemoryLabel(BuildContext context, int mb) => mb <= 0 ? context.l10n.cloudDecodeMemoryUnlimited : '$mb MB';

  Future<void> _pickDecodeMemoryLimit(BuildContext context) async {
    final l10n = context.l10n;
    final selected = await _showRadioDialog<int>(
      context,
      title: l10n.cloudDecodeMemoryLimit,
      values: CloudSettings.cloudDecodeMemoryLimitsMb,
      current: settings.cloudDecodeMemoryLimitMb,
      label: (value) => _decodeMemoryLabel(context, value),
    );
    if (selected == null) return;
    settings.cloudDecodeMemoryLimitMb = selected;
    // apply at once, so the new budget is not waiting for the next thumbnail
    applyCloudDecodeBudget();
  }

  static String _sizeLabel(BuildContext context, int mb) => mb <= 0 ? context.l10n.cloudDiskCacheUnlimited : '$mb MB';

  Future<void> _pickDiskCacheSize(BuildContext context) async {
    final selected = await _showRadioDialog<int>(
      context,
      title: context.l10n.cloudDiskCacheSize,
      values: CloudSettings.cloudDiskCacheSizesMb,
      current: settings.cloudDiskCacheSizeMb,
      label: (value) => _sizeLabel(context, value),
    );
    if (selected == null) return;
    settings.cloudDiskCacheSizeMb = selected;
    // a lowered budget is applied right away instead of on the next write
    unawaited(cloudDiskCache.trim());
  }

  Future<void> _clearProgress(BuildContext context) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.cloudClearProgress),
        content: Text(l10n.cloudClearProgressConfirmation),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.webdavActionCancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.cloudClearProgress)),
        ],
      ),
    );
    if (confirmed ?? false) settings.clearCloudFolderProgress();
  }

  Future<T?> _showRadioDialog<T>(
    BuildContext context, {
    required String title,
    required List<T> values,
    required T current,
    required String Function(T value) label,
  }) {
    return showDialog<T>(
      context: context,
      builder: (context) => RadioGroup<T>(
        groupValue: current,
        onChanged: (selected) => Navigator.pop(context, selected),
        child: AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: double.maxFinite,
            // the language list is long, so it must scroll within the dialog
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .7),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final value in values)
                    RadioListTile<T>(
                      value: value,
                      title: Text(label(value)),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.webdavActionCancel),
            ),
          ],
        ),
      ),
    );
  }
}

// The size of the local cache, refreshed after clearing, so the user knows what
// the clear action removes before confirming it.
class _CacheUsageTile extends StatefulWidget {
  const new();

  @override
  State<_CacheUsageTile> createState() => _CacheUsageTileState();
}

class _CacheUsageTileState extends State<_CacheUsageTile> {
  int? _bytes;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final bytes = await cloudDiskCache.usageBytes();
    if (mounted) setState(() => _bytes = bytes);
  }

  Future<void> _clear(BuildContext context) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.aboutDataUsageClearCache),
        content: Text(l10n.cloudClearCacheConfirmation),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.webdavActionCancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.aboutDataUsageClearCache)),
        ],
      ),
    );
    if (confirmed != true) return;
    purerLog.info(PurerLogCategory.cache, '清理本地缓存');
    await cloudDiskCache.clear();
    resetCloudThumbnailCaches();
    imageCache.clear();
    imageCache.clearLiveImages();
    await _refresh();
    messenger.showSnackBar(SnackBar(content: Text(l10n.aboutDataUsageClearCache)));
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return ListTile(
      leading: const Icon(Icons.cleaning_services_outlined),
      title: Text(context.l10n.aboutDataUsageClearCache),
      subtitle: Text(
        context.l10n.cloudDiskCacheUsage(bytes == null ? '…' : formatFileSize(settings.purerLocale, bytes, round: 0)),
      ),
      onTap: () => _clear(context),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;

  const new({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
