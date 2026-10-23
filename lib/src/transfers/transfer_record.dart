import 'package:background_downloader/background_downloader.dart';

/// Engine-independent state of a transfer, unifying `background_downloader`
/// tasks and the in-app chunked uploader so the transfers UI renders one list.
enum TransferStatus {
  /// Accepted but not yet moving bytes.
  enqueued,

  /// Actively moving bytes.
  running,

  /// Paused by the user; resumable.
  paused,

  /// A transient error occurred; the engine will retry by itself.
  retrying,

  /// Finished successfully.
  complete,

  /// Finished unsuccessfully (including a 404'd download); retryable by hand.
  failed,

  /// Canceled by the user; retryable by hand.
  canceled;

  /// True while the transfer may still change state — i.e. it counts toward
  /// the app-bar badge.
  bool get isActive => switch (this) {
        enqueued || running || paused || retrying => true,
        complete || failed || canceled => false,
      };
}

/// Maps `background_downloader`'s status onto the unified [TransferStatus].
TransferStatus transferStatusOf(TaskStatus status) => switch (status) {
      TaskStatus.enqueued => TransferStatus.enqueued,
      TaskStatus.running => TransferStatus.running,
      TaskStatus.paused => TransferStatus.paused,
      TaskStatus.waitingToRetry => TransferStatus.retrying,
      TaskStatus.complete => TransferStatus.complete,
      TaskStatus.failed || TaskStatus.notFound => TransferStatus.failed,
      TaskStatus.canceled => TransferStatus.canceled,
    };

/// An immutable snapshot of one tracked transfer.
///
/// Kept free of widgets so the update -> record mapping and the derived action
/// flags (pause/resume/cancel/retry, active) are unit-testable; the transfers
/// screen renders straight from these. The two concrete shapes are
/// [TaskTransferRecord] (native background tasks) and [ChunkedUploadRecord]
/// (the in-app chunked uploader); [TransferService] dispatches the actions by
/// type.
sealed class TransferRecord {
  const TransferRecord();

  String get id;
  String get filename;
  bool get isUpload;
  TransferStatus get status;

  /// Last known fraction in `0.0..1.0`. Engines never store their negative
  /// state sentinels here, so a failed transfer still shows how far it got.
  double get progress;

  /// Total size in bytes once known (`-1` until then).
  int get expectedFileSize;
  String? get errorMessage => null;

  bool get isActive => status.isActive;
  bool get isComplete => status == TransferStatus.complete;
  bool get isFailed => status == TransferStatus.failed;

  bool get canPause;
  bool get canResume => status == TransferStatus.paused;
  bool get canCancel => isActive;
  bool get canRetry => isFailed || status == TransferStatus.canceled;
}

/// Snapshot of a `background_downloader` task, folded from its [TaskUpdate]
/// stream (status changes and progress arrive as separate events, so the
/// record merges the latest of each — see [applyTaskUpdate]).
final class TaskTransferRecord extends TransferRecord {
  const TaskTransferRecord({
    required this.task,
    required this.taskStatus,
    required this.progress,
    this.expectedFileSize = -1,
  });

  /// The task as enqueued (retained so retry can re-enqueue it with a fresh
  /// token, and so pause/resume can pass the concrete [DownloadTask]).
  final Task task;

  /// The engine's own status; [status] is the unified view.
  final TaskStatus taskStatus;

  @override
  final double progress;
  @override
  final int expectedFileSize;

  @override
  String get id => task.taskId;
  @override
  String get filename => task.filename;
  @override
  bool get isUpload => task is UploadTask;
  @override
  TransferStatus get status => transferStatusOf(taskStatus);

  /// Pause is a download-only, opt-in capability in `background_downloader`
  /// (single-POST uploads can't pause); only offer it while the download is
  /// actively running.
  @override
  bool get canPause =>
      taskStatus == TaskStatus.running &&
      task is DownloadTask &&
      task.allowPause;
}

/// Snapshot of an in-app chunked upload (see `ChunkedUploadTask`), which can
/// pause/resume gracefully mid-file.
final class ChunkedUploadRecord extends TransferRecord {
  const ChunkedUploadRecord({
    required this.id,
    required this.filename,
    required this.status,
    required this.progress,
    required this.expectedFileSize,
    this.errorMessage,
  });

  @override
  final String id;
  @override
  final String filename;
  @override
  final TransferStatus status;
  @override
  final double progress;
  @override
  final int expectedFileSize;

  @override
  final String? errorMessage;

  @override
  bool get isUpload => true;
  @override
  bool get canPause => status == TransferStatus.running;
}

/// Folds a single [update] into the running [prev] record (or creates the first
/// one). PURE: status and progress updates arrive separately, so a status event
/// preserves the last progress and a progress event preserves the last status.
/// This is the seam the transfers UI and the active-count badge are built on.
TaskTransferRecord applyTaskUpdate(TaskTransferRecord? prev, TaskUpdate update) {
  final task = update.task;
  switch (update) {
    case TaskStatusUpdate(:final status):
      return TaskTransferRecord(
        task: task,
        taskStatus: status,
        progress: _foldProgress(status, prev?.progress ?? 0),
        expectedFileSize: prev?.expectedFileSize ?? -1,
      );
    case TaskProgressUpdate(:final progress, :final expectedFileSize):
      return TaskTransferRecord(
        task: task,
        taskStatus: prev?.taskStatus ?? TaskStatus.running,
        // Negative values are state sentinels (failed/canceled/…), not real
        // fractions — keep the last good one for display.
        progress: progress >= 0 ? progress : (prev?.progress ?? 0),
        expectedFileSize: expectedFileSize >= 0
            ? expectedFileSize
            : (prev?.expectedFileSize ?? -1),
      );
  }
}

/// A completed transfer is pinned to 1.0; otherwise the last real fraction is
/// preserved across a status change.
double _foldProgress(TaskStatus status, double previous) =>
    status == TaskStatus.complete ? 1.0 : previous;

/// Number of [records] still in flight — drives the app-bar badge. PURE.
int activeTransferCount(Iterable<TransferRecord> records) =>
    records.where((r) => r.isActive).length;
