import 'dart:async';

import 'package:purer/model/settings/settings.dart';
import 'package:purer/utils/file_utils.dart';
import 'package:purer/widgets/common/extensions/build_context.dart';
import 'package:material_ui/material_ui.dart';

typedef CloudTransferProgress = void Function(int done, int total);

// Runs a remote transfer (save to phone / share) behind a modal progress
// dialog. Saving reports the downloaded bytes and shows a determinate bar;
// sharing shows an indeterminate one until the chooser opens.
//
// The cancel button (and the system back gesture) stops the platform transfer
// and returns `null`, so the caller can tell a cancellation from a failure.
Future<bool?> runCloudTransfer(
  BuildContext context, {
  required String title,
  required Future<bool?> Function(String transferId, CloudTransferProgress onProgress) run,
  required Future<void> Function(String transferId) cancel,
}) async {
  final l10n = context.l10n;
  final progress = ValueNotifier<(int, int)?>(null);
  final transferId = 'transfer-${DateTime.now().microsecondsSinceEpoch}';
  var cancelled = false;
  BuildContext? dialogContext;

  void requestCancel() {
    if (cancelled) return;
    cancelled = true;
    unawaited(cancel(transferId));
  }

  Widget buildDialog(BuildContext ctx) {
    return PopScope(
      // back must cancel the transfer, not hide the dialog while it keeps going
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        requestCancel();
        Navigator.of(ctx).pop();
      },
      child: AlertDialog(
        title: Text(title),
        content: ValueListenableBuilder<(int, int)?>(
          valueListenable: progress,
          builder: (context, value, child) {
            final total = value?.$2 ?? -1;
            final done = value?.$1 ?? 0;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: total > 0 ? (done / total).clamp(0.0, 1.0) : null),
                const SizedBox(height: 12),
                Text(
                  total > 0
                      ? l10n.cloudTransferDownloading(
                          formatFileSize(settings.purerLocale, done, round: 0),
                          formatFileSize(settings.purerLocale, total, round: 0),
                        )
                      : l10n.cloudTransferPreparing,
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              requestCancel();
              Navigator.of(ctx).pop();
            },
            child: Text(l10n.cancelTooltip),
          ),
        ],
      ),
    );
  }

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogContext = ctx;
        return buildDialog(ctx);
      },
    ),
  );
  // let the dialog build before a very fast transfer finishes
  await WidgetsBinding.instance.endOfFrame;
  try {
    final result = await run(transferId, (done, total) => progress.value = (done, total));
    return cancelled ? null : result;
  } catch (_) {
    return cancelled ? null : false;
  } finally {
    final ctx = dialogContext;
    if (ctx != null && ctx.mounted) Navigator.of(ctx).pop();
    // the route may still be animating out when this returns
    Future<void>.delayed(const Duration(milliseconds: 400), progress.dispose);
  }
}
