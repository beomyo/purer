import 'package:purer/model/settings/modules/cloud.dart';
import 'package:purer/model/settings/settings.dart';
import 'package:purer/services/media/cloud_fetch_service.dart';
import 'package:purer/theme/icons.dart';
import 'package:purer/widgets/cloud/cloud_options_sheet.dart';
import 'package:purer/widgets/common/extensions/build_context.dart';
import 'package:material_ui/material_ui.dart';

Future<void> showCloudViewOptions(
  BuildContext context, {
  required String url,
  required bool video,
  Future<void> Function()? onRebuildThumbnails,
  Future<void> Function()? onExportProgress,
  Future<void> Function()? onImportProgress,
  Future<void> Function()? onClearProgress,
  Future<void> Function()? onLoadSprites,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    // the sheet keeps the layout switcher on top and collapses every other
    // group, so it does not need a long scroll. On a tablet the width is
    // bounded, which also centres it instead of stretching edge to edge.
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .85,
      maxWidth: 1000,
    ),
    builder: (context) => Theme(
      // a denser sheet: compact tiles/sliders so more options fit without a
      // long scroll
      data: Theme.of(context).copyWith(
        visualDensity: VisualDensity.compact,
        listTileTheme: const ListTileThemeData(dense: true),
      ),
      child: SizedBox.expand(
        child: CloudViewOptionsSheet(
          url: url,
          video: video,
          onRebuildThumbnails: onRebuildThumbnails,
          onExportProgress: onExportProgress,
          onImportProgress: onImportProgress,
          onClearProgress: onClearProgress,
          onLoadSprites: onLoadSprites,
        ),
      ),
    ),
  );
}

// All the view related options, gathered behind the app bar "view" button.
// Reads the global `settings` directly (no `Provider` lookup) so that it also
// works when shown from a separate modal route.
//
// The layout switcher sits at the top; every other group is collapsible, so
// reaching an option never means scrolling through the whole sheet.
class CloudViewOptionsSheet extends StatelessWidget {
  static const List<String> layoutValues = ['mosaic', 'grid', 'list'];
  static const List<String> mediaValues = ['all', 'image', 'video'];

  final String url;
  final bool video;
  final Future<void> Function()? onRebuildThumbnails;
  final Future<void> Function()? onExportProgress;
  final Future<void> Function()? onImportProgress;
  final Future<void> Function()? onClearProgress;
  final Future<void> Function()? onLoadSprites;

  const new({
    super.key,
    required this.url,
    required this.video,
    this.onRebuildThumbnails,
    this.onExportProgress,
    this.onImportProgress,
    this.onClearProgress,
    this.onLoadSprites,
  });

  static IconData layoutIcon(String layout) => switch (layout) {
    'mosaic' => AIcons.layoutMosaic,
    'list' => AIcons.layoutList,
    _ => AIcons.layoutGrid,
  };

  static String layoutName(BuildContext context, String layout) => switch (layout) {
    'mosaic' => context.l10n.webdavLayoutMosaic,
    'list' => context.l10n.webdavLayoutList,
    _ => context.l10n.webdavLayoutGrid,
  };

  static IconData mediaIcon(String media) => switch (media) {
    'image' => Icons.image_outlined,
    'video' => Icons.videocam_outlined,
    _ => Icons.collections_outlined,
  };

  static String mediaName(BuildContext context, String media) => switch (media) {
    'image' => context.l10n.webdavMediaImages,
    'video' => context.l10n.webdavMediaVideos,
    _ => context.l10n.webdavMediaAll,
  };

  static String _qualityName(BuildContext context, String quality) => switch (quality) {
    'high' => context.l10n.cloudThumbnailQualityHigh,
    'original' => context.l10n.cloudThumbnailQualityOriginal,
    _ => context.l10n.cloudThumbnailQualityStandard,
  };

  static const List<String> sortFields = ['name', 'size', 'duration'];

  static String _sortFieldOf(String sort) {
    for (final field in sortFields) {
      if (sort.startsWith(field)) return field;
    }
    return 'name';
  }

  static String _sortValue(String field, bool descending) => '$field${descending ? 'Desc' : 'Asc'}';

  static String _sortFieldName(BuildContext context, String field) => switch (field) {
    'size' => context.l10n.cloudSortFieldSize,
    'duration' => context.l10n.cloudSortFieldDuration,
    _ => context.l10n.cloudSortFieldName,
  };

  static String sortName(BuildContext context, String sort) => switch (sort) {
    'nameDesc' => context.l10n.cloudSortNameDesc,
    'sizeAsc' => context.l10n.cloudSortSizeAsc,
    'sizeDesc' => context.l10n.cloudSortSizeDesc,
    'durationAsc' => context.l10n.cloudSortDurationAsc,
    'durationDesc' => context.l10n.cloudSortDurationDesc,
    _ => context.l10n.cloudSortNameAsc,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // the mosaic groups only make sense for that layout
    final isMosaic = settings.cloudLayoutFor(url, video: video) == 'mosaic';
    // the layout switcher stays at the top (the most used option); every other
    // group is a collapsible section, so the sheet stays short and no option
    // requires a long scroll to reach
    return ListenableBuilder(
      listenable: settings,
      builder: (context, child) => CloudOptionsSheet(
        title: l10n.webdavViewOptions,
        // the layout switcher stays above the groups and spans the full width
        header: _layoutQuickBlock(context),
        children: [
          CloudOptionSection(
            icon: Icons.visibility_outlined,
            title: l10n.cloudTabDisplay,
            summary: '${mediaName(context, settings.cloudMediaFilter)} · ${sortName(context, settings.cloudSort)}',
            children: _displaySection(context),
          ),
          CloudOptionSection(
            icon: Icons.dashboard_customize_outlined,
            title: l10n.cloudDefaultViews,
            summary: '${layoutName(context, settings.cloudImageLayout)} · ${layoutName(context, settings.cloudVideoLayout)}',
            children: _defaultViewsSection(context),
          ),
          if (isMosaic)
            CloudOptionSection(
              icon: Icons.play_circle_outline,
              title: l10n.cloudSectionAutoBrowse,
              summary: '${settings.cloudMosaicScrollDirection == 'horizontal' ? l10n.cloudDirectionHorizontal : l10n.cloudDirectionVertical} · ${cloudFormatFactor(settings.cloudMosaicAutoScrollSpeed)}',
              children: _mosaicMotionSection(context),
            ),
          if (isMosaic)
            CloudOptionSection(
              icon: Icons.zoom_in,
              title: l10n.cloudMagnifier,
              summary: settings.cloudMosaicMagnifierEnabled ? cloudFormatFactor(settings.cloudMosaicMagnifierScale) : null,
              children: _magnifierSection(context),
            ),
          CloudOptionSection(
            icon: Icons.swap_horiz,
            title: l10n.cloudSectionSwitch,
            summary: _qualityName(context, settings.cloudThumbnailQuality),
            children: _switchSection(context),
          ),
          CloudOptionSection(
            icon: Icons.movie_outlined,
            title: l10n.cloudTabVideo,
            summary: settings.cloudVideoThumbnails ? '${settings.cloudVideoThumbnailPercent.toStringAsFixed(0)}%' : null,
            children: _videoSection(context),
          ),
          CloudOptionSection(
            icon: Icons.gif_box_outlined,
            title: l10n.cloudSpriteSettingsTitle,
            summary: settings.cloudSpriteAnimationEnabled
                ? '${cloudFormatNumber(settings.cloudSpriteAnimationSpeed)} 帧/秒 · ${settings.cloudSpriteAnimationOrder == 'columnMajor' ? l10n.cloudSpriteOrderColumnMajor : l10n.cloudSpriteOrderRowMajor}'
                : null,
            children: _spriteSection(context),
          ),
          CloudOptionSection(
            icon: Icons.insights,
            title: l10n.cloudTabProgress,
            summary: l10n.cloudProgressSummary(settings.cloudProgressFolderCount, settings.cloudProgressImageCount),
            children: _progressSection(context),
          ),
        ],
      ),
    );
  }

  // layout choice and column count, kept visible above the collapsible groups
  Widget _layoutQuickBlock(BuildContext context) {
    final l10n = context.l10n;
    final currentLayout = settings.cloudLayoutFor(url, video: video);
    final columns = settings.cloudColumns;
    final layoutRow = SegmentedButton<String>(
      showSelectedIcon: false,
      segments: [
        for (final value in layoutValues)
          ButtonSegment<String>(
            value: value,
            icon: Icon(layoutIcon(value)),
            label: Text(layoutName(context, value)),
          ),
      ],
      selected: {currentLayout},
      onSelectionChanged: (selection) => settings.setCloudLayoutFor(url, selection.first, video: video),
    );
    final columnsRow = currentLayout == 'list'
        ? null
        : CloudNumberStepper(
            label: l10n.webdavColumnsTitle,
            valueLabel: '${columns.round()}',
            value: columns,
            min: CloudSettings.minCloudColumns,
            max: CloudSettings.maxCloudColumns,
            step: 1,
            onChanged: (v) => settings.cloudColumns = v.roundToDouble(),
            onTapValue: () => _showColumnDialog(context),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // in landscape the sheet is wide and short: the layout switcher and
          // the columns slider sit on one line instead of stacking vertically.
          // Needs more room than the switch columns, since both controls have
          // a minimum width of their own.
          if (constraints.maxWidth >= _splitRowBreakpoint) {
            return Row(
              children: [
                Expanded(flex: 3, child: layoutRow),
                if (columnsRow != null) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: columnsRow,
                  ),
                ],
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              layoutRow,
              if (columnsRow != null) ...[
                const SizedBox(height: 4),
                columnsRow,
              ],
            ],
          );
        },
      ),
    );
  }

  // width from which the sheet arranges short options in two columns
  static const double _wideBreakpoint = 560;
  // width from which the layout switcher and the columns slider share a row
  static const double _splitRowBreakpoint = 640;

  // Two columns on a wide (landscape/tablet) sheet, one column otherwise.
  // Switch tiles are short, so a single column left half the width empty.
  Widget _switchColumns(BuildContext context, List<Widget> children) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _wideBreakpoint) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
        }
        final width = (constraints.maxWidth - 8) / 2;
        return Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }

  // the per-media-kind defaults, collapsed by default
  List<Widget> _defaultViewsSection(BuildContext context) {
    final l10n = context.l10n;
    return [
      // the two kinds share a row on a wide sheet: they are short and always
      // looked at together
      _switchColumns(context, [
        _chipRow(context, l10n.cloudDefaultImage, settings.cloudImageLayout, (v) => settings.cloudImageLayout = v),
        _chipRow(context, l10n.cloudDefaultVideo, settings.cloudVideoLayout, (v) => settings.cloudVideoLayout = v),
      ]),
      SwitchListTile(
        title: Text(l10n.cloudLayoutPerFolder),
        value: settings.cloudLayoutPerFolder,
        onChanged: (v) => settings.cloudLayoutPerFolder = v,
      ),
    ];
  }

  // mosaic only: how the auto motion moves through the images
  List<Widget> _mosaicMotionSection(BuildContext context) {
    final l10n = context.l10n;
    final speed = settings.cloudMosaicAutoScrollSpeed;
    final interval = settings.cloudMosaicAutoPageFlipInterval;
    final distance = settings.cloudMosaicAutoPageFlipDistance;
    return [
      _sectionTitle(context, l10n.cloudScrollDirection),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            ChoiceChip(
              label: Text(l10n.cloudDirectionVertical),
              selected: settings.cloudMosaicScrollDirection == 'vertical',
              onSelected: (selected) {
                if (selected) settings.cloudMosaicScrollDirection = 'vertical';
              },
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: Text(l10n.cloudDirectionHorizontal),
              selected: settings.cloudMosaicScrollDirection == 'horizontal',
              onSelected: (selected) {
                if (selected) settings.cloudMosaicScrollDirection = 'horizontal';
              },
            ),
          ],
        ),
      ),
      CloudNumberStepper(
        label: l10n.cloudViewerAutoScrollSpeed,
        valueLabel: cloudFormatFactor(speed),
        value: speed,
        // the setting accepts next to zero, but the discrete step would land
        // on its exclusive lower bound, which reads back as the default
        min: 0.1,
        max: CloudSettings.autoScrollSpeedMax,
        step: 0.5,
        onChanged: (v) => settings.cloudMosaicAutoScrollSpeed = v,
        onTapValue: () => _showCustomSpeedDialog(context),
      ),
      CloudNumberStepper(
        label: l10n.cloudViewerAutoPageFlipInterval,
        valueLabel: cloudFormatInterval(interval),
        value: interval,
        min: CloudSettings.mosaicPageFlipIntervalMin,
        max: CloudSettings.mosaicPageFlipIntervalMax,
        step: 0.1,
        onChanged: (v) => settings.cloudMosaicAutoPageFlipInterval = v,
        onTapValue: () => _showCustomIntervalDialog(context),
      ),
      CloudNumberStepper(
        label: l10n.cloudViewerAutoPageFlipDistance,
        valueLabel: '${(distance * 100).round()}%',
        value: distance,
        min: CloudSettings.pageFlipDistanceMin,
        max: CloudSettings.pageFlipDistanceMax,
        step: 0.05,
        onChanged: (v) => settings.cloudMosaicAutoPageFlipDistance = v,
        onTapValue: () => _showCustomDistanceDialog(context),
      ),
    ];
  }

  // mosaic only: long-press magnifier
  List<Widget> _magnifierSection(BuildContext context) {
    final l10n = context.l10n;
    final delay = settings.cloudMosaicMagnifierDelay;
    final scale = settings.cloudMosaicMagnifierScale;
    return [
      SwitchListTile(
        title: Text(l10n.cloudMagnifier),
        value: settings.cloudMosaicMagnifierEnabled,
        onChanged: (v) => settings.cloudMosaicMagnifierEnabled = v,
      ),
      if (settings.cloudMosaicMagnifierEnabled) ...[
        CloudNumberStepper(
          label: l10n.cloudMagnifierDelay,
          valueLabel: '${delay}ms',
          value: delay.toDouble(),
          min: CloudSettings.magnifierDelayMin.toDouble(),
          max: CloudSettings.magnifierDelayMax.toDouble(),
          step: 50,
          onChanged: (v) => settings.cloudMosaicMagnifierDelay = v.round(),
          onTapValue: () => _showCustomMagnifierDelayDialog(context),
        ),
        CloudNumberStepper(
          label: l10n.cloudMagnifierScale,
          valueLabel: '${scale.toStringAsFixed(1)}x',
          value: scale,
          min: CloudSettings.magnifierScaleMin,
          max: CloudSettings.magnifierScaleMax,
          step: 0.2,
          onChanged: (v) => settings.cloudMosaicMagnifierScale = v,
          onTapValue: () => _showCustomMagnifierScaleDialog(context),
        ),
      ],
    ];
  }

  // list contents and the browser chrome
  List<Widget> _displaySection(BuildContext context) {
    final l10n = context.l10n;
    return [
      _sectionTitle(context, l10n.webdavMediaType),
      _chips<String>(
        values: mediaValues,
        selected: settings.cloudMediaFilter,
        label: (v) => mediaName(context, v),
        icon: mediaIcon,
        onSelected: (v) => settings.cloudMediaFilter = v,
        compact: true,
      ),
      // sorting is one row: the field (name/size/duration) plus an arrow that
      // flips ascending/descending, instead of six long chips
      _sectionTitle(context, l10n.cloudSort),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            for (final field in sortFields) ...[
              ChoiceChip(
                label: Text(_sortFieldName(context, field)),
                selected: _sortFieldOf(settings.cloudSort) == field,
                onSelected: (_) => settings.cloudSort = _sortValue(field, settings.cloudSort.endsWith('Desc')),
              ),
              const SizedBox(width: 8),
            ],
            ChoiceChip(
              avatar: Icon(settings.cloudSort.endsWith('Desc') ? Icons.arrow_downward : Icons.arrow_upward, size: 18),
              label: Text(settings.cloudSort.endsWith('Desc') ? l10n.cloudSortDescending : l10n.cloudSortAscending),
              selected: true,
              showCheckmark: false,
              onSelected: (_) {
                final field = _sortFieldOf(settings.cloudSort);
                settings.cloudSort = _sortValue(field, !settings.cloudSort.endsWith('Desc'));
              },
            ),
          ],
        ),
      ),
      const Divider(height: 8),
      _switchColumns(context, [
        SwitchListTile(
          title: Text(l10n.webdavShowFileNames),
          value: settings.cloudShowNames,
          onChanged: (v) => settings.cloudShowNames = v,
        ),
        SwitchListTile(
          title: Text(l10n.cloudShowFileSizes),
          value: settings.cloudShowSizes,
          onChanged: (v) => settings.cloudShowSizes = v,
        ),
        SwitchListTile(
          title: Text(l10n.cloudShowDimensions),
          value: settings.cloudShowDimensions,
          onChanged: (v) => settings.cloudShowDimensions = v,
        ),
        SwitchListTile(
          title: Text(l10n.webdavImmersive),
          value: settings.cloudImmersive,
          onChanged: (v) => settings.cloudImmersive = v,
        ),
      ]),
    ];
  }

  // seamless switching and decode quality (the memory budget is in the app settings)
  List<Widget> _switchSection(BuildContext context) {
    final l10n = context.l10n;
    return [
      SwitchListTile(
        title: Text(l10n.cloudSeamlessSwitch),
        subtitle: Text(l10n.cloudSeamlessSwitchDescription),
        value: settings.cloudSeamlessSwitch,
        onChanged: (v) => settings.cloudSeamlessSwitch = v,
      ),
      const Divider(height: 8),
      _sectionTitle(context, l10n.cloudThumbnailQuality),
      _chips<String>(
        values: CloudSettings.cloudThumbnailQualities,
        selected: settings.cloudThumbnailQuality,
        label: (v) => _qualityName(context, v),
        icon: (v) => v == 'original' ? Icons.hd_outlined : (v == 'high' ? Icons.high_quality_outlined : Icons.image_outlined),
        onSelected: (v) {
          if (v == settings.cloudThumbnailQuality) return;
          settings.cloudThumbnailQuality = v;
          // the providers of the images on screen were decoded at the
          // previous cap: drop them so the new quality applies at once
          final cache = PaintingBinding.instance.imageCache;
          cache.clear();
          cache.clearLiveImages();
        },
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
        child: Text(
          l10n.cloudThumbnailQualityDescription,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      // the decoded bitmap budget is a local cache setting and only exists on
      // the app settings page: editing it from here too made two places write
      // the same preference
    ];
  }

  // video thumbnails and their concurrency
  List<Widget> _videoSection(BuildContext context) {
    final l10n = context.l10n;
    final videoThumbnails = settings.cloudVideoThumbnails;
    final videoThumbnailPercent = settings.cloudVideoThumbnailPercent;
    final perFolderRate = settings.cloudThumbnailRatePerFolder;
    final folderRateOverride = settings.cloudThumbnailRateOverride(url);
    final rate = perFolderRate ? settings.cloudThumbnailRateForFolder(url) : settings.cloudThumbnailRate;
    return [
      _switchColumns(context, [
        SwitchListTile(
          title: Text(l10n.cloudShowVideoDuration),
          value: settings.cloudVideoDurationVisible,
          onChanged: (v) => settings.cloudVideoDurationVisible = v,
        ),
        SwitchListTile(
          title: Text(l10n.cloudShowVideoPlayIcon),
          value: settings.cloudVideoPlayIcon,
          onChanged: (v) => settings.cloudVideoPlayIcon = v,
        ),
      ]),
      if (videoThumbnails) ...[
        CloudNumberStepper(
          label: l10n.cloudVideoThumbnailPosition,
          valueLabel: '${videoThumbnailPercent.toStringAsFixed(0)}%',
          value: videoThumbnailPercent,
          min: CloudSettings.minVideoThumbnailPercent,
          max: CloudSettings.maxVideoThumbnailPercent,
          step: 5,
          onChanged: (v) => settings.cloudVideoThumbnailPercent = v,
          onTapValue: () => _showCustomVideoPercentDialog(context),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            l10n.cloudVideoThumbnailPositionDescription,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SwitchListTile(
          title: Text(l10n.cloudThumbnailRatePerFolder),
          value: perFolderRate,
          onChanged: (v) => settings.cloudThumbnailRatePerFolder = v,
        ),
        CloudNumberStepper(
          label: l10n.cloudThumbnailRate,
          valueLabel: '$rate/s',
          value: rate.toDouble(),
          min: CloudSettings.minThumbnailRate.toDouble(),
          max: CloudSettings.maxThumbnailRate.toDouble(),
          step: 1,
          onChanged: (v) {
            final value = v.round();
            if (perFolderRate) {
              settings.setCloudThumbnailRateForFolder(url, value);
            } else {
              settings.cloudThumbnailRate = value;
            }
          },
          onTapValue: () => _showCustomRateDialog(context, perFolderRate),
        ),
        if (perFolderRate && folderRateOverride != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => settings.clearCloudThumbnailRateForFolder(url),
                child: Text(l10n.cloudUseGlobalConcurrency),
              ),
            ),
          ),
      ],
      const Divider(height: 8),
      // always available: frames captured during playback are affected too
      ListTile(
        leading: const Icon(Icons.refresh),
        title: Text(l10n.cloudRebuildThumbnails),
        onTap: () => _runAndClose(context, onRebuildThumbnails),
      ),
    ];
  }

  // sprite sheet -> looping GIF thumbnail options
  List<Widget> _spriteSection(BuildContext context) {
    final l10n = context.l10n;
    final enabled = settings.cloudSpriteAnimationEnabled;
    final speed = settings.cloudSpriteAnimationSpeed;
    return [
      SwitchListTile(
        title: Text(l10n.cloudSpriteAnimationEnabled),
        value: enabled,
        onChanged: (v) => settings.cloudSpriteAnimationEnabled = v,
      ),
      SwitchListTile(
        title: Text(l10n.cloudSpriteOnly),
        value: settings.cloudSpriteOnly,
        onChanged: (v) => settings.cloudSpriteOnly = v,
      ),
      if (enabled) ...[
        CloudNumberStepper(
          label: l10n.cloudSpriteAnimationSpeed,
          valueLabel: '${cloudFormatNumber(speed)} 帧/秒',
          value: speed,
          min: CloudSettings.spriteAnimationSpeedMin,
          max: CloudSettings.spriteAnimationSpeedMax,
          step: 0.5,
          onChanged: (v) => settings.cloudSpriteAnimationSpeed = v,
          onTapValue: () => _showCustomSpriteSpeedDialog(context),
        ),
        SwitchListTile(
          title: Text(l10n.cloudSpriteAnimationOrder),
          subtitle: Text(settings.cloudSpriteAnimationOrder == 'columnMajor' ? l10n.cloudSpriteOrderColumnMajor : l10n.cloudSpriteOrderRowMajor),
          value: settings.cloudSpriteAnimationOrder == 'columnMajor',
          onChanged: (v) {
            settings.cloudSpriteAnimationOrder = v ? 'columnMajor' : 'rowMajor';
            // the animation is rebuilt on the new order, so drop the old one
            _invalidateSpriteAnimations();
          },
        ),
        CloudNumberStepper(
          label: l10n.cloudSpritePlaybackZone,
          valueLabel: '${settings.cloudSpritePlaybackZone}%',
          value: settings.cloudSpritePlaybackZone.toDouble(),
          min: CloudSettings.minSpritePlaybackZone.toDouble(),
          max: CloudSettings.maxSpritePlaybackZone.toDouble(),
          step: 5,
          onChanged: (v) => settings.cloudSpritePlaybackZone = v.round(),
          onTapValue: () => _showCustomSpritePlaybackZoneDialog(context),
        ),
        CloudNumberStepper(
          label: l10n.cloudSpriteStartPercent,
          valueLabel: '${settings.cloudSpriteStartPercent}%',
          value: settings.cloudSpriteStartPercent.toDouble(),
          min: CloudSettings.minSpriteStartPercent.toDouble(),
          max: CloudSettings.maxSpriteStartPercent.toDouble(),
          step: 5,
          onChanged: (v) => settings.cloudSpriteStartPercent = v.round(),
          onTapValue: () => _showCustomSpriteStartPercentDialog(context),
        ),
        // an explicit trigger for the current folder, since loading sprites is
        // normally automatic once the option is on
        ListTile(
          leading: const Icon(Icons.download_for_offline_outlined),
          title: Text(l10n.cloudSpriteLoadNow),
          onTap: () => _runAndClose(context, onLoadSprites),
        ),
      ],
    ];
  }

  // a settings change invalidates the built animations: the tile keys include
  // the signature, so a rebuild is enough to swap them (stale files are pruned
  // when each new animation is written)
  void _invalidateSpriteAnimations() => cloudSpriteAnimationsVersion.value++;

  // folder progress: import, export, clear
  List<Widget> _progressSection(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return [
      ListTile(
        leading: const Icon(Icons.insights),
        title: Text(l10n.cloudProgressSummary(settings.cloudProgressFolderCount, settings.cloudProgressImageCount)),
      ),
      const Divider(height: 8),
      ListTile(
        leading: const Icon(Icons.upload_file),
        title: Text(l10n.cloudExportProgress),
        onTap: () => _runAndClose(context, onExportProgress),
      ),
      ListTile(
        leading: const Icon(Icons.download),
        title: Text(l10n.cloudImportProgress),
        onTap: () => _runAndClose(context, onImportProgress),
      ),
      ListTile(
        leading: Icon(Icons.delete_forever, color: theme.colorScheme.error),
        title: Text(l10n.cloudClearProgress, style: TextStyle(color: theme.colorScheme.error)),
        onTap: () => _runAndClose(context, onClearProgress),
      ),
    ];
  }

  Future<void> _showCustomSpeedDialog(BuildContext context) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudViewerCustomSpeedTitle,
      suffix: 'x',
      initial: settings.cloudMosaicAutoScrollSpeed,
      min: CloudSettings.autoScrollSpeedMin,
      max: CloudSettings.autoScrollSpeedMax,
      hint: '3.0',
      minExclusive: true,
    );
    if (result != null) settings.cloudMosaicAutoScrollSpeed = result;
  }

  Future<void> _showCustomIntervalDialog(BuildContext context) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudViewerCustomIntervalTitle,
      suffix: 's',
      initial: settings.cloudMosaicAutoPageFlipInterval,
      min: CloudSettings.mosaicPageFlipIntervalMin,
      max: CloudSettings.mosaicPageFlipIntervalMax,
      hint: '3.0',
    );
    if (result != null) settings.cloudMosaicAutoPageFlipInterval = result;
  }

  Future<void> _showCustomDistanceDialog(BuildContext context) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudViewerCustomDistanceTitle,
      suffix: '%',
      initial: (settings.cloudMosaicAutoPageFlipDistance * 100).round(),
      min: (CloudSettings.pageFlipDistanceMin * 100).round(),
      max: (CloudSettings.pageFlipDistanceMax * 100).round(),
      hint: '80',
      decimal: false,
    );
    if (result != null) settings.cloudMosaicAutoPageFlipDistance = result / 100.0;
  }

  Future<void> _showCustomMagnifierDelayDialog(BuildContext context) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudCustomMagnifierDelayTitle,
      suffix: 'ms',
      initial: settings.cloudMosaicMagnifierDelay,
      min: CloudSettings.magnifierDelayMin,
      max: CloudSettings.magnifierDelayMax,
      hint: '200',
      decimal: false,
    );
    if (result != null) settings.cloudMosaicMagnifierDelay = result.round();
  }

  // the steppers share this input dialog, so an exact value is always possible
  // without adding another preset chip to the sheet
  Future<void> _showColumnDialog(BuildContext context) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.webdavColumnsTitle,
      suffix: '',
      initial: settings.cloudColumns.round(),
      min: CloudSettings.minCloudColumns.round(),
      max: CloudSettings.maxCloudColumns.round(),
      hint: '3',
      decimal: false,
    );
    if (result != null) settings.cloudColumns = result.roundToDouble();
  }

  Future<void> _showCustomVideoPercentDialog(BuildContext context) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudVideoThumbnailPosition,
      suffix: '%',
      initial: settings.cloudVideoThumbnailPercent.round(),
      min: CloudSettings.minVideoThumbnailPercent.round(),
      max: CloudSettings.maxVideoThumbnailPercent.round(),
      hint: '80',
      decimal: false,
    );
    if (result != null) settings.cloudVideoThumbnailPercent = result;
  }

  Future<void> _showCustomRateDialog(BuildContext context, bool perFolder) async {
    final current = perFolder ? settings.cloudThumbnailRateForFolder(url) : settings.cloudThumbnailRate;
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudThumbnailRate,
      suffix: '/s',
      initial: current,
      min: CloudSettings.minThumbnailRate,
      max: CloudSettings.maxThumbnailRate,
      hint: '2',
      decimal: false,
    );
    if (result == null) return;
    final value = result.round();
    if (perFolder) {
      settings.setCloudThumbnailRateForFolder(url, value);
    } else {
      settings.cloudThumbnailRate = value;
    }
  }

  Future<void> _showCustomSpriteSpeedDialog(BuildContext context) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudSpriteAnimationSpeed,
      suffix: ' 帧/秒',
      initial: settings.cloudSpriteAnimationSpeed,
      min: CloudSettings.spriteAnimationSpeedMin,
      max: CloudSettings.spriteAnimationSpeedMax,
      hint: '2',
    );
    if (result != null) settings.cloudSpriteAnimationSpeed = result;
  }

  Future<void> _showCustomSpritePlaybackZoneDialog(BuildContext context) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudSpritePlaybackZone,
      suffix: '%',
      initial: settings.cloudSpritePlaybackZone.toDouble(),
      min: CloudSettings.minSpritePlaybackZone.toDouble(),
      max: CloudSettings.maxSpritePlaybackZone.toDouble(),
      hint: '20',
      decimal: false,
    );
    if (result != null) settings.cloudSpritePlaybackZone = result.round();
  }

  Future<void> _showCustomSpriteStartPercentDialog(BuildContext context) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudSpriteStartPercent,
      suffix: '%',
      initial: settings.cloudSpriteStartPercent.toDouble(),
      min: CloudSettings.minSpriteStartPercent.toDouble(),
      max: CloudSettings.maxSpriteStartPercent.toDouble(),
      hint: '0',
      decimal: false,
    );
    if (result != null) settings.cloudSpriteStartPercent = result.round();
  }

  Future<void> _showCustomMagnifierScaleDialog(BuildContext context) async {
    final result = await showCloudNumberDialog(
      context,
      title: context.l10n.cloudCustomMagnifierScaleTitle,
      suffix: 'x',
      initial: settings.cloudMosaicMagnifierScale,
      min: CloudSettings.magnifierScaleMin,
      max: CloudSettings.magnifierScaleMax,
      hint: '2.0',
    );
    if (result != null) settings.cloudMosaicMagnifierScale = result;
  }

  void _runAndClose(BuildContext context, Future<void> Function()? action) {
    if (action == null) return;
    Navigator.pop(context);
    action();
  }

  Widget _sectionTitle(BuildContext context, String text) => cloudOptionSectionTitle(context, text);

  Widget _chipRow(BuildContext context, String label, String selected, ValueChanged<String> onSelected) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in layoutValues)
                ChoiceChip(
                  avatar: Icon(layoutIcon(value), size: 18),
                  label: Text(layoutName(context, value)),
                  selected: value == selected,
                  onSelected: (_) => onSelected(value),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chips<T>({
    required List<T> values,
    required T selected,
    required String Function(T) label,
    required IconData Function(T) icon,
    required ValueChanged<T> onSelected,
    bool compact = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final value in values)
            ChoiceChip(
              avatar: Icon(icon(value), size: 18),
              label: Text(label(value)),
              selected: value == selected,
              // compact chips drop the padding so a row of short options fits
              // without stretching the whole sheet
              labelPadding: compact ? const EdgeInsets.symmetric(horizontal: 2) : null,
              visualDensity: compact ? VisualDensity.compact : null,
              onSelected: (_) => onSelected(value),
            ),
        ],
      ),
    );
  }
}
