import 'package:purer/model/settings/settings.dart';
import 'package:purer/model/source/cloud/cloud_server.dart';
import 'package:purer/services/common/cloud_registry.dart';
import 'package:purer/services/media/cloud_media_cache.dart';
import 'package:purer/services/media/smb_stream_server.dart';
import 'package:purer/theme/icons.dart';
import 'package:purer/widgets/cloud/cloud_browser_page.dart';
import 'package:purer/widgets/cloud/cloud_page_route.dart';
import 'package:purer/widgets/cloud/cloud_server_edit_page.dart';
import 'package:purer/widgets/cloud/cloud_settings_page.dart';
import 'package:purer/widgets/common/basic/scaffold.dart';
import 'package:purer/widgets/common/extensions/build_context.dart';
import 'package:purer/widgets/common/identity/empty.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

// Management page for every remote service (WebDAV / SMB).
class CloudServerListPage extends StatelessWidget {
  static const routeName = '/cloud/servers';

  // when true, a shortcut to the last browsed folder is shown on top
  final bool showResume;

  const new({super.key, this.showResume = true});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final servers = settings.cloudServers;
    final resume = _resumeLocation();
    final l10n = context.l10n;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // The same shell as the browser: a pinned toolbar with its actions on the
    // right, then the 42px address strip, then the rows. Opening a service
    // therefore starts its first row at exactly the y of the row that was
    // tapped, and the fade transition reads as a folder switch instead of a
    // screen sliding in (which used to shift the whole list).
    return PurerScaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            primary: true,
            pinned: true,
            automaticallyImplyLeading: false,
            actions: [
              IconButton(
                tooltip: l10n.cloudAddService,
                icon: const Icon(AIcons.add),
                onPressed: () => _addServer(context),
              ),
              IconButton(
                tooltip: l10n.settingsPageTitle,
                icon: const Icon(AIcons.settings),
                onPressed: () => Navigator.push(
                  context,
                  cloudFadeRoute(
                    settings: const RouteSettings(name: CloudSettingsPage.routeName),
                    builder: (context) => const CloudSettingsPage(),
                  ),
                ),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(CloudBrowserPage.addressBarHeight),
              child: _buildAddressBar(context),
            ),
          ),
          if (servers.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyContent(
                icon: AIcons.cloud,
                text: l10n.cloudEmptyServers,
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.only(bottom: bottomInset + 24),
              sliver: SliverList.list(
                children: [
                  if (resume != null)
                    _ResumeTile(
                      server: resume.$1,
                      url: resume.$2,
                      onTap: () => _browse(context, resume.$1, initialUrl: resume.$2),
                    ),
                  for (final server in servers)
                    _ServerTile(
                      server: server,
                      onTap: () => _browse(context, server),
                      onEdit: () => _editServer(context, server),
                      onRemove: () => _removeServer(context, server),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // Empty strip where the browser shows its address bar. There is no path
  // above a service, and a label here would be a title the browser itself does
  // not have: the strip only keeps the same height, so the first row starts at
  // exactly the y it has inside a folder.
  Widget _buildAddressBar(BuildContext context) {
    return const SizedBox(height: CloudBrowserPage.addressBarHeight);
  }

  (CloudServer, String)? _resumeLocation() {
    if (!showResume) return null;
    final serverId = settings.cloudLastServerId;
    final url = settings.cloudLastUrl;
    if (serverId == null || url == null) return null;
    for (final server in settings.cloudServers) {
      if (server.id == serverId) return (server, url);
    }
    return null;
  }

  // the "+" button asks which kind of service to add
  Future<void> _addServer(BuildContext context) async {
    final type = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(context.l10n.cloudAddService, style: Theme.of(context).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(AIcons.cloud),
              title: Text(context.l10n.cloudTypeWebDav),
              subtitle: Text(context.l10n.cloudTypeWebDavHint),
              onTap: () => Navigator.pop(context, CloudServerType.webDav),
            ),
            ListTile(
              leading: const Icon(Icons.storage_rounded),
              title: Text(context.l10n.cloudTypeSmb),
              subtitle: Text(context.l10n.cloudTypeSmbHint),
              onTap: () => Navigator.pop(context, CloudServerType.smb),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (type == null || !context.mounted) return;
    await _editServer(context, null, type: type);
  }

  void _browse(BuildContext context, CloudServer server, {String? initialUrl}) {
    Navigator.push(
      context,
      cloudFadeRoute(
        settings: const RouteSettings(name: CloudBrowserPage.routeName),
        builder: (context) => CloudBrowserPage(server: server, initialUrl: initialUrl),
      ),
    );
  }

  Future<void> _editServer(BuildContext context, CloudServer? server, {String type = CloudServerType.webDav}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: CloudServerEditPage.routeName),
        builder: (context) => CloudServerEditPage(server: server, initialType: type),
      ),
    );
  }

  Future<void> _removeServer(BuildContext context, CloudServer server) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.cloudRemoveServer),
        content: Text(server.displayName),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.webdavActionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.webdavActionRemove),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      settings.removeCloudServer(server.id);
      cloudRegistry.closeServer(server.id);
      smbStreamServer.closeServer(server.id);
      cloudMediaCache.reset();
      // the shared thumbnail cache cannot point at a service that is gone
      if (settings.cloudThumbnailCacheServerId == server.id) {
        settings.cloudThumbnailCacheServerId = null;
        settings.cloudThumbnailCacheFolderUrl = null;
      }
    }
  }
}

// the last browsed folder, offered as a one tap way back into the browser.
// The folder name is hidden by default (it is the same information the browser
// itself never shows on the home screen), and the eye on the left reveals it
// for this visit only.
class _ResumeTile extends StatefulWidget {
  final CloudServer server;
  final String url;
  final VoidCallback onTap;

  const new({required this.server, required this.url, required this.onTap});

  @override
  State<_ResumeTile> createState() => _ResumeTileState();
}

class _ResumeTileState extends State<_ResumeTile> {
  bool _showName = false;

  static String _folderName(String url, CloudServer server) {
    final uri = Uri.tryParse(url);
    if (uri == null) return server.displayName;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? server.displayName : segments.last;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final hintColor = theme.hintColor;
    final name = _folderName(widget.url, widget.server);
    return ListTile(
      // a folder row: 56 wide leading column with the icon and a small label
      // under it, and a title. An `IconButton` (48dp) or a subtitle would make
      // this row taller than the folder rows it sits among
      minLeadingWidth: 56,
      leading: SizedBox(
        width: 56,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            InkResponse(
              onTap: () => setState(() => _showName = !_showName),
              radius: 20,
              child: Tooltip(
                message: l10n.cloudResumeToggleName,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(_showName ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                ),
              ),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                widget.server.displayName,
                maxLines: 1,
                style: TextStyle(fontSize: 10, height: 1.1, color: hintColor),
              ),
            ),
          ],
        ),
      ),
      title: Text(
        _showName ? name : l10n.cloudContinueBrowsing,
        style: _showName ? null : TextStyle(color: theme.colorScheme.onSurfaceVariant, fontStyle: FontStyle.italic),
      ),
      onTap: widget.onTap,
    );
  }
}

class _ServerTile extends StatelessWidget {
  final CloudServer server;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  const new({
    required this.server,
    required this.onTap,
    required this.onEdit,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final typeLabel = server.isSmb ? l10n.cloudTypeSmb : l10n.cloudTypeWebDav;
    return ListTile(
      // the same row as a folder inside the browser: leading column with the
      // icon and a small label, title only (no subtitle, no URL)
      minLeadingWidth: 56,
      leading: SizedBox(
        width: 56,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(server.isSmb ? Icons.storage_rounded : AIcons.cloud),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                typeLabel,
                maxLines: 1,
                style: TextStyle(fontSize: 10, height: 1.1, color: Theme.of(context).hintColor),
              ),
            ),
          ],
        ),
      ),
      title: Text(server.displayName),
      onTap: onTap,
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          switch (value) {
            case 'edit':
              onEdit();
            case 'remove':
              onRemove();
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(value: 'edit', child: Text(context.l10n.webdavActionEdit)),
          PopupMenuItem(value: 'remove', child: Text(context.l10n.webdavActionRemove)),
        ],
      ),
    );
  }
}
