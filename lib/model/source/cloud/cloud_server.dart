import 'dart:convert';

import 'package:equatable/equatable.dart';

// A configured remote service. Only WebDAV is supported; SMB configurations
// saved by older versions are ignored when the stored list is read.
class CloudServer extends Equatable {
  final String id;
  final String name;

  // full `http(s)://` URL of the collection
  final String url;

  final String username;
  final String password;

  final bool ignoreTlsErrors;

  @override
  List<Object?> get props => [id, name, url, username, password, ignoreTlsErrors];

  const new({
    required this.id,
    required this.name,
    required this.url,
    this.username = '',
    this.password = '',
    this.ignoreTlsErrors = false,
  });

  Uri? get uri => Uri.tryParse(url);

  String get host => uri?.host ?? '';

  String get displayName => name.isNotEmpty ? name : url;

  CloudServer copyWith({
    String? id,
    String? name,
    String? url,
    String? username,
    String? password,
    bool? ignoreTlsErrors,
  }) {
    return CloudServer(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
      ignoreTlsErrors: ignoreTlsErrors ?? this.ignoreTlsErrors,
    );
  }

  Map<String, Object?> toJsonMap() => {
    'id': id,
    'name': name,
    'url': url,
    'username': username,
    'password': password,
    'ignoreTlsErrors': ignoreTlsErrors,
  };

  String toJsonString() => jsonEncode(toJsonMap());

  static CloudServer? fromJsonString(String? jsonString) {
    if (jsonString == null || jsonString.isEmpty) return null;
    try {
      final jsonMap = jsonDecode(jsonString);
      if (jsonMap is Map) {
        final url = jsonMap['url'] as String?;
        if (url == null || url.isEmpty) return null;
        // SMB services were removed: don't keep offering one that the app can
        // no longer open.
        if (jsonMap['type'] == 'smb' || url.startsWith('smb://')) return null;
        return CloudServer(
          id: (jsonMap['id'] as String?) ?? url,
          name: (jsonMap['name'] as String?) ?? '',
          url: url,
          username: (jsonMap['username'] as String?) ?? '',
          password: (jsonMap['password'] as String?) ?? '',
          ignoreTlsErrors: (jsonMap['ignoreTlsErrors'] as bool?) ?? false,
        );
      }
    } catch (_) {
      // ignore malformed entry
    }
    return null;
  }
}
