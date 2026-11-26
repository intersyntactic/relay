/// The HTTP front every relay shares: refuse at the door, read the body,
/// check it, record it in the logbook, and only then answer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:is_docking_station_api/is_docking_station_api.dart'
    show encodeRelayedEvent;
import 'package:is_logbook_client/is_logbook_client.dart';

import 'checks_deliveries.dart';
import 'write_rate_bound.dart';

/// Where a logbook service's write socket is: an absolute filesystem path.
final class LogbookSocket {
  const LogbookSocket._(this.path);

  /// [s] as a socket path, or null when it isn't an absolute path.
  static LogbookSocket? parse(String s) =>
      s.startsWith('/') && !s.contains('\x00') ? LogbookSocket._(s) : null;

  final String path;

  @override
  String toString() => path;
}

/// The one path a relay takes: starts with `/`, no whitespace, no query.
final class RelayPath {
  const RelayPath._(this.value);

  /// [s] as a path, or null when it isn't one.
  static RelayPath? parse(String s) =>
      _form.hasMatch(s) ? RelayPath._(s) : null;

  static final _form = RegExp(r'^/[^\s?#]*$');

  /// The path, as a request's `uri.path` spells it.
  final String value;

  @override
  String toString() => value;
}

/// The one endpoint a source posts to.
///
/// Every request runs inside [budget], which must be shorter than the
/// source's own deadline (Slack 3 s, Teams 15 s, GitHub 10 s). Nothing a
/// request starts outlives it: the body read is cut off, the logbook
/// write's timeout is what remains (and the client destroys its socket
/// then), and the answer has what remains to go out. A 2xx is sent only
/// after the logbook says `Written` or `AlreadyRecorded`; everything else
/// is a refusal, so the source can send it again.
///
/// It keeps no record of what it has seen. A duplicate is written like any
/// delivery; the docking station decides each `EventKey` once.
///
/// It answers 200 once a delivery is recorded and a [RefusalStatus]
/// otherwise, never another status: a sender reads
/// `RefusalStatus.ofCode(status)?.worthAnotherTry` to decide whether to send
/// the same bytes again.
final class RelayServer<V extends Object> {
  /// A relay that records each authentic delivery exactly as it arrived.
  RelayServer({
    required ChecksDeliveries<V> check,
    required LogbookSocket logbook,
    required RelayPath path,
    required Duration budget,
    required WriteRateBound rate,
    int maxBodyBytes = defaultMaxBodyBytes,
    int maxInFlight = defaultMaxInFlight,
    DateTime Function() now = DateTime.now,
    void Function(String line) log = _stderr,
  }) : this._(
         check: check,
         decide: (vouched, body) =>
             switch (check.checkBody(vouched, body.asUnmodifiableView())) {
               Record(:final response) => _recording(body, response),
               final Refuse refusal => _Refusing(refusal),
             },
         logbook: logbook,
         path: path,
         budget: budget,
         rate: rate,
         maxBodyBytes: maxBodyBytes,
         maxInFlight: maxInFlight,
         now: now,
         log: log,
       );

  /// A relay that records a projection of each authentic delivery in place
  /// of what arrived, so a field the projection doesn't name is never
  /// recorded.
  RelayServer.projecting({
    required ChecksAndProjectsDeliveries<V> check,
    required LogbookSocket logbook,
    required RelayPath path,
    required Duration budget,
    required WriteRateBound rate,
    int maxBodyBytes = defaultMaxBodyBytes,
    int maxInFlight = defaultMaxInFlight,
    DateTime Function() now = DateTime.now,
    void Function(String line) log = _stderr,
  }) : this._(
         check: check,
         decide: (vouched, body) =>
             switch (check.checkBody(vouched, body.asUnmodifiableView())) {
               RecordProjection(:final projection, :final response) =>
                 _recording(_encode(projection), response),
               final Refuse refusal => _Refusing(refusal),
             },
         logbook: logbook,
         path: path,
         budget: budget,
         rate: rate,
         maxBodyBytes: maxBodyBytes,
         maxInFlight: maxInFlight,
         now: now,
         log: log,
       );

  RelayServer._({
    required this.check,
    required this._decide,
    required this.logbook,
    required this.path,
    required this.budget,
    required this.rate,
    required this.maxBodyBytes,
    required this.maxInFlight,
    required this._now,
    required this.log,
  });

  /// The body cap both constructors default to.
  static const defaultMaxBodyBytes = 1024 * 1024;

  /// The in-flight cap both constructors default to.
  static const defaultMaxInFlight = 64;

  /// How deep a check's JSON may nest. Deeper is refused, not encoded.
  static const _maxJsonDepth = 64;

  /// [o] as the bytes the relay records or sends, or null when it holds a
  /// value JSON can't carry. `JsonObject.of` doesn't check its values, and
  /// `jsonEncode` throws an `Error` on one, which would end the process; so
  /// nothing reaches it unchecked.
  static Uint8List? _encode(JsonObject o) =>
      _isJson(o, 0) ? utf8.encode(jsonEncode(o)) : null;

  static bool _isJson(Object? v, int depth) =>
      depth <= _maxJsonDepth &&
      switch (v) {
        null || bool() || String() || int() => true,
        final double d => d.isFinite,
        final List<Object?> l => l.every((e) => _isJson(e, depth + 1)),
        _ => switch (JsonObject.parse(v)) {
          final JsonObject o => o.keys.every(
            (k) => _isJson(o.raw(k), depth + 1),
          ),
          null => false,
        },
      };

  /// What to record and send, both encoded before the write, or
  /// [_Unencodable] when either can't be.
  static _Decided _recording(Uint8List? bytes, JsonObject? response) {
    final sent = response == null ? null : _encode(response);
    if (bytes == null || (response != null && sent == null)) {
      return const _Unencodable();
    }
    return _Recording(bytes, sent);
  }

  /// The source's check. Its body half is held in [_decide], which is the
  /// only thing that chooses the bytes recorded.
  final ChecksDeliveryHeaders<V> check;

  /// The body check, given the relay's own buffer: what to record and the
  /// response to send, both already encoded, or the refusal. A check sees
  /// only an unmodifiable view of the buffer.
  final _Decided Function(V vouched, Uint8List body) _decide;

  /// The logbook service's write socket. The relay writes through its own
  /// `LogbookWriter`, whose timeout ends every write inside the budget.
  final LogbookSocket logbook;

  /// The only path taken, such as `/api/messages`.
  final RelayPath path;

  /// The whole request's time, from arrival to answer.
  final Duration budget;

  /// The bound on how fast this source's deliveries are recorded.
  final WriteRateBound rate;

  final int maxBodyBytes;

  /// The most requests handled at once. Nothing a request starts outlives
  /// its budget, so this bounds all unfinished work.
  final int maxInFlight;

  /// One line per request: the status and why, never the content.
  final void Function(String line) log;

  final DateTime Function() _now;
  int _inFlight = 0;

  /// The time kept back for an answer to go out. The write's timeout leaves
  /// it, so an answer after a write fits inside the budget; an answer is
  /// never given less, so a refusal can still reach the sender.
  static const _leastToAnswer = Duration(milliseconds: 250);

  /// Serves [server] until it closes, each request on its own.
  ///
  /// An `Error` from a request is a bug, in the relay or in the source's
  /// check, and is not caught: it ends the process, and the deployment
  /// restarts it. So a check must turn any input into a [Refuse] or an
  /// `Exception` (answered 500), never an `Error`.
  Future<void> serve(HttpServer server) =>
      server.forEach((req) => unawaited(handle(req)));

  /// Handles one request.
  Future<void> handle(HttpRequest req) async {
    final clock = Stopwatch()..start();
    Duration left() {
      final rest = budget - clock.elapsed;
      return rest < _leastToAnswer ? _leastToAnswer : rest;
    }

    final full = _inFlight >= maxInFlight;
    if (!full) _inFlight++;
    try {
      await (full
          ? _refuseUnread(req, RefusalStatus.serviceUnavailable, 'busy', left)
          : _handle(req, clock, left));
    } on Exception catch (e) {
      // The checks and the write turn their exceptions into answers, so
      // only answering throws here, on a connection the sender closed or
      // stopped reading: there is no one left to answer.
      log('${check.source} relay: answer not sent: ${e.runtimeType}');
    } finally {
      if (!full) _inFlight--;
    }
  }

  Future<void> _handle(
    HttpRequest req,
    Stopwatch clock,
    Duration Function() left,
  ) async {
    // wire-ok: the HTTP method, checked against the one we accept.
    if (req.method != 'POST') {
      return _refuseUnread(req, RefusalStatus.methodNotAllowed, 'method', left);
    }
    if (req.uri.path != path.value) {
      return _refuseUnread(req, RefusalStatus.notFound, 'path', left);
    }
    if (req.contentLength > maxBodyBytes) {
      return _refuseUnread(req, RefusalStatus.payloadTooLarge, 'length', left);
    }

    final headers = <String, String>{};
    req.headers.forEach((name, values) => headers[name] = values.join(','));
    final HeaderCheck<V> onHeaders;
    try {
      onHeaders = check.checkHeaders(DeliveryHeaders(headers), _now());
    } on Exception catch (e) {
      // Unread like every other refusal before the body: answering with
      // `close()` would wait on whatever body the sender chooses to send.
      return _refuseUnread(
        req,
        RefusalStatus.internalServerError,
        'header check threw ${e.runtimeType}',
        left,
      );
    }
    final V vouched;
    switch (onHeaders) {
      case HeadersRefused(:final status, :final reason):
        return _refuseUnread(req, status, reason, left);
      case HeadersVouch(vouched: final v):
        vouched = v;
    }

    final Uint8List bytes;
    // The read keeps back the time an answer needs, as the write does, so a
    // refusal after a slow body still goes out inside the budget.
    switch (await _read(req, budget - clock.elapsed - _leastToAnswer)) {
      case _TooLarge():
        return _refuseUnread(req, RefusalStatus.payloadTooLarge, 'body', left);
      case _TooSlow():
        return _refuseUnread(
          req,
          RefusalStatus.requestTimeout,
          'body slow',
          left,
        );
      case _Broken():
        return _refuseUnread(
          req,
          RefusalStatus.badRequest,
          'body broken',
          left,
        );
      case _Read(bytes: final b):
        bytes = b;
    }

    // From here the body is read, so `close()` has nothing left to wait on.
    final _Decided decided;
    try {
      decided = _decide(vouched, bytes);
    } on Exception catch (e) {
      return _refuse(
        req,
        RefusalStatus.internalServerError,
        'body check threw ${e.runtimeType}',
        left,
      );
    }
    final _Recording recording;
    switch (decided) {
      case _Refusing(refusal: Refuse(:final status, :final reason)):
        return _refuse(req, status, reason, left);
      case _Unencodable():
        return _refuse(
          req,
          RefusalStatus.internalServerError,
          'body check returned JSON that cannot be encoded',
          left,
        );
      case final _Recording r:
        recording = r;
    }

    // After the check, so only authentic deliveries spend the bound: an
    // unauthenticated sender can't use it up and shut out the source.
    if (!rate.take()) {
      return _refuse(req, RefusalStatus.tooManyRequests, 'rate bound', left);
    }

    final (outcome, why) = await _write(recording.bytes, clock);
    switch (outcome) {
      case _Outcome.recorded:
        return _send(req, 200, why, left, recording.response);
      case _Outcome.absent:
        // Certainly not in the logbook: give the room back, or an outage
        // would leave the bound spent on the retries.
        rate.giveBack();
        return _refuse(req, RefusalStatus.serviceUnavailable, why, left);
      case _Outcome.unknown:
        // It may be in, so the room stays spent: the bound counts what
        // could be recorded, not what was confirmed.
        return _refuse(req, RefusalStatus.serviceUnavailable, why, left);
    }
  }

  /// Writes [bytes] in what remains of the budget by [clock], keeping back
  /// the time an answer needs, and says what became of it.
  ///
  /// The relay's own `LogbookWriter`, whose timeout is that remainder: it
  /// destroys its socket when that runs out, so the write ends inside the
  /// budget and nothing waits on it after.
  Future<(_Outcome, String)> _write(Uint8List bytes, Stopwatch clock) async {
    final (kind, entry) = encodeRelayedEvent(
      check.source,
      at: _now().toUtc(),
      bytes: bytes,
    );
    final remaining = budget - clock.elapsed - _leastToAnswer;
    if (remaining <= Duration.zero) {
      return (_Outcome.absent, 'budget spent before write');
    }
    final WriteResult result;
    try {
      result = await LogbookWriter(
        logbook.path,
        timeout: remaining,
      ).write(kind, entry);
    } on Exception catch (e) {
      // The client turns its own failures into Unanswered; anything else
      // it lets through may have reached the logbook all the same.
      return (_Outcome.unknown, 'writer threw ${e.runtimeType}');
    }
    return switch (result) {
      Written(:final entry) => (_Outcome.recorded, 'recorded ${entry.hex}'),
      AlreadyRecorded(:final entry) => (
        _Outcome.recorded,
        'already ${entry.hex}',
      ),
      // A chain start has no tip to be behind: the writer isn't one we know.
      NotTip(:final tip) => (_Outcome.absent, 'not-tip ${tip.hex}'),
      WriteRefused(:final why) => (_Outcome.absent, 'refused $why'),
      // The writer's own words: failed partway, and may be in.
      WriteFailed(:final why) => (_Outcome.unknown, 'failed $why'),
      Unanswered(:final why) => (_Outcome.unknown, 'unanswered $why'),
    };
  }

  /// The body, read until it ends, passes the cap, or [within] runs out.
  Future<_Body> _read(HttpRequest req, Duration within) async {
    if (within <= Duration.zero) return const _TooSlow();
    final builder = BytesBuilder(copy: false);
    final done = Completer<_Body>();
    late final StreamSubscription<Uint8List> sub;
    final timer = Timer(within, () {
      if (!done.isCompleted) done.complete(const _TooSlow());
    });
    sub = req.listen(
      (chunk) {
        if (builder.length + chunk.length > maxBodyBytes) {
          if (!done.isCompleted) done.complete(const _TooLarge());
          return;
        }
        builder.add(chunk);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(_Read(builder.takeBytes()));
      },
      onError: (Object e) {
        if (!done.isCompleted) done.complete(const _Broken());
      },
    );
    final body = await done.future;
    timer.cancel();
    // Paused, not cancelled: cancelling the body detaches dart:io's request
    // from its response, and the refusal then can't take the socket to
    // drop it. Destroying the socket ends the subscription.
    if (body is! _Read) sub.pause();
    return body;
  }

  /// Answers a request whose body has been read. The response's deadline is
  /// what remains of the budget: a sender that stops reading can't hold the
  /// request past it. (Not set earlier: a deadline that fired during the
  /// body read would destroy the socket under it.)
  Future<void> _refuse(
    HttpRequest req,
    RefusalStatus status,
    String reason,
    Duration Function() left,
  ) => _send(req, status.code, reason, left);

  /// [_refuse] and the recorded answer's shared body. Only those two call
  /// it, so every status a relay answers is 200 or a [RefusalStatus].
  Future<void> _send(
    HttpRequest req,
    int status,
    String reason,
    Duration Function() left, [
    Uint8List? response,
  ]) async {
    _log(status, reason);
    req.response
      ..deadline = left()
      ..statusCode = status;
    if (response != null) {
      req.response.headers.contentType = ContentType.json;
      req.response.add(response);
    }
    await req.response.close();
  }

  /// Answers [status] and drops the connection, leaving the rest of the
  /// body unread. dart:io's `response.close()` reads the whole request body
  /// before it sends a byte, so a refusal sent with it would still wait on
  /// whatever the sender chooses to send.
  ///
  /// The socket is taken before anything is written to it, so no output is
  /// pending when it is handed over, and the status line is written to it
  /// directly. The flush gets what remains of the budget, and the socket is
  /// destroyed whatever it does.
  Future<void> _refuseUnread(
    HttpRequest req,
    RefusalStatus status,
    String reason,
    Duration Function() left,
  ) async {
    _log(status.code, reason);
    final socket = await req.response.detachSocket(writeHeaders: false);
    try {
      socket.write(
        'HTTP/1.1 ${status.code} ${status.phrase}\r\n'
        'content-length: 0\r\nconnection: close\r\n\r\n',
      );
      await socket.flush().timeout(left());
    } on TimeoutException {
      // The sender isn't reading; it gets no answer, as a dropped one.
    } finally {
      socket.destroy();
    }
  }

  /// One line per request. A reason can carry what a sender sent (a header
  /// value in a source's refusal), so control characters are escaped and a
  /// sender can't start a line of its own.
  void _log(int status, String reason) => log(
    '${check.source} relay: $status '
    '${reason.replaceAllMapped(_control, (m) => '\\x${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}')}',
  );

  static final _control = RegExp(r'[\x00-\x1f\x7f]');

  static void _stderr(String line) => stderr.writeln(line);
}

sealed class _Body {
  const _Body();
}

final class _Read extends _Body {
  const _Read(this.bytes);
  final Uint8List bytes;
}

final class _TooLarge extends _Body {
  const _TooLarge();
}

final class _TooSlow extends _Body {
  const _TooSlow();
}

/// The body stream failed: the sender went away mid-body.
final class _Broken extends _Body {
  const _Broken();
}

/// What a body check decided, whichever kind of check it was.
sealed class _Decided {
  const _Decided();
}

/// Record [bytes], then answer 2xx with [response]. Both are encoded before
/// the write, so nothing after it can fail on what a check returned.
final class _Recording extends _Decided {
  const _Recording(this.bytes, this.response);
  final Uint8List bytes;
  final Uint8List? response;
}

/// The check returned a projection or response JSON can't carry: its bug,
/// answered 500 before anything is written.
final class _Unencodable extends _Decided {
  const _Unencodable();
}

final class _Refusing extends _Decided {
  const _Refusing(this.refusal);
  final Refuse refusal;
}

/// What became of a write.
enum _Outcome {
  /// The logbook holds it.
  recorded,

  /// The logbook certainly doesn't hold it.
  absent,

  /// It may or may not be in.
  unknown,
}
