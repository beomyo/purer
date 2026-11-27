import 'package:purer_model/purer_model.dart';
import 'package:material_ui/material_ui.dart';

extension ExtraPurerThemeBrightness on PurerThemeBrightness {
  ThemeMode get appThemeMode {
    switch (this) {
      case .system:
        return ThemeMode.system;
      case .light:
        return ThemeMode.light;
      case .dark:
      case .black:
        return ThemeMode.dark;
    }
  }
}
