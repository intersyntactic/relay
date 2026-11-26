import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:is_docking_station_api/is_docking_station_api.dart';
import 'package:is_logbook_client/is_logbook_client.dart';
import 'package:is_relay/is_relay.dart';
import 'package:test/test.dart';

/// A source whose header check wants `x-test-key: good` and whose body check
/// refuses a body of `refuse`.
final class _TestCheck implements ChecksDeliveries<String> {
  final seenBodies = <Uint8List>[];
  String reason = 'bad key';

  @override
  RelayedEventSource get source => RelayedEventSource.parse('test')!;

  /// A key of `throw` makes the header check throw, as a source parser that
  /// throws `FormatException` on a malformed header would.
  @override
  HeaderCheck<String> checkHeaders(DeliveryHeaders headers, DateTime now) =>
      switch (headers['X-Test-Key']) {
        'good' => const HeadersVouch('good'),
        'throw' => throw const FormatException('bad header'),
        _ => HeadersRefused(RefusalStatus.unauthorized, reason),
      };

  @override
  BodyVerdict checkBody(String vouched, Uint8List body) {
    seenBodies.add(body);
    return utf8.decode(body) == 'refuse'
        ? const Refuse(RefusalStatus.forbidden, 'refused body')
        : Record(response: JsonObject.of({'ok': vouched}));
  }
}

/// A source that projects: the same header check as [_TestCheck], and a body
/// check that keeps only a JSON body's `text`, so its `token` is never
/// recorded. A body of `refuse` is refused and `throw` makes it throw.
final class _ProjectingCheck implements ChecksAndProjectsDeliveries<String> {
  final seenBodies = <Uint8List>[];

  @override
  RelayedEventSource get source => RelayedEventSource.parse('test')!;

  @override
  HeaderCheck<String> checkHeaders(DeliveryHeaders headers, DateTime now) =>
      headers['X-Test-Key'] == 'good'
      ? const HeadersVouch('good')
      : const HeadersRefused(RefusalStatus.unauthorized, 'bad key');

  @override
  ProjectedVerdict checkBody(String vouched, Uint8List body) {
    seenBodies.add(body);
    final text = utf8.decode(body);
    if (text == 'refuse') {
      return const Refuse(RefusalStatus.forbidden, 'refused body');
    }
    if (text == 'throw') throw const FormatException('unreadable');
    final activity = JsonObject.parse(jsonDecode(text))!;
    return RecordProjection(
      JsonObject.of({'projection': 1, 'text': activity.string('text')}),
      response: JsonObject.of({'ok': vouched}),
    );
  }
}

/// How the fake logbook answers a write.
enum _Answer { ok, duplicate, refusedKind, failed, notTip, silent }

/// A logbook write service on a Unix socket, speaking its wire protocol:
/// the request `<kind>\n<previous>\n<body>` to the end of the stream, then
/// one line back naming the request's hash.
final class _FakeLogbook {
  _FakeLogbook._(this._server, this.socket, this._dir);

  static Future<_FakeLogbook> start() async {
    final dir = await Directory.systemTemp.createTemp('relay');
    final path = '${dir.path}/w.sock';
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final logbook = _FakeLogbook._(server, LogbookSocket.parse(path)!, dir);
    server.listen(logbook._serve);
    return logbook;
  }

  final ServerSocket _server;
  final Directory _dir;
  final LogbookSocket socket;
  final _open = <Socket>[];

  _Answer answer = _Answer.ok;

  /// Each request, in full, as it arrived.
  final requests = <Uint8List>[];

  /// Completes when the first request has arrived.
  final called = Completer<void>();

  /// While set, no answer is sent until it completes.
  Completer<void>? hold;

  Future<void> _serve(Socket s) async {
    _open.add(s);
    final b = BytesBuilder();
    try {
      await s.forEach(b.add);
    } on SocketException {
      return;
    }
    final request = b.takeBytes();
    requests.add(request);
    if (!called.isCompleted) called.complete();
    await hold?.future;
    final id = ObjectId.of(request).hex;
    final line = switch (answer) {
      _Answer.ok => 'ok $id',
      _Answer.duplicate => 'refused duplicate $id',
      _Answer.refusedKind => 'refused kind not allowed',
      _Answer.failed => 'failed disk',
      _Answer.notTip => 'refused not-tip ${ObjectId.of(Uint8List(2)).hex}',
      _Answer.silent => null,
    };
    if (line == null) return;
    try {
      s.write('$line\n');
      await s.close();
    } on SocketException {
      // The relay gave up and destroyed its end.
    }
  }

  /// The entry's kind and body, read back from [request].
  static (Kind, Uint8List) parse(Uint8List request) {
    final first = request.indexOf(0x0a);
    final second = request.indexOf(0x0a, first + 1);
    return (
      Kind.parse(utf8.decode(request.sublist(0, first)))!,
      Uint8List.sublistView(request, second + 1),
    );
  }

  bool _stopped = false;

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    for (final s in _open) {
      s.destroy();
    }
    await _server.close();
    await _dir.delete(recursive: true);
  }
}

void main() {
  late HttpServer server;
  late _TestCheck check;
  late _ProjectingCheck projector;
  late _FakeLogbook logbook;
  late List<String> logged;
  late Uri url;
  var started = false;

  Future<void> start({
    Duration budget = const Duration(seconds: 2),
    int burst = 100,
    int maxBodyBytes = 1024,
    int maxInFlight = 8,
    bool projecting = false,
  }) async {
    started = true;
    check = _TestCheck();
    projector = _ProjectingCheck();
    logbook = await _FakeLogbook.start();
    logged = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = Uri.parse('http://127.0.0.1:${server.port}/in');
    final relayPath = RelayPath.parse('/in')!;
    final rate = WriteRateBound(perMinute: 1, burst: burst);
    unawaited(
      (projecting
              ? RelayServer.projecting(
                  check: projector,
                  logbook: logbook.socket,
                  path: relayPath,
                  budget: budget,
                  rate: rate,
                  maxBodyBytes: maxBodyBytes,
                  maxInFlight: maxInFlight,
                  log: logged.add,
                )
              : RelayServer(
                  check: check,
                  logbook: logbook.socket,
                  path: relayPath,
                  budget: budget,
                  rate: rate,
                  maxBodyBytes: maxBodyBytes,
                  maxInFlight: maxInFlight,
                  log: logged.add,
                ))
          .serve(server),
    );
  }

  tearDown(() async {
    if (!started) return;
    started = false;
    await server.close(force: true);
    await logbook.stop();
  });

  Future<(int, String)> post(String body) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(url);
      req.headers.set('x-test-key', 'good');
      req.write(body);
      final res = await req.close();
      return (res.statusCode, await utf8.decodeStream(res));
    } finally {
      client.close(force: true);
    }
  }

  /// The status a refusal sent unread carries, read off a raw socket: the
  /// relay drops the connection after it, which an HttpClient still writing
  /// can report as a broken pipe instead of a status.
  Future<int> rawStatus({
    String method = 'POST',
    String path = '/in',
    String key = 'good',
    String body = 'x',
    int? declaredLength,
  }) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    socket.write(
      '$method $path HTTP/1.1\r\nhost: x\r\nx-test-key: $key\r\n'
      'connection: close\r\n'
      'content-length: ${declaredLength ?? body.length}\r\n\r\n$body',
    );
    // Read to the end; a reset after the status line (the relay destroys the
    // socket with the body unread) ends the read like a close.
    final received = BytesBuilder();
    final done = Completer<void>();
    socket.listen(
      received.add,
      onDone: done.complete,
      onError: (Object _) {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    await done.future;
    socket.destroy();
    return int.parse(utf8.decode(received.takeBytes()).split(' ')[1]);
  }

  group('records, then answers', () {
    setUp(start);

    test(
      'an authentic delivery is written, then 200 with its response',
      () async {
        final (status, body) = await post('hello');
        expect(status, 200);
        expect(jsonDecode(body), {'ok': 'good'});
        final (kind, entry) = _FakeLogbook.parse(logbook.requests.single);
        expect(kind.name, 'test-event');
        final event = RelayedEvent.read(ObjectId.of(Uint8List(1)), kind, entry);
        expect(utf8.decode(event!.bytes), 'hello');
      },
    );

    test('already recorded is also a 200', () async {
      logbook.answer = _Answer.duplicate;
      expect((await post('again')).$1, 200);
    });

    for (final answer in [
      _Answer.failed,
      _Answer.refusedKind,
      _Answer.notTip,
    ]) {
      test('a write answered ${answer.name} is a 503, no body', () async {
        logbook.answer = answer;
        expect(await post('x'), (503, ''));
      });
    }

    test('no logbook listening is a 503', () async {
      await File(logbook.socket.path).delete();
      expect((await post('x')).$1, 503);
    });

    test('the check sees a body it cannot write to', () async {
      await post('hello');
      expect(() => check.seenBodies.single[0] = 0, throwsUnsupportedError);
    });

    test('a duplicate is written again: no seen set', () async {
      await post('same');
      await post('same');
      expect(logbook.requests, hasLength(2));
    });
  });

  group('refuses without writing', () {
    setUp(start);

    test('a header refusal answers its status and writes nothing', () async {
      expect(await rawStatus(key: 'bad'), 401);
      expect(logbook.requests, isEmpty);
      expect(check.seenBodies, isEmpty);
      expect(logged.single, contains('401 bad key'));
    });

    test('a body refusal answers its status and writes nothing', () async {
      expect(await rawStatus(body: 'refuse'), 403);
      expect(logbook.requests, isEmpty);
    });

    test('another path is 404', () async {
      expect(await rawStatus(path: '/else'), 404);
    });

    test('another method is 405', () async {
      expect(await rawStatus(method: 'PUT'), 405);
    });

    test('a declared length over the cap is 413', () async {
      expect(await rawStatus(body: 'x' * 2000), 413);
      expect(logbook.requests, isEmpty);
    });

    test(
      'a header check that throws is a 500, sent without the body',
      () async {
        // Declares 10 bytes and sends none: an answer that waited on the body
        // would never come.
        expect(
          await rawStatus(key: 'throw', body: '', declaredLength: 10),
          500,
        );
        expect(logbook.requests, isEmpty);
      },
    );

    test('a sender gone mid-body leaves the relay serving', () async {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      socket.write(
        'POST /in HTTP/1.1\r\nhost: x\r\nx-test-key: good\r\n'
        'content-length: 10\r\n\r\nab',
      );
      await socket.flush();
      socket.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect((await post('after')).$1, 200);
      expect(logbook.requests, hasLength(1));
    });
  });

  group('the write-rate bound', () {
    test('refuses past the burst with 429', () async {
      await start(burst: 1);
      expect((await post('one')).$1, 200);
      expect((await post('two')).$1, 429);
      expect(logbook.requests, hasLength(1));
    });

    test('is not spent by deliveries that fail the check', () async {
      await start(burst: 1);
      await rawStatus(key: 'bad');
      await rawStatus(body: 'refuse');
      expect((await post('one')).$1, 200);
    });

    test('is given back when the write certainly did not record', () async {
      await start(burst: 1);
      logbook.answer = _Answer.refusedKind;
      expect((await post('one')).$1, 503);
      logbook.answer = _Answer.ok;
      expect((await post('one')).$1, 200);
    });

    test('stays spent when the write failed partway: it may be in', () async {
      await start(burst: 1);
      logbook.answer = _Answer.failed;
      expect((await post('one')).$1, 503);
      logbook.answer = _Answer.ok;
      expect((await post('two')).$1, 429);
    });

    test('stays spent when the write went unanswered', () async {
      await start(budget: const Duration(milliseconds: 300), burst: 1);
      logbook.answer = _Answer.silent;
      expect((await post('one')).$1, 503);
      logbook.answer = _Answer.ok;
      expect((await post('two')).$1, 429);
    });

    test('refills by elapsed time, not the wall clock', () {
      var elapsed = Duration.zero;
      final bound = WriteRateBound(
        perMinute: 60,
        burst: 1,
        elapsed: () => elapsed,
      );
      expect(bound.take(), isTrue);
      expect(bound.take(), isFalse);
      elapsed += const Duration(seconds: 1);
      expect(bound.take(), isTrue);
    });
  });

  test('a reason cannot start a log line of its own', () async {
    await start();
    check.reason = 'tenant a\nforged line';
    await rawStatus(key: 'bad');
    expect(logged.single, isNot(contains('\n')));
    expect(logged.single, contains(r'tenant a\x0aforged line'));
  });

  test('a path is a slash and no whitespace or query', () {
    expect(RelayPath.parse('/api/messages')?.value, '/api/messages');
    expect(RelayPath.parse('api'), isNull);
    expect(RelayPath.parse('/a b'), isNull);
    expect(RelayPath.parse('/a?b'), isNull);
  });

  test('a logbook socket is an absolute path', () {
    expect(
      LogbookSocket.parse('/run/logbook/write.sock')?.path,
      '/run/logbook/write.sock',
    );
    expect(LogbookSocket.parse('write.sock'), isNull);
  });

  group('the budget', () {
    test('a logbook that never answers is a 503, in time', () async {
      await start(budget: const Duration(milliseconds: 300));
      logbook.answer = _Answer.silent;
      final clock = Stopwatch()..start();
      expect((await post('slow')).$1, 503);
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a body trickled past the budget is refused', () async {
      await start(budget: const Duration(milliseconds: 300));
      expect(await rawStatus(body: 'ab', declaredLength: 10), 408);
      expect(logbook.requests, isEmpty);
    });

    test('nothing a request starts holds its place past the budget', () async {
      await start(budget: const Duration(milliseconds: 300), maxInFlight: 1);
      logbook.answer = _Answer.silent;
      expect((await post('slow')).$1, 503);
      // The silent write ended with the budget, so the place is free.
      logbook.answer = _Answer.ok;
      expect((await post('after')).$1, 200);
    });
  });

  group('a projecting relay', () {
    setUp(() => start(projecting: true));

    const withToken = '{"text":"hi","token":"SECRET-AAD-JWT"}';

    test('records the projection, not the body, then 200', () async {
      final (status, body) = await post(withToken);
      expect(status, 200);
      expect(jsonDecode(body), {'ok': 'good'});
      final (kind, entry) = _FakeLogbook.parse(logbook.requests.single);
      expect(kind.name, 'test-event');
      final event = RelayedEvent.read(ObjectId.of(Uint8List(1)), kind, entry);
      expect(jsonDecode(utf8.decode(event!.bytes)), {
        'projection': 1,
        'text': 'hi',
      });
    });

    test('a field the projection leaves out is not recorded', () async {
      await post(withToken);
      final request = logbook.requests.single;
      final (kind, entry) = _FakeLogbook.parse(request);
      final event = RelayedEvent.read(ObjectId.of(Uint8List(1)), kind, entry);
      // The entry holds the recorded bytes base64-encoded, so look in both
      // the decoded bytes and the request as sent.
      expect(utf8.decode(event!.bytes), isNot(contains('SECRET')));
      expect(
        utf8.decode(request, allowMalformed: true),
        isNot(contains('SECRET')),
      );
    });

    test('the same delivery projects to the same bytes', () async {
      await post(withToken);
      await post(withToken);
      final [first, second] = [
        for (final r in logbook.requests)
          RelayedEvent.read(
            ObjectId.of(Uint8List(1)),
            _FakeLogbook.parse(r).$1,
            _FakeLogbook.parse(r).$2,
          )!.bytes,
      ];
      expect(first, second);
    });

    test('a refusal is answered and nothing is written', () async {
      expect((await post('refuse')).$1, 403);
      expect(logbook.requests, isEmpty);
    });

    test('a check that throws is a 500, nothing written', () async {
      expect((await post('throw')).$1, 500);
      expect(logbook.requests, isEmpty);
    });

    test('the check sees a body it cannot write to', () async {
      await post(withToken);
      expect(() => projector.seenBodies.single[0] = 0, throwsUnsupportedError);
    });

    test('no 2xx without the write: a failed write is a 503', () async {
      logbook.answer = _Answer.failed;
      expect(await post(withToken), (503, ''));
    });
  });

  test('the in-flight cap counts a request until it is answered', () async {
    await start(maxInFlight: 1);
    logbook.hold = Completer();
    final first = post('first');
    await logbook.called.future;
    expect(await rawStatus(), 503);
    expect(logged.last, contains('busy'));
    logbook.hold!.complete();
    expect((await first).$1, 200);
    expect((await post('third')).$1, 200);
  });
}
