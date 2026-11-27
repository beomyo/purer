// ignore_for_file: non_constant_identifier_names
import 'package:purer/locale/calendar/dateformat/base.dart';
import 'package:purer/locale/calendar/dateformat/intl.dart';
import 'package:purer/locale/number.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart' as intl;

// Chinese (Gregorian) formatting only: the app has no calendar or numeral
// system preference, so the `intl` delegates are enough.
class PurerLocale({
  required final String languageBcp47,
}) {
  late final DateFormatDelegate _dateFormatDelegate = IntlDateFormatDelegate(languageTag: languageBcp47);

  @override
  String toString() => '$runtimeType#${shortHash(this)}{languageBcp47=$languageBcp47}';

  ANumberFormat numberFormat(String pattern) {
    return ANumberFormat.fromIntl(intl.NumberFormat(pattern, languageBcp47));
  }

  ANumberFormat decimalNumberFormat() {
    return ANumberFormat.fromIntl(intl.NumberFormat.decimalPattern(languageBcp47));
  }

  ANumberFormat percentNumberFormat() {
    return ANumberFormat.fromIntl(intl.NumberFormat.percentPattern(languageBcp47));
  }

  DateFormatter? _y;

  DateFormatter get y {
    _y ??= _dateFormatDelegate.y;
    return _y!;
  }

  DateFormatter? _MMM;

  DateFormatter get MMM {
    _MMM ??= _dateFormatDelegate.MMM;
    return _MMM!;
  }

  DateFormatter? _MMMM;

  DateFormatter get MMMM {
    _MMMM ??= _dateFormatDelegate.MMMM;
    return _MMMM!;
  }

  DateFormatter? _d;

  DateFormatter get d {
    _d ??= _dateFormatDelegate.d;
    return _d!;
  }

  DateFormatter? _MMMd;

  DateFormatter get MMMd {
    _MMMd ??= _dateFormatDelegate.MMMd;
    return _MMMd!;
  }

  DateFormatter? _MMMMd;

  DateFormatter get MMMMd {
    _MMMMd ??= _dateFormatDelegate.MMMMd;
    return _MMMMd!;
  }

  DateFormatter? _yMMM;

  DateFormatter get yMMM {
    _yMMM ??= _dateFormatDelegate.yMMM;
    return _yMMM!;
  }

  DateFormatter? _yMMMM;

  DateFormatter get yMMMM {
    _yMMMM ??= _dateFormatDelegate.yMMMM;
    return _yMMMM!;
  }

  DateFormatter? _MMMEd;

  DateFormatter get MMMEd {
    _MMMEd ??= _dateFormatDelegate.MMMEd;
    return _MMMEd!;
  }

  DateFormatter? _yMd;

  DateFormatter get yMd {
    _yMd ??= _dateFormatDelegate.yMd;
    return _yMd!;
  }

  DateFormatter? _yMMMd;

  DateFormatter get yMMMd {
    _yMMMd ??= _dateFormatDelegate.yMMMd;
    return _yMMMd!;
  }

  DateFormatter? _yMMMMd;

  DateFormatter get yMMMMd {
    _yMMMMd ??= _dateFormatDelegate.yMMMMd;
    return _yMMMMd!;
  }

  DateFormatter? _yMMMMEEEEd;

  DateFormatter get yMMMMEEEEd {
    _yMMMMEEEEd ??= _dateFormatDelegate.yMMMMEEEEd;
    return _yMMMMEEEEd!;
  }

  DateFormatter? _Hm;

  DateFormatter get Hm {
    _Hm ??= _dateFormatDelegate.Hm;
    return _Hm!;
  }

  DateFormatter? _jm;

  DateFormatter get jm {
    _jm ??= _dateFormatDelegate.jm;
    return _jm!;
  }
}
