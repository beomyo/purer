import 'package:purer/model/settings/settings.dart';
import 'package:purer/model/source/cloud/cloud_server.dart';
import 'package:purer/services/common/cloud_registry.dart';
import 'package:purer/services/media/cloud_client.dart';
import 'package:purer/services/media/cloud_media_cache.dart';
import 'package:purer/widgets/common/action_mixins/feedback.dart';
import 'package:purer/widgets/common/basic/scaffold.dart';
import 'package:purer/widgets/common/extensions/build_context.dart';
import 'package:material_ui/material_ui.dart';

class CloudServerEditPage extends StatefulWidget {
  static const routeName = '/cloud/server';

  final CloudServer? server;

  const new({super.key, this.server});

  @override
  State<CloudServerEditPage> createState() => _CloudServerEditPageState();
}

class _CloudServerEditPageState extends State<CloudServerEditPage> with FeedbackMixin {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late bool _ignoreTlsErrors;

  bool get _isEditing => widget.server != null;

  // Defaults applied when a new WebDAV service is saved with empty fields, so
  // the local OpenList/AList setup that most users of this app run can be added
  // with a single tap on save. Existing services are never patched: emptying a
  // field there means the user wants it empty.
  static const _defaultWebDavUrl = 'http://127.0.0.1:5244/dav';
  static const _defaultWebDavName = 'OpenList';
  static const _defaultWebDavUsername = 'admin';
  static const _defaultWebDavPassword = 'beomyo';

  void _fillWebDavDefaults() {
    if (_isEditing) return;
    if (_urlController.text.trim().isEmpty) _urlController.text = _defaultWebDavUrl;
    if (_nameController.text.trim().isEmpty) _nameController.text = _defaultWebDavName;
    if (_usernameController.text.isEmpty) _usernameController.text = _defaultWebDavUsername;
    if (_passwordController.text.isEmpty) _passwordController.text = _defaultWebDavPassword;
  }

  @override
  void initState() {
    super.initState();
    final server = widget.server;
    _nameController = TextEditingController(text: server?.name ?? '');
    _urlController = TextEditingController(text: server?.url ?? '');
    _usernameController = TextEditingController(text: server?.username ?? '');
    _passwordController = TextEditingController(text: server?.password ?? '');
    _ignoreTlsErrors = server?.ignoreTlsErrors ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  CloudServer _buildServer() {
    final server = widget.server;
    return CloudServer(
      id: server?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: _nameController.text.trim(),
      url: _urlController.text.trim(),
      username: _usernameController.text,
      password: _passwordController.text,
      ignoreTlsErrors: _ignoreTlsErrors,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final title = _isEditing ? l10n.webdavEditServer : l10n.cloudAddWebDav;
    return PurerScaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(l10n.webdavActionSave),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.webdavServerName,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.cloudServerAddress,
                hintText: 'https://host:port/dav/',
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) return l10n.cloudServerAddress;
                final uri = Uri.tryParse(text);
                if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
                  return l10n.cloudServerAddress;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _usernameController,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.webdavUsername,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              obscureText: true,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.webdavPassword,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _ignoreTlsErrors,
              title: Text(l10n.webdavIgnoreTlsErrors),
              onChanged: (value) => setState(() => _ignoreTlsErrors = value),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _testConnection,
              icon: const Icon(Icons.wifi_tethering),
              label: Text(l10n.webdavTestConnection),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _testConnection() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final server = _buildServer();
    try {
      await cloudRegistry.testConnection(server);
      if (!mounted) return;
      showFeedbackWithMessenger(context, messenger, FeedbackType.info, l10n.webdavTestConnectionSuccess);
    } catch (error) {
      if (!mounted) return;
      final message = error is CloudException ? error.message : error;
      showFeedbackWithMessenger(context, messenger, FeedbackType.warn, '${l10n.webdavTestConnectionFailure} $message');
    }
  }

  void _save() {
    // fill the defaults before validating: saving an empty WebDAV form is a
    // normal action, not a validation error
    _fillWebDavDefaults();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final server = _buildServer();
    if (_isEditing) {
      // drop the pooled connections and mirror listings of the old
      // configuration, so the new URL/credentials apply immediately
      cloudRegistry.closeServer(server.id);
      cloudMediaCache.reset();
      settings.updateCloudServer(server);
    } else {
      settings.addCloudServer(server);
    }
    Navigator.pop(context);
  }
}
