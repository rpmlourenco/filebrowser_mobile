import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../api/filebrowser_client.dart';
import 'transfer_record.dart';

/// Chunk size for chunked uploads, matching the server-side default
/// (`userDefaults.fileLoading.uploadChunkSizeMb` = 10). Files at or below this
/// size go out as a single background POST instead (see [TransferService]).
const int defaultUploadChunkSize = 10 * 1024 * 1024;

/// One resumable upload, driven chunk-by-chunk through
/// [FileBrowserClient.uploadChunk] (quantum's offset-header scheme).
///
/// State machine, mirroring what the protocol allows (verified against
/// v1.4.0-stable — see [FileBrowserClient.uploadChunk]):
///
///  - Chunks are sent sequentially; `_committed` advances only after a chunk
///    is acknowledged, so progress is exact.
///  - A transient failure (transport error / 5xx) destroys the server's temp
///    file, so the automatic retry **restarts from offset 0** after a backoff
///    (status `retrying`), up to [maxAttempts] tries overall.
///  - A permanent failure (any 4xx, e.g. the offset-0 conflict 409) fails
///    immediately — retrying cannot fix it.
///  - [pause] is graceful: it signals `/api/resources/pause` (the server then
///    truncates to the committed offset and keeps its temp file) and aborts
///    the in-flight chunk; [resume] continues from `_committed`.
///  - [cancel] aborts the in-flight chunk. Server cleanup of abandoned
///    partial uploads depends on the Quantum version.
///
/// The task reports itself as a stream of immutable [ChunkedUploadRecord]
/// snapshots; [TransferService] folds those into the unified transfers list.
/// Auth is the client's concern: its interceptor renews the token on 401 and
/// replays, so multi-hour uploads survive token expiry without help here.
class ChunkedUploadTask {
  ChunkedUploadTask({
    required FileBrowserClient client,
    required this.remotePath,
    required this.localFilePath,
    required String id,
    this.override = false,
    this.chunkSize = defaultUploadChunkSize,
    this.maxAttempts = 5,
    this.retryBaseDelay = const Duration(seconds: 2),
  })  : _client = client,
        _source = client.source,
        _id = id,
        assert(chunkSize > 0),
        assert(maxAttempts > 0);

  final FileBrowserClient _client;
  final String? _source;
  final String remotePath;
  final String localFilePath;
  final bool override;
  final int chunkSize;

  /// Total tries per upload (first attempt + automatic restarts).
  final int maxAttempts;

  /// Backoff before automatic restart `n` is `retryBaseDelay * n`.
  final Duration retryBaseDelay;

  final String _id;

  final _controller = StreamController<ChunkedUploadRecord>.broadcast();

  TransferStatus _status = TransferStatus.enqueued;
  int _total = -1;
  int _committed = 0;
  int _attempts = 0;
  CancelToken? _inflight;
  bool _pauseRequested = false;
  bool _cancelRequested = false;
  String? _error;
  bool _restartOnResume = false;

  /// Live snapshots; the current one is always available via [snapshot].
  Stream<ChunkedUploadRecord> get updates => _controller.stream;

  ChunkedUploadRecord get snapshot => _snapshot(_progress());

  /// Starts (or, after a failure/cancel, restarts from scratch) the upload.
  /// Returns when the upload reaches a final state *or* pauses; a paused
  /// upload is continued with [resume].
  Future<void> start() async {
    if (_status == TransferStatus.running ||
        _status == TransferStatus.retrying ||
        _status == TransferStatus.paused) {
      return;
    }
    _status = TransferStatus.running;
    _committed = 0;
    _attempts = 0;
    _pauseRequested = false;
    _cancelRequested = false;
    _error = null;
    _restartOnResume = false;
    try {
      _total = await File(localFilePath).length();
    } on IOException {
      _error = 'Local file could not be read.';
      _settle(TransferStatus.failed);
      return;
    }
    if (_cancelRequested) return;
    _emit(_progress());
    await _run();
  }

  /// Continues a paused upload from the committed offset (the graceful pause
  /// left the server's temp file truncated exactly there).
  Future<void> resume() async {
    if (_status != TransferStatus.paused) return;
    if (_restartOnResume) {
      _committed = 0;
      _restartOnResume = false;
    }
    _status = TransferStatus.running;
    _pauseRequested = false;
    _emit(_progress());
    await _run();
  }

  /// Gracefully pauses a running upload: signal the server first (so it
  /// preserves its temp file), then abort the in-flight chunk. Safe to call
  /// between chunks — the loop checks the flag before each send.
  Future<void> pause() async {
    if (_status != TransferStatus.running) return;
    _pauseRequested = true;
    try {
      await _client.pauseUpload(remotePath, sourceName: _source);
    } on DioException {
      // The signal is best-effort: without it an aborted chunk just costs a
      // restart from 0 on resume. Never continue from an unconfirmed offset.
      _restartOnResume = true;
    }
    _inflight?.cancel();
  }

  /// Cancels the upload and stops sending bytes.
  void cancel() {
    if (!_status.isActive) return;
    _cancelRequested = true;
    _inflight?.cancel();
    // Between chunks (or while paused) there is no in-flight request to abort;
    // settle immediately. Mid-chunk, the loop's error path settles instead.
    if (_status != TransferStatus.running || _inflight == null) {
      _settle(TransferStatus.canceled);
    }
  }

  Future<void> _run() async {
    RandomAccessFile? file;
    try {
      file = await File(localFilePath).open();
      while (_status == TransferStatus.running) {
        if (_cancelRequested) {
          _settle(TransferStatus.canceled);
          return;
        }
        if (_pauseRequested) {
          _pause();
          return;
        }
        if (_committed >= _total) {
          _settle(TransferStatus.complete);
          return;
        }
        final length = math.min(chunkSize, _total - _committed);
        await file.setPosition(_committed);
        final bytes = await file.read(length);
        if (bytes.length != length) {
          _error = 'Local file changed during upload. Please retry.';
          _settle(TransferStatus.failed);
          return;
        }
        final token = _inflight = CancelToken();
        try {
          await _client.uploadChunk(
            remotePath,
            offset: _committed,
            totalSize: _total,
            bytes: bytes,
            sessionId: _id,
            sourceName: _source,
            override: override,
            cancelToken: token,
            onSendProgress: (sent, _) => _emitThrottled(
                _total == 0 ? 1.0 : (_committed + sent) / _total),
          );
          _committed += bytes.length;
          _emit(_progress());
        } on DioException catch (e) {
          if (!await _handleChunkError(e)) return;
        } finally {
          _inflight = null;
        }
      }
    } on IOException {
      _error = 'Local file could not be read.';
      _settle(TransferStatus.failed);
    } finally {
      await file?.close();
    }
  }

  /// Decides what a failed chunk means. Returns true when the loop should
  /// keep going (after resetting for an automatic restart), false when the
  /// task has settled or paused.
  Future<bool> _handleChunkError(DioException e) async {
    if (_cancelRequested) {
      _settle(TransferStatus.canceled);
      return false;
    }
    if (_pauseRequested && e.type == DioExceptionType.cancel) {
      _pause();
      return false;
    }
    final code = e.response?.statusCode;
    final permanent = code != null && code >= 400 && code < 500;
    _attempts++;
    if (permanent || _attempts >= maxAttempts) {
      _error = code == null ? 'Network error. Please retry.' : 'HTTP $code';
      _settle(TransferStatus.failed);
      return false;
    }
    // Transient: the server discarded its temp file with the aborted chunk,
    // so restart from the beginning after a linear backoff.
    _status = TransferStatus.retrying;
    _committed = 0;
    _emit(0);
    await Future<void>.delayed(retryBaseDelay * _attempts);
    if (_cancelRequested) {
      _settle(TransferStatus.canceled);
      return false;
    }
    _status = TransferStatus.running;
    _emit(0);
    return true;
  }

  void _pause() {
    _status = TransferStatus.paused;
    _emit(_progress());
  }

  void _settle(TransferStatus status) {
    _status = status;
    _emit(status == TransferStatus.complete ? 1.0 : _progress());
  }

  double _progress() =>
      _total <= 0 ? 0 : (_committed / _total).clamp(0.0, 1.0);

  double _lastEmitted = -1;

  /// Intra-chunk progress arrives per network write; forward at most every
  /// 1% so the UI stream isn't flooded.
  void _emitThrottled(double progress) {
    if (progress - _lastEmitted >= 0.01) _emit(progress);
  }

  void _emit(double progress) {
    _lastEmitted = progress;
    if (!_controller.isClosed) _controller.add(_snapshot(progress));
  }

  ChunkedUploadRecord _snapshot(double progress) => ChunkedUploadRecord(
        id: _id,
        filename: p.basename(remotePath),
        status: _status,
        progress: progress,
        expectedFileSize: _total,
        errorMessage: _error,
      );

  void dispose() {
    cancel();
    _controller.close();
  }
}
