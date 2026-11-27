import 'package:purer/model/settings/settings.dart';
import 'package:purer/model/source/cloud/cloud_resource.dart';
import 'package:purer/ref/mime_types.dart';
import 'package:purer/services/common/cloud_registry.dart';
import 'package:purer/services/media/cloud_client.dart';
import 'package:purer/services/media/cloud_mime.dart';
import 'package:purer/theme/icons.dart';
import 'package:purer/widgets/common/extensions/build_context.dart';
import 'package:purer/widgets/common/identity/empty.dart';
import 'package:material_ui/material_ui.dart';

// Simple folder browser shown inside the cloud video player, so another video
// can be picked and played without leaving the player.
//
// Returns the picked [CloudResource] through `Navigator.pop`, or null.
class CloudVideoBrowserSheet extends StatefulWidget {
  static const maxHeightRatio = .75;

  // stable URL of the file currently playing, used to start in its folder and
  // to highlight it
  final String playingUri;

  const new({super.key, required this.playingUri});

  @override
  State<CloudVideoBrowserSheet> createState() => _CloudVideoBrowserSheetState();
}

enum _LoadState { loading, ready, error }

class _CloudVideoBrowserSheetState extends State<CloudVideoBrowserSheet> {
  final ValueNotifier<_LoadState> _state = ValueNotifier(.loading);
  final ValueNotifier<String> _error = ValueNotifier('');

  late final String _serverRoot;
  late String _folderUrl;
  List<CloudResource> _folders = const [];
  List<CloudResource> _videos = const [];

  @override
  void initState() {
    super.initState();
    _serverRoot = _normalize(cloudRegistry.serverForUrl(widget.playingUri)?.url ?? widget.playingUri);
    _folderUrl = _parentOf(widget.playingUri);
    _fetch();
  }

  @override
  void dispose() {
    _state.dispose();
    _error.dispose();
    super.dispose();
  }

  static String _normalize(String url) => url.endsWith('/') ? url : '$url/';

  // parent folder of a file or folder URL, never above [serverRoot]
  String _parentOf(String url) {
    final trimmed = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final index = trimmed.lastIndexOf('/');
    if (index <= _serverRoot.length - 1) return _serverRoot;
    return _normalize(trimmed.substring(0, index));
  }

  bool get _canGoUp => _folderUrl != _serverRoot;

  Future<void> _fetch() async {
    _state.value = .loading;
    _error.value = '';
    final client = cloudRegistry.clientForUrl(_folderUrl);
    if (client == null) {
      _error.value = '没有为该地址配置云服务';
      _state.value = .error;
      return;
    }
    try {
      final resources = await client.list(_folderUrl);
      if (!mounted) return;
      final descending = settings.cloudSort == 'nameDesc';
      _folders = sortCloudResourcesByName(resources.where((v) => v.isCollection), descending: descending);
      _videos = sortCloudResourcesByName(resources.where((v) => !v.isCollection && MimeTypes.isVideo(cloudMimeForResource(v))), descending: descending);
      _state.value = .ready;
    } catch (error) {
      if (!mounted) return;
      _error.value = cloudErrorText(error);
      _state.value = .error;
    }
  }

  Future<void> _openFolder(CloudResource folder) async {
    _folderUrl = _normalize(folder.url);
    await _fetch();
  }

  Future<void> _goUp() async {
    if (!_canGoUp) return;
    _folderUrl = _parentOf(_folderUrl);
    await _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * CloudVideoBrowserSheet.maxHeightRatio,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 16, end: 16, bottom: 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(l10n.cloudVideoBrowserTitle, style: Theme.of(context).textTheme.titleMedium),
              ),
            ),
            ValueListenableBuilder<_LoadState>(
              valueListenable: _state,
              builder: (context, state, child) {
                if (state == .loading) {
                  return const Expanded(child: Center(child: CircularProgressIndicator()));
                }
                if (state == .error) {
                  return Expanded(
                    child: EmptyContent(
                      icon: AIcons.error,
                      text: '${l10n.webdavLoadError}\n${_error.value}',
                      bottom: OutlinedButton(onPressed: _fetch, child: Text(l10n.webdavRefresh)),
                    ),
                  );
                }
                return Expanded(child: _buildList(context));
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final l10n = context.l10n;
    if (_folders.isEmpty && _videos.isEmpty) {
      return EmptyContent(icon: AIcons.folder, text: l10n.webdavEmptyFolder);
    }
    return ListView.builder(
      itemCount: _folders.length + _videos.length + (_canGoUp ? 1 : 0),
      itemBuilder: (context, index) {
        if (_canGoUp && index == 0) {
          return ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('..'),
            onTap: _goUp,
          );
        }
        final folderIndex = index - (_canGoUp ? 1 : 0);
        if (folderIndex < _folders.length) {
          final folder = _folders[folderIndex];
          return ListTile(
            leading: const Icon(Icons.folder),
            title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => _openFolder(folder),
          );
        }
        final video = _videos[folderIndex - _folders.length];
        final playing = video.url == widget.playingUri;
        return ListTile(
          leading: Icon(playing ? AIcons.play : Icons.movie_outlined, color: playing ? Theme.of(context).colorScheme.primary : null),
          title: Text(video.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          selected: playing,
          onTap: () => Navigator.pop(context, video),
        );
      },
    );
  }
}
