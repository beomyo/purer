import 'package:purer/model/settings/settings.dart';
import 'package:purer/utils/cloud_url.dart';

// "server name  /relative/path" for a cloud URL, falling back to the decoded
// URL when no configured service owns it. Used by the settings and scrape pages
// so both describe a folder the same way.
String cloudFolderDisplay(String url, {bool showRootSlash = true}) {
  if (url.isEmpty) return '';
  for (final server in settings.cloudServers) {
    final root = server.url.endsWith('/') ? server.url : '${server.url}/';
    if (url == root || url.startsWith(root)) {
      final relative = decodeCloudPath(url.substring(root.length));
      if (relative.isEmpty) return showRootSlash ? '${server.displayName}  /' : server.displayName;
      return '${server.displayName}  /$relative';
    }
  }
  return decodeCloudUrl(url);
}
