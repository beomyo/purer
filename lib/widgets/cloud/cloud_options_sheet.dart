import 'package:purer/widgets/common/extensions/build_context.dart';
import 'package:material_ui/material_ui.dart';

// Shared layout of the two option sheets (browser view options and viewer
// settings), so both look and behave the same: a titled sheet whose option
// groups are collapsible and show their current state in the subtitle.
class CloudOptionsSheet extends StatelessWidget {
  final String title;
  // full width block above the groups (the browser keeps its layout switcher
  // there); it never joins the columns
  final Widget? header;
  final List<Widget> children;

  const new({super.key, required this.title, required this.header, required this.children});

  // width from which the groups sit side by side: on a landscape phone or a
  // tablet the sheet is wide and short, and a single column leaves most of that
  // width empty (and needs a long scroll for the same options)
  static const double wideBreakpoint = 700;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 8, 0),
            child: Row(
              children: [
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.maybePop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final headerWidget = header;
                final twoColumns = constraints.maxWidth >= wideBreakpoint && children.length > 1;
                return ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    ?headerWidget,
                    if (!twoColumns)
                      ...children
                    else
                      Wrap(
                        children: [
                          for (final child in children)
                            SizedBox(
                              width: constraints.maxWidth / 2,
                              child: child,
                            ),
                        ],
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// A collapsible group of options. The subtitle shows the current state without
// having to open it, and every group starts collapsed so the sheet stays short.
class CloudOptionSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? summary;
  final List<Widget> children;

  const new({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
    this.summary,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = summary;
    return ExpansionTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title),
      subtitle: subtitle == null || subtitle.isEmpty ? null : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: children,
    );
  }
}

// label above a row of choice chips
Widget cloudOptionSectionTitle(BuildContext context, String text) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

// One numeric option on a single line: label, minus, value, plus. The value is
// also a button that opens the same input dialog as before, so any value in the
// range is one tap away.
//
// This replaces the rows of preset chips and the sliders: chips multiplied the
// buttons for a handful of presets (and still needed a separate "custom" entry
// for everything in between), while a slider took a whole line and could not be
// set exactly. With a stepper every option is one compact line and the sheet
// fits without a long scroll.
class CloudNumberStepper extends StatelessWidget {
  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;
  final VoidCallback onTapValue;
  final bool enabled;

  const new({
    super.key,
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    required this.onTapValue,
    this.enabled = true,
  });

  double _stepped(int direction) {
    final raw = value + direction * step;
    final snapped = (raw / step).round() * step;
    final clamped = snapped.clamp(min, max);
    // avoid values like 6.999999999999999 when the step is fractional
    return (clamped * 1000).round() / 1000;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canDecrease = enabled && value > min + 1e-9;
    final canIncrease = enabled && value < max - 1e-9;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove_circle_outline, size: 22),
            onPressed: canDecrease ? () => onChanged(_stepped(-1)) : null,
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 56),
            child: TextButton(
              onPressed: enabled ? onTapValue : null,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(48, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(valueLabel, textAlign: TextAlign.center),
                  const SizedBox(width: 4),
                  // the value opens the exact input dialog: the pencil makes
                  // that discoverable without adding a "custom" button per row
                  Icon(Icons.edit, size: 13, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_circle_outline, size: 22),
            onPressed: canIncrease ? () => onChanged(_stepped(1)) : null,
          ),
        ],
      ),
    );
  }
}

// chips wrap instead of scrolling sideways, so every option stays reachable
Widget cloudOptionChips(BuildContext context, List<Widget> chips) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Wrap(spacing: 8, runSpacing: 8, children: chips),
  );
}

// a labelled group of chips (a field of the option sheet)
Widget cloudOptionField(BuildContext context, {required String label, required List<Widget> chips}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ),
      cloudOptionChips(context, chips),
    ],
  );
}

// ---- shared numeric options ----

// "3x" / "3.5x", "3s" / "3.5s": one decimal only when the value is not whole,
// so both option sheets and their summaries format values the same way
String cloudFormatNumber(double value) => (value - value.roundToDouble()).abs() < 0.01 ? '${value.toInt()}' : value.toStringAsFixed(1);

String cloudFormatFactor(double value) => '${cloudFormatNumber(value)}x';

String cloudFormatInterval(double value) => '${cloudFormatNumber(value)}s';

// Shared editor for the numeric auto-browse options. The accepted range comes
// from the caller (which takes it from `CloudSettings`), so a value accepted
// here always reads back unchanged.
Future<double?> showCloudNumberDialog(
  BuildContext context, {
  required String title,
  required String suffix,
  required num initial,
  required num min,
  required num max,
  required String hint,
  bool decimal = true,
  bool minExclusive = false,
}) async {
  final initialText = decimal
      ? ((initial - initial.round()).abs() < 0.01 ? initial.toInt().toString() : initial.toStringAsFixed(1))
      : initial.round().toString();
  final l10n = context.l10n;
  // a local field rather than a controller: a controller would have to outlive
  // the dialog's closing animation to be disposed safely
  var text = initialText;
  var invalid = false;
  return showDialog<double>(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (dialogCtx, setState) {
        void submit() {
          final value = double.tryParse(text.trim());
          final inRange = value != null && (minExclusive ? value > min : value >= min) && value <= max;
          if (!inRange) {
            setState(() => invalid = true);
            return;
          }
          Navigator.pop(dialogCtx, value);
        }

        return AlertDialog(
          title: Text(title),
          content: TextFormField(
            initialValue: initialText,
            autofocus: true,
            keyboardType: TextInputType.numberWithOptions(decimal: decimal),
            decoration: InputDecoration(
              suffixText: suffix,
              hintText: hint,
              errorText: invalid ? l10n.cloudNumberInvalidRange(min.toString(), max.toString()) : null,
            ),
            onChanged: (value) {
              text = value;
              if (invalid) setState(() => invalid = false);
            },
            onFieldSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogCtx), child: Text(MaterialLocalizations.of(dialogCtx).cancelButtonLabel)),
            TextButton(onPressed: submit, child: Text(MaterialLocalizations.of(dialogCtx).okButtonLabel)),
          ],
        );
      },
    ),
  );
}
