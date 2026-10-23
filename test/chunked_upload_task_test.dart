import 'dart:async';
import 'dart:io';

import 'package:filebrowser_mobile/src/api/filebrowser_client.dart';
import 'package:filebrowser_mobile/src/transfers/chunked_upload_task.dart';
import 'package:filebrowser_mobile/src/transfers/transfer_record.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mock_adapter.dart';

// A JWT-shaped token whose payload decodes; the client only reads exp/perms.
const _jwt =
    'eyJhbGciOiJIUzI1NiJ9.'
    'eyJleHAiOjk5OTk5OTk5OTksInVzZXJuYW1lIjoidCJ9.'
    'sig';

FileBrowserClient _client(MockAdapter adapter) {
  final c = FileBrowserClient(baseUrl: 'https://s.example', adapter: adapter);
  c.adoptToken(_jwt);
  c.setSource('files');
  return c;
}

/// Writes [bytes] to a temp file the task can read; cleaned up by addTearDown.
Future<String> _tempFile(List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp('chunked_test');
  addTearDown(() => dir.delete(recursive: true));
  final f = File('${dir.path}/big.bin');
  await f.writeAsBytes(bytes);
  return f.path;
}

ChunkedUploadTask _task(
  FileBrowserClient client,
  String localPath, {
  int chunkSize = 10,
  bool override = false,
  int maxAttempts = 3,
}) =>
    ChunkedUploadTask(
      client: client,
      remotePath: '/dest/big.bin',
      localFilePath: localPath,
      id: 'c1',
      override: override,
      chunkSize: chunkSize,
      maxAttempts: maxAttempts,
      retryBaseDelay: const Duration(milliseconds: 1),
    );

void main() {
  test('uploads sequential chunks with offset/total headers and completes',
      () async {
    final adapter = MockAdapter((_) => MockAdapter.json({}));
    final client = _client(adapter);
    final path = await _tempFile(List.generate(25, (i) => i));

    final task = _task(client, path, chunkSize: 10);
    final statuses = <TransferStatus>[];
    final sub = task.updates.listen((r) => statuses.add(r.status));
    await task.start();
    await sub.cancel();

    expect(adapter.requests, hasLength(3));
    expect(adapter.requests.map((r) => r.headers['X-File-Upload-Session']).toSet(),
        {'c1'});
    for (final (i, expected) in const [(0, 10), (10, 10), (20, 5)].indexed) {
      final req = adapter.requests[i];
      expect(req.headers['X-File-Chunk-Offset'], '${expected.$1}');
      expect(req.headers['X-File-Total-Size'], '25');
      expect(req.uri.queryParameters['path'], '/dest/big.bin');
      expect(req.uri.queryParameters['source'], 'files');
      expect(adapter.bodies[i], hasLength(expected.$2));
    }
    // Chunk bodies carry the right slices.
    expect(adapter.bodies[1].first, 10);
    expect(adapter.bodies[2].last, 24);
    expect(statuses.last, TransferStatus.complete);
    expect(task.snapshot.progress, 1.0);
  });

  test('a 409 conflict fails immediately without retrying', () async {
    final adapter = MockAdapter((_) => MockAdapter.json({}, status: 409));
    final client = _client(adapter);
    final path = await _tempFile(List.filled(15, 1));

    final task = _task(client, path, chunkSize: 10);
    await task.start();

    expect(adapter.requests, hasLength(1)); // no second attempt
    expect(task.snapshot.status, TransferStatus.failed);
    expect(task.snapshot.errorMessage, 'HTTP 409');
  });

  test('a transient 500 restarts from offset 0 and then succeeds', () async {
    var calls = 0;
    final adapter = MockAdapter((_) {
      calls++;
      // Fail the second chunk of the first attempt; succeed afterwards.
      return calls == 2 ? MockAdapter.json({}, status: 500) : MockAdapter.json({});
    });
    final client = _client(adapter);
    final path = await _tempFile(List.filled(15, 7));

    final task = _task(client, path, chunkSize: 10);
    final statuses = <TransferStatus>[];
    final sub = task.updates.listen((r) => statuses.add(r.status));
    await task.start();
    await sub.cancel();

    // Attempt 1: offsets 0, 10 (fails). Attempt 2: offsets 0, 10.
    final offsets = adapter.requests
        .map((r) => r.headers['X-File-Chunk-Offset'])
        .toList();
    expect(offsets, ['0', '10', '0', '10']);
    expect(statuses, contains(TransferStatus.retrying));
    expect(task.snapshot.status, TransferStatus.complete);
  });

  test('exhausting maxAttempts settles to failed', () async {
    final adapter = MockAdapter((_) => MockAdapter.json({}, status: 500));
    final client = _client(adapter);
    final path = await _tempFile(List.filled(15, 7));

    final task = _task(client, path, chunkSize: 10, maxAttempts: 3);
    await task.start();

    // 3 attempts, each dying on its first chunk.
    expect(adapter.requests, hasLength(3));
    expect(task.snapshot.status, TransferStatus.failed);
  });

  test('pause between chunks parks the task; resume continues from offset',
      () async {
    final adapter = MockAdapter((_) => MockAdapter.json({}));
    final client = _client(adapter);
    final path = await _tempFile(List.filled(30, 3));

    final task = _task(client, path, chunkSize: 10);
    // Pause as soon as the first chunk is committed.
    Future<void>? pauseFuture;
    late StreamSubscription<ChunkedUploadRecord> sub;
    sub = task.updates.listen((r) {
      if (pauseFuture == null &&
          r.status == TransferStatus.running &&
          r.progress > 0) {
        pauseFuture = task.pause();
        unawaited(sub.cancel());
      }
    });
    await task.start();
    await pauseFuture;

    expect(task.snapshot.status, TransferStatus.paused);
    final sentBeforeResume = adapter.requests
        .where((r) => r.headers.containsKey('X-File-Chunk-Offset'))
        .length;
    expect(sentBeforeResume, lessThan(3));
    // The graceful-pause signal went out.
    expect(
        adapter.requests.any((r) => r.path.contains('/resources/pause')), isTrue);

    await task.resume();
    expect(task.snapshot.status, TransferStatus.complete);
    final offsets = adapter.requests
        .where((r) => r.headers.containsKey('X-File-Chunk-Offset'))
        .map((r) => r.headers['X-File-Chunk-Offset'])
        .toList();
    expect(offsets, ['0', '10', '20']); // no chunk repeated, none skipped
    expect(adapter.requests.where((r) => r.headers.containsKey('X-File-Chunk-Offset'))
        .map((r) => r.headers['X-File-Upload-Session']).toSet(), {'c1'});
  });

  test('source selection changes do not redirect an upload', () async {
    final adapter = MockAdapter((_) => MockAdapter.json({}));
    final client = _client(adapter);
    final path = await _tempFile(List.filled(25, 3));
    final task = _task(client, path);
    client.setSource('another-source');
    await task.start();
    expect(adapter.requests.every((r) => r.uri.queryParameters['source'] == 'files'),
        isTrue);
  });

  test('a failed pause signal restarts safely with the same session', () async {
    final adapter = MockAdapter((r) => r.path.endsWith('/pause')
        ? MockAdapter.json({}, status: 503)
        : MockAdapter.json({}));
    final task = _task(_client(adapter), await _tempFile(List.filled(30, 3)));
    Future<void>? pause;
    final sub = task.updates.listen((r) {
      if (pause == null && r.status == TransferStatus.running && r.progress > 0) {
        pause = task.pause();
      }
    });
    await task.start();
    await pause;
    await sub.cancel();
    expect(task.snapshot.status, TransferStatus.paused);
    final before = adapter.requests.length;
    await task.resume();
    expect(adapter.requests[before].headers['X-File-Chunk-Offset'], '0');
    expect(adapter.requests[before].headers['X-File-Upload-Session'], 'c1');
    expect(task.snapshot.status, TransferStatus.complete);
  });

  test('a file truncated mid-upload fails rather than looping forever', () async {
    final path = await _tempFile(List.filled(25, 3));
    final adapter = MockAdapter((_) {
      File(path).writeAsBytesSync([1, 2]);
      return MockAdapter.json({});
    });
    final task = _task(_client(adapter), path);
    await task.start();
    expect(task.snapshot.status, TransferStatus.failed);
    expect(task.snapshot.errorMessage, contains('changed'));
    expect(adapter.requests, hasLength(1));
  });

  test('cancel settles to canceled and stops sending', () async {
    final adapter = MockAdapter((_) => MockAdapter.json({}));
    final client = _client(adapter);
    final path = await _tempFile(List.filled(30, 3));

    final task = _task(client, path, chunkSize: 10);
    late StreamSubscription<ChunkedUploadRecord> sub;
    sub = task.updates.listen((r) {
      if (r.status == TransferStatus.running && r.progress > 0) {
        task.cancel();
        unawaited(sub.cancel());
      }
    });
    await task.start();

    expect(task.snapshot.status, TransferStatus.canceled);
    expect(task.snapshot.canRetry, isTrue);
    expect(adapter.requests.length, lessThan(3));
  });

  test('a vanished local file fails cleanly', () async {
    final adapter = MockAdapter((_) => MockAdapter.json({}));
    final client = _client(adapter);

    final task = _task(client, '/nonexistent/nope.bin');
    await task.start();

    expect(task.snapshot.status, TransferStatus.failed);
    expect(adapter.requests, isEmpty);
  });

  test('override is carried on every chunk', () async {
    final adapter = MockAdapter((_) => MockAdapter.json({}));
    final client = _client(adapter);
    final path = await _tempFile(List.filled(15, 1));

    final task = _task(client, path, chunkSize: 10, override: true);
    await task.start();

    for (final req in adapter.requests) {
      expect(req.uri.queryParameters['override'], 'true');
    }
  });
}
