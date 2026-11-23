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

/// Writes one entry to the logbook as a chain start, giving up after
/// [timeout]. [writerAt] makes the real one.
typedef WritesEntry = Future<WriteResult> Function(
  Kind kind,
  List<int> body,
  Duration timeout,
);

/// The writer for the logbook service at [socketPath].
WritesEntry writerAt(String socketPath) =>
    (kind, body, timeout) =>
        LogbookWriter(socketPath, timeout: timeout).write(kind, body);

/// The one endpoint a source posts to.
///
/// Every request runs inside [budget], which must be shorter than the
/// source's own deadline (Slack 3 s, Teams 15 s, GitHub 10 s). Nothing a
/// request starts outlives it: the body read is cut off, and the write's
/// timeout is what remains. A 2xx is sent only after the logbook says
/// `Written` or `AlreadyRecorded`; everything else is a refusal, so the
/// source can send it again.
///
/// It keeps no record of what it has seen. A duplicate is written like any
/// delivery; the docking station decides each `EventKey` once.
final class RelayServer<V extends Object> {
  RelayServer({
    required this.check,
    required this.write,
    required this.path,
    required this.budget,
    required this.rate,
    this.maxBodyBytes = 1024 * 1024,
    this.maxInFlight = 64,
    this._now = DateTime.now,
    this.log = _stderr,
  });

  final ChecksDeliveries<V> check;
  final WritesEntry write;

  /// The only path taken, such as `/api/messages`.
  final RelayPath path;

  /// The whole request's time, from arrival to answer.
  final Duration budget;

  /// The bound on how fast this source's deliveries are recorded.
  final WriteRateBound rate;

  final int maxBodyBytes;

  /// The most requests handled at once. Each holds its place until its
  /// budget ends, so this bounds unfinished writes too.
  final int maxInFlight;

  /// One line per request: the status and why, never the content.
  final void Function(String line) log;

  final DateTime Function() _now;
  int _inFlight = 0;

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
    if (_inFlight >= maxInFlight) {
      return _refuseUnread(req, RefusalStatus.serviceUnavailable, 'busy');
    }
    _inFlight++;
    try {
      await _handle(req, Stopwatch()..start());
    } on Exception catch (e) {
      _log(500, '${e.runtimeType}');
      try {
        await _end(req, 500);
      } on Exception {
        // The response was already under way; there is no one left to tell.
      }
    } finally {
      _inFlight--;
    }
  }

  Future<void> _handle(HttpRequest req, Stopwatch clock) async {
    // wire-ok: the HTTP method, checked against the one we accept.
    if (req.method != 'POST') {
      return _refuseUnread(req, RefusalStatus.methodNotAllowed, 'method');
    }
    if (req.uri.path != path.value) {
      return _refuseUnread(req, RefusalStatus.notFound, 'path');
    }
    if (req.contentLength > maxBodyBytes) {
      return _refuseUnread(req, RefusalStatus.payloadTooLarge, 'length');
    }

    final headers = <String, String>{};
    req.headers.forEach((name, values) => headers[name] = values.join(','));
    final V vouched;
    switch (check.checkHeaders(DeliveryHeaders(headers), _now())) {
      case HeadersRefused(:final status, :final reason):
        return _refuseUnread(req, status, reason);
      case HeadersVouch(vouched: final v):
        vouched = v;
    }

    final Uint8List bytes;
    switch (await _read(req, budget - clock.elapsed)) {
      case _TooLarge():
        return _refuseUnread(req, RefusalStatus.payloadTooLarge, 'body');
      case _TooSlow():
        return _refuseUnread(req, RefusalStatus.requestTimeout, 'body slow');
      case _Read(bytes: final b):
        bytes = b;
    }

    final verdict = check.checkBody(vouched, bytes.asUnmodifiableView());
    final Record record;
    switch (verdict) {
      case Refuse(:final status, :final reason):
        return _answer(req, status.code, reason);
      case final Record r:
        record = r;
    }

    // After the check, so only authentic deliveries spend the bound: an
    // unauthenticated sender can't use it up and shut out the source.
    if (!rate.take()) {
      return _answer(req, RefusalStatus.tooManyRequests.code, 'rate bound');
    }

    final (recorded, why) = await _write(bytes, budget - clock.elapsed);
    if (!recorded) {
      // Not recorded, so the source will send it again: the room it took is
      // given back, or an outage would leave the bound spent on retries.
      rate.giveBack();
      return _answer(req, 503, why);
    }
    return _answer(req, 200, why, record.response);
  }

  /// Writes [bytes] within [remaining]. True when the logbook holds the
  /// entry, whether written now or already there.
  Future<(bool recorded, String why)> _write(
    Uint8List bytes,
    Duration remaining,
  ) async {
    if (remaining <= Duration.zero) return (false, 'budget spent before write');
    final (kind, entry) = encodeRelayedEvent(
      check.source,
      at: _now().toUtc(),
      bytes: bytes,
    );
    final WriteResult result;
    try {
      result = await write(kind, entry, remaining).timeout(remaining);
    } on TimeoutException {
      return (false, 'unanswered: budget spent');
    }
    return switch (result) {
      Written(:final entry) => (true, 'recorded ${entry.hex}'),
      AlreadyRecorded(:final entry) => (true, 'already ${entry.hex}'),
      // A chain start has no tip to be behind: the writer isn't one we know.
      NotTip(:final tip) => (false, 'not-tip ${tip.hex}'),
      WriteRefused(:final why) => (false, 'refused $why'),
      WriteFailed(:final why) => (false, 'failed $why'),
      Unanswered(:final why) => (false, 'unanswered $why'),
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
        if (!done.isCompleted) done.complete(const _TooSlow());
      },
      cancelOnError: true,
    );
    final body = await done.future;
    timer.cancel();
    // Paused, not cancelled: cancelling the body detaches dart:io's request
    // from its response, and the refusal then can't take the socket to
    // drop it. Destroying the socket ends the subscription.
    if (body is! _Read) sub.pause();
    return body;
  }

  Future<void> _answer(
    HttpRequest req,
    int status,
    String reason, [
    JsonObject? response,
  ]) async {
    _log(status, reason);
    req.response.statusCode = status;
    if (response != null) {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(response));
    }
    await req.response.close();
  }

  static Future<void> _end(HttpRequest req, int status) async {
    req.response.statusCode = status;
    await req.response.close();
  }

  /// Answers [status] and drops the connection, leaving the rest of the
  /// body unread. dart:io's `response.close()` reads the whole request body
  /// before it sends a byte, so a refusal sent with it would still wait on
  /// whatever the sender chooses to send.
  Future<void> _refuseUnread(
    HttpRequest req,
    RefusalStatus status,
    String reason,
  ) async {
    _log(status.code, reason);
    req.response
      ..statusCode = status.code
      ..persistentConnection = false
      ..contentLength = 0;
    final socket = await req.response.detachSocket();
    await socket.flush();
    socket.destroy();
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
