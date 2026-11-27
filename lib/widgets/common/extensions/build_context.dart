import 'package:purer/l10n/l10n.dart';
import 'package:flutter/widgets.dart';

extension ExtraBuildContext on BuildContext {
  String? get currentRouteName => ModalRoute.of(this)?.settings.name;

  bool get isPortrait => MediaQuery.orientationOf(this) == .portrait;

  // l10n

  AppLocalizations get l10n => AppLocalizations.of(this)!;

  // the UI is Simplified Chinese (LTR), kept for the generic layout helpers
  bool get isRtl => Directionality.of(this) == TextDirection.rtl;
}
