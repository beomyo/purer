import 'package:purer/model/entry/entry.dart';
import 'package:purer/model/entry/origins.dart';
import 'package:purer/model/settings/settings.dart';
import 'package:purer/model/source/cloud/cloud_resource.dart';

// Builds a media entry for a remote resource. Shared by the browser and the
// in-player video picker, so both describe the same file the same way.
PurerEntry cloudEntryFromResource(CloudResource resource, {required String mimeType, int id = 0}) {
  final dim = settings.cloudImageDimensions(resource.url);
  return PurerEntry(
    id: id,
    uri: resource.url,
    // remote entries have no local path, which also keeps the video backend
    // from looking for sibling subtitle files on disk
    path: null,
    contentId: null,
    pageId: null,
    sourceMimeType: mimeType,
    width: dim?.$1 ?? 0,
    height: dim?.$2 ?? 0,
    sourceRotationDegrees: 0,
    sizeBytes: resource.sizeBytes,
    sourceTitle: resource.name,
    dateAddedSecs: null,
    dateModifiedMillis: resource.dateModifiedMillis,
    sourceDateTakenMillis: null,
    durationMillis: null,
    trashed: false,
    origin: EntryOrigins.webDav,
  );
}
