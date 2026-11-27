import 'package:material_ui/material_ui.dart';

// Cutout insets of the current window. The cloud app lays its pages out inside
// `MediaQuery.viewPadding`, which already accounts for cutouts, so this stays
// zero and the widgets depending on it behave as a no-op.
final ValueNotifier<EdgeInsets> cutoutInsetsNotifier = ValueNotifier(EdgeInsets.zero);
