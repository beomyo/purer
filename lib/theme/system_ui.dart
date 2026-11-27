import 'package:purer/model/device.dart';
import 'package:purer/services/common/services.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

// App-wide system overlay mode. The window stays edge-to-edge, and the status
// bar is hidden through the window service: with target SDK 36, Android
// ignores the legacy fullscreen flags that `SystemUiMode.manual` relies on.
// The bottom navigation bar is kept, so back/home gestures stay clear.
Future<void> applyAppSystemUiMode({required bool fullScreen}) async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await windowService.setStatusBarHidden(fullScreen);
}

SystemUiOverlayStyle appSystemUIStyleForBrightness(Brightness themeBrightness, Color backgroundColor) {
  final barBrightness = themeBrightness == Brightness.dark ? Brightness.light : Brightness.dark;
  const statusBarColor = Colors.transparent;
  // as of Flutter v3.3.0-0.2.pre, setting `SystemUiOverlayStyle` (whether manually or automatically because of `AppBar`)
  // prevents the canvas from drawing behind the nav bar on Android <10 (API <29),
  // so the nav bar is opaque, even when requesting `SystemUiMode.edgeToEdge` from Flutter
  // or setting `android:windowTranslucentNavigation` in Android themes.
  final navBarColor = device.supportEdgeToEdgeUIMode ? Colors.transparent : backgroundColor;

  // on Android >=15 (API >=35), setting colors here has no effect
  return SystemUiOverlayStyle(
    systemNavigationBarColor: navBarColor,
    systemNavigationBarDividerColor: navBarColor,
    systemNavigationBarIconBrightness: barBrightness,
    // shows background scrim when using navigation buttons, but not when using gesture navigation
    systemNavigationBarContrastEnforced: true,
    statusBarColor: statusBarColor,
    statusBarBrightness: barBrightness,
    statusBarIconBrightness: barBrightness,
    systemStatusBarContrastEnforced: false,
  );
}
