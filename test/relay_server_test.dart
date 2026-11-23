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

  @override
  HeaderCheck<String> checkHeaders(DeliveryHeaders headers, DateTime now) =>
      headers['X-Test-Key'] == 'good'
      ? const HeadersVouch('good')
      : HeadersRefused(RefusalStatus.unauthorized, reason);

  @override
  BodyVerdict checkBody(String vouched, Uint8List body) {
    seenBodies.add(body);
    return utf8.decode(body) == 'refuse'
        ? const Refuse(RefusalStatus.forbidden, 'refused body')
        : Record(response: JsonObject.of({'ok': vouched}));
  }
}

final class _Write {
  final calls = <(Kind, List<int>, Duration)>[];
  WriteResult Function() answer = () => Written(ObjectId.of(Uint8List(1)));
  Completer<void>? hold;

  /// Completes when the first write arrives.
  final called = Completer<void>();

  Future<WriteResult> call(Kind kind, List<int> body, Duration timeout) async {
    calls.add((kind, body, timeout));
    if (!called.isCompleted) called.complete();
    await hold?.future;
    return answer();
  }
}

void main() {
  late HttpServer server;
  late _TestCheck check;
  late _Write write;
  late List<String> logged;
  late Uri url;

  Future<void> start({
    Duration budget = const Duration(seconds: 2),
    int burst = 100,
    int maxBodyBytes = 1024,
    int maxInFlight = 8,
  }) async {
    check = _TestCheck();
    write = _Write();
    logged = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = Uri.parse('http://127.0.0.1:${server.port}/in');
    unawaited(
      RelayServer(
        check: check,
        write: write.call,
        path: RelayPath.parse('/in')!,
        budget: budget,
        rate: WriteRateBound(perMinute: 1, burst: burst),
        maxBodyBytes: maxBodyBytes,
        maxInFlight: maxInFlight,
        log: logged.add,
      ).serve(server),
    );
  }

  tearDown(() => server.close(force: true));

  Future<(int, String)> post(
    String body, {
    String key = 'good',
    Uri? to,
    String method = 'POST',
  }) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, to ?? url);
      req.headers.set('x-test-key', key);
      req.write(body);
      final res = await req.close();
      return (res.statusCode, await utf8.decodeStream(res));
    } on HttpException {
      // The relay drops the connection after a refusal it sends unread;
      // a client still writing can see that as a broken pipe.
      return (-1, '');
    } finally {
      client.close(force: true);
    }
  }

  group('records, then answers', () {
    setUp(start);

    test(
      'an authentic delivery is written, then 200 with its response',
      () async {
        final (status, body) = await post('hello');
        expect(status, 200);
        expect(jsonDecode(body), {'ok': 'good'});
        expect(write.calls, hasLength(1));
        final (kind, entry, _) = write.calls.single;
        expect(kind.name, 'test-event');
        final event = RelayedEvent.read(
          ObjectId.of(Uint8List(1)),
          kind,
          Uint8List.fromList(entry),
        );
        expect(utf8.decode(event!.bytes), 'hello');
      },
    );

    test('already recorded is also a 200', () async {
      write.answer = () => AlreadyRecorded(ObjectId.of(Uint8List(1)));
      expect((await post('again')).$1, 200);
    });

    for (final (name, result) in [
      ('failed', const WriteFailed('disk')),
      ('refused', const WriteRefused('kind')),
      ('unanswered', const Unanswered('gone')),
    ]) {
      test('a write that is $name is a 503 with no response body', () async {
        write.answer = () => result;
        expect(await post('x'), (503, ''));
      });
    }

    test('not-tip is a 503', () async {
      write.answer = () => NotTip(ObjectId.of(Uint8List(2)));
      expect((await post('x')).$1, 503);
    });

    test('the check sees a body it cannot write to', () async {
      await post('hello');
      expect(() => check.seenBodies.single[0] = 0, throwsUnsupportedError);
    });

    test('a duplicate is written again: no seen set', () async {
      await post('same');
      await post('same');
      expect(write.calls, hasLength(2));
    });
  });

  group('refuses without writing', () {
    setUp(start);

    test('a header refusal answers its status and writes nothing', () async {
      expect((await post('hello', key: 'bad')).$1, anyOf(401, -1));
      expect(write.calls, isEmpty);
      expect(check.seenBodies, isEmpty);
      expect(logged.single, contains('401 bad key'));
    });

    test('a body refusal answers its status and writes nothing', () async {
      expect((await post('refuse')).$1, 403);
      expect(write.calls, isEmpty);
    });

    test('another path is 404', () async {
      final status = (await post('x', to: url.replace(path: '/else'))).$1;
      expect(status, anyOf(404, -1));
      expect(write.calls, isEmpty);
    });

    test('another method is 405', () async {
      expect((await post('x', method: 'PUT')).$1, anyOf(405, -1));
      expect(write.calls, isEmpty);
    });

    test('a body over the cap is 413', () async {
      expect((await post('x' * 2000)).$1, anyOf(413, -1));
      expect(write.calls, isEmpty);
    });
  });

  group('the write-rate bound', () {
    test('refuses past the burst with 429', () async {
      await start(burst: 1);
      expect((await post('one')).$1, 200);
      expect((await post('two')).$1, 429);
      expect(write.calls, hasLength(1));
    });

    test('is not spent by deliveries that fail the check', () async {
      await start(burst: 1);
      await post('x', key: 'bad');
      await post('refuse');
      expect((await post('one')).$1, 200);
    });

    test('is given back when the write does not record', () async {
      await start(burst: 1);
      write.answer = () => const Unanswered('down');
      expect((await post('one')).$1, 503);
      write.answer = () => Written(ObjectId.of(Uint8List(1)));
      expect((await post('one')).$1, 200);
    });
  });

  test('a reason cannot start a log line of its own', () async {
    await start();
    await post('x', key: 'bad');
    final check = _TestCheck();
    final lines = <String>[];
    final relay = RelayServer(
      check: check,
      write: write.call,
      path: RelayPath.parse('/in')!,
      budget: const Duration(seconds: 1),
      rate: WriteRateBound(perMinute: 1, burst: 1),
      log: lines.add,
    );
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(relay.serve(other));
    check.reason = 'tenant a\nforged line';
    final client = HttpClient();
    try {
      final req = await client.post('127.0.0.1', other.port, '/in');
      req.headers.set('x-test-key', 'bad');
      await (await req.close()).drain<void>();
    } on HttpException {
      // Dropped unread; the log line is what's checked.
    } finally {
      client.close(force: true);
      await other.close(force: true);
    }
    expect(lines.single, isNot(contains('\n')));
    expect(lines.single, contains(r'tenant a\x0aforged line'));
  });

  test('a path is a slash and no whitespace or query', () {
    expect(RelayPath.parse('/api/messages')?.value, '/api/messages');
    expect(RelayPath.parse('api'), isNull);
    expect(RelayPath.parse('/a b'), isNull);
    expect(RelayPath.parse('/a?b'), isNull);
  });

  group('the budget', () {
    test('a write slower than the budget is a 503, in time', () async {
      await start(budget: const Duration(milliseconds: 300));
      write.hold = Completer();
      final clock = Stopwatch()..start();
      expect((await post('slow')).$1, 503);
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      final (_, _, timeout) = write.calls.single;
      expect(timeout, lessThanOrEqualTo(const Duration(milliseconds: 300)));
      write.hold!.complete();
    });

    test('a body trickled past the budget is refused', () async {
      await start(budget: const Duration(milliseconds: 300));
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      socket.write(
        'POST /in HTTP/1.1\r\nhost: x\r\nx-test-key: good\r\n'
        'content-length: 10\r\n\r\nab',
      );
      final answer = await utf8.decodeStream(socket);
      expect(answer, startsWith('HTTP/1.1 408'));
      expect(write.calls, isEmpty);
    });
  });

  test('the in-flight cap counts a request until its write settles', () async {
    await start(maxInFlight: 1);
    write.hold = Completer();
    final first = post('first');
    await write.called.future;
    expect((await post('second')).$1, anyOf(503, -1));
    write.hold!.complete();
    expect((await first).$1, 200);
    expect((await post('third')).$1, 200);
  });
}
