import 'package:purer/model/settings/modules/cloud.dart';
import 'package:purer/model/settings/settings.dart';
import 'package:purer/model/source/cloud/cloud_resource.dart';
import 'package:purer/model/source/cloud/cloud_server.dart';
import 'package:purer/services/common/cloud_registry.dart';
import 'package:purer/services/media/cloud_client.dart';
import 'package:purer/theme/icons.dart';
import 'package:purer/utils/cloud_url.dart';
import 'package:purer/widgets/common/basic/scaffold.dart';
import 'package:purer/widgets/common/extensions/build_context.dart';
import 'package:purer/widgets/common/identity/empty.dart';
import 'package:material_ui/material_ui.dart';

// Picks a collection from one of the configured cloud services. Used for the
// shared thumbnail cache destination, for choosing the folder to scrape, and
// for picking a move destination. The chosen pair is returned as
// `(server, folder url)`.
class CloudFolderPickerPage extends StatefulWidget {
  static const routeName = '/cloud/folder-picker';

  final String title;
  final String? initialServerId;
  final String? initialFolder;

  const new({
    super.key,
    required this.title,
    this.initialServerId,
    this.initialFolder,
  });

  @override
  State<CloudFolderPickerPage> createState() => _CloudFolderPickerPageState();
}

class _CloudFolderPickerPageState extends State<CloudFolderPickerPage> {
  late final List<CloudServer> _servers;
  CloudServer? _server;
  String _folder = '';
  bool _loading = false;
  String? _error;
  List<CloudResource> _folders = const [];
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _servers = settings.cloudServers;
    if (_servers.isNotEmpty) {
      CloudServer? initial;
      for (final server in _servers) {
        if (server.id == widget.initialServerId) {
          initial = server;
          break;
        }
      }
      _selectServer(initial ?? _servers.first);
    }
  }

  static String _rootOf(CloudServer server) => server.url.endsWith('/') ? server.url : '${server.url}/';

  void _selectServer(CloudServer server) {
    _server = server;
    final root = _rootOf(server);
    final initial = widget.initialFolder;
    _folder = (initial != null && initial.startsWith(root)) ? (initial.endsWith('/') ? initial : '$initial/') : root;
    _folders = const [];
    _error = null;
    _load();
  }

  Future<void> _load() async {
    final server = _server;
    if (server == null) return;
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = cloudRegistry.clientForServer(server);
      if (client == null) throw StateError('找不到该服务');
      final resources = await client.list(_folder);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _folders = resources.where((resource) => resource.isCollection).toList();
        _loading = false;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = cloudErrorText(error);
        _loading = false;
      });
    }
  }

  bool get _atRoot {
    final server = _server;
    if (server == null) return true;
    return _folder == _rootOf(server);
  }

  void _goUp() {
    final server = _server;
    if (server == null || _atRoot) return;
    final root = _rootOf(server);
    final parent = CloudSettings.cloudParentUrl(_folder);
    _folder = parent.startsWith(root) ? parent : root;
    _load();
  }

  void _enter(CloudResource folder) {
    final url = folder.url.endsWith('/') ? folder.url : '${folder.url}/';
    _folder = url;
    _load();
  }

  String get _relativePath {
    final server = _server;
    if (server == null) return '';
    final root = _rootOf(server);
    if (!_folder.startsWith(root)) return decodeCloudUrl(_folder);
    final relative = decodeCloudPath(_folder.substring(root.length));
    return relative.isEmpty ? '/' : '/$relative';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final server = _server;
    return PurerScaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (_servers.length > 1)
            PopupMenuButton<CloudServer>(
              tooltip: l10n.cloudFolderPickerServer,
              icon: const Icon(AIcons.cloud),
              onSelected: (selected) {
                if (selected == _server) return;
                setState(() => _selectServer(selected));
              },
              itemBuilder: (context) => [
                for (final option in _servers)
                  PopupMenuItem<CloudServer>(
                    value: option,
                    child: Text(option.displayName),
                  ),
              ],
            ),
        ],
      ),
      body: _servers.isEmpty
          ? EmptyContent(
              icon: AIcons.cloud,
              text: l10n.cloudFolderPickerNoServers,
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 8, 4),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: _atRoot ? null : _goUp,
                      ),
                      Expanded(
                        child: Text(
                          '${server?.displayName ?? ''}  $_relativePath',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      IconButton(
                        tooltip: context.l10n.webdavRefresh,
                        icon: const Icon(Icons.refresh),
                        onPressed: _loading ? null : _load,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _error != null
                      ? EmptyContent(
                          icon: AIcons.error,
                          text: '${l10n.cloudFolderPickerLoadError}\n$_error',
                          bottom: Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: OutlinedButton(onPressed: _load, child: Text(l10n.webdavRefresh)),
                          ),
                        )
                      : _folders.isEmpty
                      ? EmptyContent(icon: AIcons.folder, text: l10n.cloudFolderPickerEmpty)
                      : ListView.builder(
                          itemCount: _folders.length,
                          itemBuilder: (context, index) {
                            final folder = _folders[index];
                            return ListTile(
                              leading: const Icon(AIcons.folder),
                              title: Text(folder.name),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _enter(folder),
                            );
                          },
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.check),
                        label: Text(l10n.cloudFolderPickerSelect),
                        onPressed: server == null || _loading ? null : () => Navigator.pop(context, (server, _folder)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
