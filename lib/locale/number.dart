import 'package:intl/intl.dart' as intl;

class ANumberFormat._private(
  final String Function(num number) _format,
) {
  factory fromIntl(intl.NumberFormat nf) {
    return ANumberFormat._private(nf.format);
  }

  String format(num number) => _format(number);
}
