import 'package:purer/widgets/settings/language/locales.dart';
import 'package:flutter/widgets.dart';

class AStyles {
  static TextStyle _baseTitleStyle(KnownLocale? locale) {
    final supportSmallCaps = locale?.supportSmallCaps ?? true;
    final supportLetterSpacing = locale?.supportLetterSpacing ?? true;
    return TextStyle(
      fontWeight: supportSmallCaps ? .w300 : .normal,
      letterSpacing: supportSmallCaps && supportLetterSpacing ? 1 : 0,
      fontFeatures: supportSmallCaps ? const [FontFeature.enable('smcp')] : [],
    );
  }

  static TextStyle pageTitleTextStyle(KnownLocale locale) {
    return _baseTitleStyle(locale).copyWith(
      fontSize: 20,
      fontWeight: .normal,
    );
  }

  static const embossShadows = [
    Shadow(
      color: Color(0xFF000000),
      offset: Offset(0.5, 1.0),
    ),
  ];
}
