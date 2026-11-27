import 'package:purer_report/purer_report.dart';
import 'package:flutter/foundation.dart';

// Local replacement for the Crashlytics-backed reporter: the cloud app does not
// send anything to a remote crash service, errors are only logged in debug
// builds.
class DebugReportService extends ReportService {
  @override
  Future<void> init() async {}

  @override
  Map<String, String> get state => const {};

  @override
  Future<void> setCollectionEnabled(bool enabled) async {}

  @override
  Future<void> log(String message) async {
    debugPrint('Report log=$message');
  }

  @override
  Future<void> setCustomKey(String key, Object value) async {
    debugPrint('Report set key $key=$value');
  }

  @override
  Future<void> setCustomKeys(Map<String, Object> map) async {
    for (final entry in map.entries) {
      await setCustomKey(entry.key, entry.value);
    }
  }

  @override
  Future<void> recordError(Object exception, [StackTrace? stack]) async {
    debugPrint('Report error=$exception${stack == null ? '' : '\n$stack'}');
  }

  @override
  Future<void> recordFlutterError(FlutterErrorDetails flutterErrorDetails) async {
    debugPrint('Report Flutter error=${flutterErrorDetails.exceptionAsString()}');
  }
}
