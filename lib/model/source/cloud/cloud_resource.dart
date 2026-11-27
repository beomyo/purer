import 'package:equatable/equatable.dart';

class CloudResource extends Equatable {
  // absolute URL used for requests
  final String url;
  // decoded last path segment, used for display
  final String name;
  final bool isCollection;
  final String? mimeType;
  final int? sizeBytes;
  final int? dateModifiedMillis;

  @override
  List<Object?> get props => [url, name, isCollection, mimeType, sizeBytes, dateModifiedMillis];

  const new({
    required this.url,
    required this.name,
    required this.isCollection,
    this.mimeType,
    this.sizeBytes,
    this.dateModifiedMillis,
  });
}

// folder rows are always name-sorted, whatever the media sort is
List<CloudResource> sortCloudResourcesByName(Iterable<CloudResource> resources, {bool descending = false}) {
  final sorted = resources.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return descending ? sorted.reversed.toList() : sorted;
}
