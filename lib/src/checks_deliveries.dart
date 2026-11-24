/// What a source supplies to a relay: its check of a delivery.
library;

import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:is_docking_station_api/is_docking_station_api.dart'
    show RelayedEventSource;

/// A source's check of its deliveries, in two parts: what the headers alone
/// decide, so a sender with no valid credentials is refused before a byte
/// of its body is read, and the rest once the body is in hand.
///
/// [V] is what the header check vouched for (a verified token, a signature
/// still to compare), handed to [checkBody]. A relay never looks inside it.
abstract interface class ChecksDeliveries<V extends Object> {
  /// The source, which names the kind its deliveries are recorded as.
  RelayedEventSource get source;

  /// What [headers] alone decide, at [now].
  HeaderCheck<V> checkHeaders(DeliveryHeaders headers, DateTime now);

  /// The rest, given what [checkHeaders] vouched for. [body] can't be
  /// written to, so the bytes recorded are the bytes checked. Returns a
  /// verdict, never bytes: on [Record], the relay records its own copy.
  BodyVerdict checkBody(V vouched, Uint8List body);
}

/// A delivery's headers, read by name in any case.
final class DeliveryHeaders {
  DeliveryHeaders(Map<String, String> headers)
    : _byName = {
        for (final MapEntry(:key, :value) in headers.entries)
          key.toLowerCase(): value,
      };

  final Map<String, String> _byName;

  /// The header [name]'s value, or null when it was not sent.
  String? operator [](String name) => _byName[name.toLowerCase()];
}

/// What a delivery's headers decided.
sealed class HeaderCheck<V extends Object> {
  const HeaderCheck();
}

/// The headers vouch for [vouched]; read the body and check the rest.
final class HeadersVouch<V extends Object> extends HeaderCheck<V> {
  const HeadersVouch(this.vouched);
  final V vouched;
}

/// Refused on the headers alone. The body is never read.
final class HeadersRefused<V extends Object> extends HeaderCheck<V> {
  const HeadersRefused(this.status, this.reason);
  final RefusalStatus status;

  /// Logged, never sent: a reason in a response is a hint to whoever is
  /// guessing.
  final String reason;
}

/// What a delivery's body decided.
sealed class BodyVerdict {
  const BodyVerdict();
}

/// Authentic: record it, then answer 2xx with [response] as the body when
/// there is one (a Teams invoke response, Slack's url_verification
/// challenge). [response] goes out only once the delivery is recorded.
final class Record extends BodyVerdict {
  const Record({this.response});
  final JsonObject? response;
}

/// Refused on its body: answered [status], not recorded.
final class Refuse extends BodyVerdict {
  const Refuse(this.status, this.reason);
  final RefusalStatus status;

  /// Logged, never sent.
  final String reason;
}

/// The statuses a relay refuses with. None is a 2xx: a 2xx means recorded.
enum RefusalStatus {
  badRequest(400, 'Bad Request'),
  unauthorized(401, 'Unauthorized'),
  forbidden(403, 'Forbidden'),
  notFound(404, 'Not Found'),
  methodNotAllowed(405, 'Method Not Allowed'),
  requestTimeout(408, 'Request Timeout'),
  payloadTooLarge(413, 'Payload Too Large'),
  tooManyRequests(429, 'Too Many Requests'),
  internalServerError(500, 'Internal Server Error'),
  serviceUnavailable(503, 'Service Unavailable');

  const RefusalStatus(this.code, this.phrase);

  /// The HTTP status code.
  final int code;

  /// The reason phrase for the status line.
  final String phrase;
}
