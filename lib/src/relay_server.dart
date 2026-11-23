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
final class RelayServer<V extends Object> {
  RelayServer({
    required this.check,
    required this.logbook,
    required this.path,
    required this.budget,
    required this.rate,
    this.maxBodyBytes = 1024 * 1024,
    this.maxInFlight = 64,
    this._now = DateTime.now,
    this.log = _stderr,
  });

  final ChecksDeliveries<V> check;

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
    switch (await _read(req, budget - clock.elapsed)) {
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
    final BodyVerdict verdict;
    try {
      verdict = check.checkBody(vouched, bytes.asUnmodifiableView());
    } on Exception catch (e) {
      return _answer(req, 500, 'body check threw ${e.runtimeType}', left);
    }
    final Record record;
    switch (verdict) {
      case Refuse(:final status, :final reason):
        return _answer(req, status.code, reason, left);
      case final Record r:
        record = r;
    }

    // After the check, so only authentic deliveries spend the bound: an
    // unauthenticated sender can't use it up and shut out the source.
    if (!rate.take()) {
      return _answer(
        req,
        RefusalStatus.tooManyRequests.code,
        'rate bound',
        left,
      );
    }

    final (outcome, why) = await _write(bytes, clock);
    switch (outcome) {
      case _Outcome.recorded:
        return _answer(req, 200, why, left, record.response);
      case _Outcome.absent:
        // Certainly not in the logbook: give the room back, or an outage
        // would leave the bound spent on the retries.
        rate.giveBack();
        return _answer(req, 503, why, left);
      case _Outcome.unknown:
        // It may be in, so the room stays spent: the bound counts what
        // could be recorded, not what was confirmed.
        return _answer(req, 503, why, left);
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
  Future<void> _answer(
    HttpRequest req,
    int status,
    String reason,
    Duration Function() left, [
    JsonObject? response,
  ]) async {
    _log(status, reason);
    req.response
      ..deadline = left()
      ..statusCode = status;
    if (response != null) {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(response));
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

/// What became of a write.
enum _Outcome {
  /// The logbook holds it.
  recorded,

  /// The logbook certainly doesn't hold it.
  absent,

  /// It may or may not be in.
  unknown,
}
