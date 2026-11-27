import 'dart:async';

import 'package:purer/services/common/services.dart';
import 'package:purer/theme/system_ui.dart';
import 'package:purer/widgets/cloud_app.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:leak_tracker/leak_tracker.dart';

@pragma('vm:entry-point')
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // mirrors the upstream app, so objects instrumented with `LeakTracking`
  // (entries, tile controllers) are tracked in debug builds
  LeakTracking.start();
  FlutterMemoryAllocations.instance.addListener(
    (event) => LeakTracking.dispatchObjectEvent(event.toMap()),
  );
  initPlatformServices();
  // hide the status bar from the very first frame; the stored preference is
  // applied again once the settings are loaded (see `CloudApp`)
  unawaited(applyAppSystemUiMode(fullScreen: true));
  runApp(const CloudApp());
}
