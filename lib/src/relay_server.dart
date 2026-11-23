/// The HTTP front every relay shares: refuse at the door, read the body,
/// check it, record it in the logbook, and only then answer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  final String path;

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

  /// Serves [server] until it closes.
  Future<void> serve(HttpServer server) => server.forEach(handle);

  /// Handles one request.
  Future<void> handle(HttpRequest req) async {
    if (_inFlight >= maxInFlight) {
      return _refuseUnread(req, RefusalStatus.serviceUnavailable, 'busy');
    }
    _inFlight++;
    try {
      await _handle(req, Stopwatch()..start());
    } on Exception catch (e) {
      log('${check.source} relay: 500 ${e.runtimeType}');
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
    if (req.uri.path != path) {
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

    final remaining = budget - clock.elapsed;
    if (remaining <= Duration.zero) {
      return _answer(req, 503, 'budget spent before write');
    }
    final (kind, entry) = encodeRelayedEvent(
      check.source,
      at: _now().toUtc(),
      bytes: bytes,
    );
    final WriteResult result;
    try {
      result = await write(kind, entry, remaining).timeout(remaining);
    } on TimeoutException {
      return _answer(req, 503, 'unanswered: budget spent');
    }
    switch (result) {
      case Written(:final entry):
        return _answer(req, 200, 'recorded ${entry.hex}', record.response);
      case AlreadyRecorded(:final entry):
        return _answer(req, 200, 'already ${entry.hex}', record.response);
      // A chain start has no tip to be behind: the writer isn't one we know.
      case NotTip(:final tip):
        return _answer(req, 503, 'not-tip ${tip.hex}');
      case WriteRefused(:final why):
        return _answer(req, 503, 'refused $why');
      case WriteFailed(:final why):
        return _answer(req, 503, 'failed $why');
      case Unanswered(:final why):
        return _answer(req, 503, 'unanswered $why');
    }
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
    Object? response,
  ]) async {
    log('${check.source} relay: $status $reason');
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
    log('${check.source} relay: ${status.code} $reason');
    req.response
      ..statusCode = status.code
      ..persistentConnection = false
      ..contentLength = 0;
    final socket = await req.response.detachSocket();
    await socket.flush();
    socket.destroy();
  }

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
