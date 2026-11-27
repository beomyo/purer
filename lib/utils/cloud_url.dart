// Cloud URLs carry UTF-8 percent-encoded path segments
// (`/Photos/%E5%81%87%E6%9C%9F/`), which are unreadable in a folder line or a
// log record. These helpers decode them for display only: the stored and
// requested URLs stay encoded.

String decodeCloudSegment(String segment) {
  if (!segment.contains('%')) return segment;
  try {
    return Uri.decodeComponent(segment);
  } catch (_) {
    // not valid percent-encoding (a literal `%` in a file name): keep as is
    return segment;
  }
}

String decodeCloudPath(String path) => path.split('/').map(decodeCloudSegment).join('/');

// schemes a remote (cloud) entry can use: WebDAV over HTTP(S)
const _cloudUriSchemes = ['http://', 'https://'];

bool isCloudUri(String uri) {
  for (final scheme in _cloudUriSchemes) {
    if (uri.startsWith(scheme)) return true;
  }
  return false;
}

// decodes the path of `scheme://authority/path`, leaving the scheme, the host
// and any other part untouched
String decodeCloudUrl(String url) {
  final schemeEnd = url.indexOf('://');
  if (schemeEnd < 0) return decodeCloudPath(url);
  final authorityEnd = url.indexOf('/', schemeEnd + 3);
  if (authorityEnd < 0) return url;
  return url.substring(0, authorityEnd) + decodeCloudPath(url.substring(authorityEnd));
}
