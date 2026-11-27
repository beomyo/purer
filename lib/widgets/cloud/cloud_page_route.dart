import 'package:purer/model/settings/settings.dart' as purer;
import 'package:flutter/widgets.dart';

// Page route used to enter a service (or a settings page) from a list.
//
// The browser changes its whole content when a folder is opened, without a page
// transition, so entering a service from the home list must not slide a new
// screen over it: a short fade through reads as the same view switching to
// another folder, which is what makes the home list feel like part of the
// browser instead of a separate app.
Route<T> cloudFadeRoute<T>({
  required RouteSettings settings,
  required WidgetBuilder builder,
  Duration duration = const Duration(milliseconds: 220),
}) {
  final effective = purer.settings.areAnimationsRemoved ? Duration.zero : duration;
  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: effective,
    reverseTransitionDuration: effective,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      // a pure cross-fade, with no slide or scale: both pages have the same
      // shell, so any movement would show up as a misalignment of the rows
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
      return FadeTransition(opacity: curved, child: child);
    },
  );
}
