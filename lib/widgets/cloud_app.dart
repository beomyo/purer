import 'dart:async';

import 'package:purer/l10n/l10n.dart';
import 'package:purer/locale/supported_locales.dart';
import 'package:purer/model/device.dart';
import 'package:purer/model/settings/enums/theme_brightness.dart';
import 'package:purer/model/settings/settings.dart';
import 'package:purer/services/accessibility_service.dart';
import 'package:purer/services/common/services.dart';
import 'package:purer/services/log/purer_log.dart';
import 'package:purer/theme/system_ui.dart';
import 'package:purer/theme/themes.dart';
import 'package:purer/widgets/cloud/cloud_server_list_page.dart';
import 'package:purer/widgets/common/providers/durations_provider.dart';
import 'package:purer/widgets/common/providers/media_query_data_provider.dart';
import 'package:purer/widgets/settings/language/locales.dart';
import 'package:purer_model/purer_model.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

const appTitle = 'Purer';

// Root of the cloud-only app: there is no local media library, so the app opens
// directly on the list of WebDAV services.
class CloudApp extends StatefulWidget {
  const new({super.key});

  @override
  State<CloudApp> createState() => _CloudAppState();
}

class _CloudAppState extends State<CloudApp> with WidgetsBindingObserver {
  late final Future<void> _appSetup;
  StreamSubscription<SettingsChangedEvent>? _settingsSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appSetup = _setup();
  }

  @override
  void dispose() {
    _settingsSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // the system can restore the bars when the app comes back from the
    // background (permission dialogs, video playback, ...): hide them again
    if (state == AppLifecycleState.resumed) {
      _applySystemUiMode();
    }
  }

  void _applySystemUiMode() => unawaited(applyAppSystemUiMode(fullScreen: settings.hideSystemStatusBar));

  Future<void> _setup() async {
    // these platform queries are independent, so they run together instead of
    // delaying the first screen one round trip at a time
    final accessibility = (
      AccessibilityService.areAnimationsRemoved(),
      AccessibilityService.getLongPressTimeout(),
    ).wait;
    await Future.wait([device.init(), settings.init()]);
    _settingsSub = settings.updateStream.listen((event) {
      if (event.key == SettingKeys.hideSystemStatusBarKey) {
        _applySystemUiMode();
      }
    });
    _applySystemUiMode();
    final (animationsRemoved, longPressTimeout) = await accessibility;
    // writing an unchanged value would write SharedPreferences on every launch
    if (settings.areAnimationsRemoved != animationsRemoved) {
      settings.areAnimationsRemoved = animationsRemoved;
    }
    if (settings.longPressTimeout.inMilliseconds != longPressTimeout) {
      settings.longPressTimeoutMillis = longPressTimeout;
    }
    // expose the translated languages in Android's per-app language settings
    // (Android 13+)
    unawaited(deviceService.setLocaleConfig(supportedLocales));
    // bounded bitmap count; the decoded bitmap budget is applied by the cloud
    // image loader when it honors the quality setting
    imageCache.maximumSize = 1000;
    // libmpv is only needed for video playback and the mpv frame fallback and
    // is initialized on first use, so it does not delay the first screen
    purerLog.info(PurerLogCategory.app, '应用启动');
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<Settings>.value(value: settings),
        DurationsProvider(),
      ],
      child: FutureBuilder<void>(
        future: _appSetup,
        builder: (context, snapshot) {
          final initialized = !snapshot.hasError && snapshot.connectionState == ConnectionState.done;
          // the launch window shows only its background color (see
          // `values/styles.xml`); the first Flutter frame uses the same color
          // and the home page fades in over it, so the start has neither an
          // icon flash nor a hard cut
          final home = initialized
              ? const CloudServerListPage(key: ValueKey('home'))
              : snapshot.hasError
                  ? Scaffold(
                      body: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(snapshot.error.toString()),
                        ),
                      ),
                    )
                  : const _LaunchBackground(key: ValueKey('launch'));
          return Selector<Settings, (PurerThemeBrightness, bool)>(
            selector: (context, s) => (s.themeBrightness, s.enableDynamicColor),
            builder: (context, s, child) {
              final (themeBrightness, enableDynamicColor) = s;
              return DynamicColorBuilder(
                builder: (lightScheme, darkScheme) {
                  const defaultAccent = Colors.indigoAccent; // upstream default accent
                  Color lightAccent = defaultAccent, darkAccent = defaultAccent;
                  if (enableDynamicColor) {
                    lightAccent = lightScheme?.primary ?? lightAccent;
                    darkAccent = darkScheme?.primary ?? darkAccent;
                  }
                  // the UI ships in Simplified Chinese only
                  const knownLocale = KnownLocale.zh;
                  final lightTheme = Themes.lightTheme(lightAccent, initialized, knownLocale);
                  final darkTheme = themeBrightness == PurerThemeBrightness.black ? Themes.blackTheme(darkAccent, initialized, knownLocale) : Themes.darkTheme(darkAccent, initialized, knownLocale);
                  return MaterialApp(
                    title: appTitle,
                    home: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: home,
                    ),
                    theme: lightTheme,
                    darkTheme: darkTheme,
                    themeMode: themeBrightness.appThemeMode,
                    locale: const Locale('zh'),
                    localizationsDelegates: const [
                      ...AppLocalizations.localizationsDelegates,
                      ...GlobalMaterialLocalizations.delegates,
                    ],
                    supportedLocales: supportedLocales,
                    scrollBehavior: const CloudScrollBehavior(),
                    builder: (context, child) => MediaQueryDataProvider(child: child!),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class CloudScrollBehavior extends MaterialScrollBehavior {
  const new();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) {
    final animate = context.select<Settings, bool>((v) => v.animate);
    return animate
        ? StretchingOverscrollIndicator(
            axisDirection: details.direction,
            child: child,
          )
        : child;
  }
}

// Matches the native launch window background (see `values/styles.xml` and
// `values-night/styles.xml`), so the first Flutter frame is indistinguishable
// from the system splash while the settings load.
class _LaunchBackground extends StatelessWidget {
  const new({super.key});

  static const _dayColor = Color(0xFFFFFFFF);
  static const _nightColor = Color(0xFF262626);

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    return ColoredBox(
      color: dark ? _nightColor : _dayColor,
      child: const SizedBox.expand(),
    );
  }
}
