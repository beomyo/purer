import 'package:purer/services/device_service.dart';
import 'package:purer/services/media/cloud_fetch_service.dart';
import 'package:purer/services/media/media_fetch_service.dart';
import 'package:purer/services/report_service.dart';
import 'package:purer/services/share_service.dart';
import 'package:purer/services/storage_service.dart';
import 'package:purer/services/window_service.dart';
import 'package:purer_video/purer_video.dart';
import 'package:purer_video_mpv/purer_video_mpv.dart';
import 'package:get_it/get_it.dart';
import 'package:path/path.dart' as p;
import 'package:purer_report/purer_report.dart';

final getIt = GetIt.instance;

final p.Context pContext = getIt<p.Context>();
final PurerVideoControllerFactory videoControllerFactory = getIt<PurerVideoControllerFactory>();
final PurerVideoMetadataFetcher videoMetadataFetcher = getIt<PurerVideoMetadataFetcher>();

final DeviceService deviceService = getIt<DeviceService>();
final MediaFetchService mediaFetchService = getIt<MediaFetchService>();
final ReportService reportService = getIt<ReportService>();
final ShareService shareService = getIt<ShareService>();
final StorageService storageService = getIt<StorageService>();
final WindowService windowService = getIt<WindowService>();

// The cloud app only needs the parts of the platform bridge that remote media
// relies on: media decoding/thumbnails, file pickers for progress export, the
// window helpers used while playing a video, and error reporting. Local media
// library, metadata, wallpaper, search and app-management services are gone.
void initPlatformServices() {
  getIt.registerLazySingleton<p.Context>(p.Context.new);
  getIt.registerLazySingleton<PurerVideoControllerFactory>(MpvVideoControllerFactory.new);
  getIt.registerLazySingleton<PurerVideoMetadataFetcher>(MpvVideoMetadataFetcher.new);

  getIt.registerLazySingleton<DeviceService>(PlatformDeviceService.new);
  getIt.registerLazySingleton<MediaFetchService>(() => CloudAwareMediaFetchService(PlatformMediaFetchService()));
  getIt.registerLazySingleton<ReportService>(DebugReportService.new);
  getIt.registerLazySingleton<ShareService>(PlatformShareService.new);
  getIt.registerLazySingleton<StorageService>(PlatformStorageService.new);
  getIt.registerLazySingleton<WindowService>(PlatformWindowService.new);
}
