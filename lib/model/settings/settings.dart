import 'dart:async';
import 'dart:ui' as ui;

import 'package:purer/locale/purer_locale.dart';
import 'package:purer/model/settings/enums/accessibility_animations.dart';
import 'package:purer/model/settings/modules/cloud.dart';
import 'package:purer/model/settings/store_shared_pref.dart';
import 'package:purer_model/purer_model.dart';
import 'package:purer_video/purer_video.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

// Cloud-only settings: the WebDAV / SMB configuration, viewing options and the
// handful of app-level preferences the cloud pages rely on (locale, theme and
// video playback). Everything related to the local media library was removed.
final Settings settings = Settings._private();

final SettingsStore settingsStore = SharedPrefSettingsStore();

class Settings with ChangeNotifier, SettingsAccess, CloudSettings, VideoSettings {
  final StreamController<SettingsChangedEvent> _updateStreamController = StreamController.broadcast();

  @override
  Stream<SettingsChangedEvent> get updateStream => _updateStreamController.stream;

  @override
  bool get initialized => store.initialized;

  @override
  SettingsStore get store => settingsStore;

  new _private();

  Future<void> init() async {
    await store.init();
  }

  @override
  void notifyKeyChange(String key, Object? oldValue, Object? newValue) {
    _updateStreamController.add(SettingsChangedEvent(key, oldValue, newValue));
  }

  // app

  // the UI is Simplified Chinese only
  ui.Locale get resolvedLocale => const ui.Locale('zh');

  PurerLocale? _purerLocale;

  PurerLocale get purerLocale {
    return _purerLocale ??= PurerLocale(languageBcp47: resolvedLocale.toLanguageTag());
  }

  // display

  PurerThemeBrightness get themeBrightness => getEnumOrDefault(SettingKeys.themeBrightnessKey, .system, PurerThemeBrightness.values);

  set themeBrightness(PurerThemeBrightness newValue) => set(SettingKeys.themeBrightnessKey, newValue.name);

  bool get enableDynamicColor => getBool(SettingKeys.enableDynamicColorKey) ?? true;

  set enableDynamicColor(bool newValue) => set(SettingKeys.enableDynamicColorKey, newValue);

  // full screen: the Android status bar is hidden and the pages start at the
  // top edge. On by default, but the setting lets the bar be restored.
  bool get hideSystemStatusBar => getBool(SettingKeys.hideSystemStatusBarKey) ?? true;

  set hideSystemStatusBar(bool newValue) => set(SettingKeys.hideSystemStatusBarKey, newValue);

  // the cloud app never enters a read-only (TV) browsing mode
  bool get isReadOnly => false;

  // background behind an image while it loads / around a non filling image
  EntryBackground get imageBackground => getEnumOrDefault(SettingKeys.imageBackgroundKey, EntryBackground.white, EntryBackground.values);

  set imageBackground(EntryBackground newValue) => set(SettingKeys.imageBackgroundKey, newValue.name);

  // thumbnail hero transition draws edge to edge (upstream default)
  bool get viewerUseCutout => true;

  Duration get longPressTimeout => Duration(milliseconds: getInt(SettingKeys.platformLongPressTimeoutMillisKey) ?? kLongPressTimeout.inMilliseconds);

  set longPressTimeoutMillis(int newValue) => set(SettingKeys.platformLongPressTimeoutMillisKey, newValue);

  // the cloud app has no Android TV layout
  bool get useTvLayout => false;

  // accessibility

  AccessibilityAnimations get accessibilityAnimations => getEnumOrDefault(SettingKeys.accessibilityAnimationsKey, AccessibilityAnimations.system, AccessibilityAnimations.values);

  set accessibilityAnimations(AccessibilityAnimations newValue) => set(SettingKeys.accessibilityAnimationsKey, newValue.name);

  bool get animate => accessibilityAnimations.animate;

  AccessibilityTimeout get timeToTakeAction => getEnumOrDefault(SettingKeys.timeToTakeActionKey, AccessibilityTimeout.s3, AccessibilityTimeout.values);

  set timeToTakeAction(AccessibilityTimeout newValue) => set(SettingKeys.timeToTakeActionKey, newValue.name);

  bool get areAnimationsRemoved => getBool(SettingKeys.platformTransitionAnimationScaleKey) ?? false;

  set areAnimationsRemoved(bool newValue) => set(SettingKeys.platformTransitionAnimationScaleKey, newValue);
}
