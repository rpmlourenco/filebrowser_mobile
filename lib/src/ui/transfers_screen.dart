import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../auth/auth_controller.dart';
import '../transfers/transfer_record.dart';
import '../transfers/transfer_service.dart';
import 'error_display.dart';

/// Live list of background transfers (uploads + downloads), driven by
/// [TransferService.records]. Each row shows the filename, a progress bar with
/// percentage, and the current state, plus the controls that apply to that
/// state: pause/resume (pausable downloads and chunked uploads), cancel, and
/// retry for a failed/canceled task.
///
/// Reached from the browser app bar's transfers icon (which badges the active
/// count). Retrying refreshes the session first ([AuthController.ensureFreshSession])
/// so a long-idle transfer re-enqueues with a current token.
class TransfersScreen extends StatelessWidget {
  const TransfersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final transfers = context.read<TransferService>();
    return Scaffold(
      appBar: AppBar(
        title: Text(loc.transfersTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: loc.transfersClearFinished,
            onPressed: transfers.clearFinished,
          ),
        ],
      ),
      body: StreamBuilder<List<TransferRecord>>(
        stream: transfers.records,
        initialData: transfers.current,
        builder: (context, snap) {
          final records = snap.data ?? const <TransferRecord>[];
          if (records.isEmpty) {
            return Center(child: Text(loc.transfersEmpty));
          }
          return ListView.separated(
            itemCount: records.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) =>
                _TransferTile(record: records[i], transfers: transfers),
          );
        },
      ),
    );
  }
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.record, required this.transfers});

  final TransferRecord record;
  final TransferService transfers;

  Future<void> _retry(BuildContext context) async {
    final auth = context.read<AuthController>();
    final messenger = ScaffoldMessenger.of(context);
    final loc = AppLocalizations.of(context);
    await auth.ensureFreshSession();
    final token = auth.client?.token;
    if (token == null) {
      showErrorSnackBar(messenger, loc.errorSessionExpiredRetry);
      return;
    }
    await transfers.retry(record, token: token);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final showBar = record.isActive && record.status != TransferStatus.enqueued;
    return ListTile(
      leading: Icon(record.isUpload ? Icons.upload : Icons.download),
      title: Text(record.filename, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          if (showBar)
            LinearProgressIndicator(
              value: record.progress > 0 ? record.progress : null,
              semanticsLabel: loc.transfersProgressSemantics,
              semanticsValue:
                  '${(record.progress.clamp(0, 1) * 100).round()}%',
            ),
          const SizedBox(height: 4),
          Text(transferStatusLabel(loc, record)),
          if (record.errorMessage != null)
            SelectableText(record.errorMessage!),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (record.canPause)
            IconButton(
              icon: const Icon(Icons.pause),
              tooltip: loc.actionPause,
              onPressed: () => transfers.pause(record),
            ),
          if (record.canResume)
            IconButton(
              icon: const Icon(Icons.play_arrow),
              tooltip: loc.actionResume,
              onPressed: () => transfers.resume(record),
            ),
          if (record.canRetry)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: loc.actionRetry,
              onPressed: () => _retry(context),
            ),
          if (record.canCancel)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: loc.actionCancel,
              onPressed: () => transfers.cancel(record),
            ),
        ],
      ),
    );
  }
}

/// Human-readable status line for a transfer row. Kept as a top-level function
/// (localizations passed in, no BuildContext) so it stays unit-testable via
/// `lookupAppLocalizations(const Locale('en'))`.
String transferStatusLabel(AppLocalizations loc, TransferRecord r) {
  final pct = (r.progress.clamp(0, 1) * 100).round();
  switch (r.status) {
    case TransferStatus.enqueued:
      return loc.transfersStatusQueued;
    case TransferStatus.running:
      return loc.transfersStatusTransferring(pct);
    case TransferStatus.paused:
      return loc.transfersStatusPaused(pct);
    case TransferStatus.retrying:
      return loc.transfersStatusRetrying;
    case TransferStatus.complete:
      return loc.transfersStatusComplete;
    case TransferStatus.failed:
      return loc.transfersStatusFailed;
    case TransferStatus.canceled:
      return loc.transfersStatusCanceled;
  }
}
