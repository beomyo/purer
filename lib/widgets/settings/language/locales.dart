// this class is kept minimal, without Flutter imports
// so it can be reused in driver tests
class const KnownLocale({
  // BCP 47 language tag: https://en.wikipedia.org/wiki/IETF_language_tag
  required final String bcp47,
  required final String endonym,
  final bool supportLetterSpacing = true,
  final bool supportSmallCaps = true,
}) {
  static KnownLocale? fromBcp47(String? bcp47) => all.where((v) => v.bcp47 == bcp47).firstOrNull;

  static const english = KnownLocale(bcp47: 'en', endonym: 'English');

  static const zh = KnownLocale(bcp47: 'zh', endonym: '简体中文');

  // the app ships in Simplified Chinese only
  static const all = [english, zh];
}
