/// What a source supplies to a relay: its check of a delivery.
library;

import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:is_docking_station_api/is_docking_station_api.dart'
    show RelayedEventSource;

/// The half of a source's check both kinds share: what the headers alone
/// decide, so a sender with no valid credentials is refused before a byte
/// of its body is read.
///
/// [V] is what the header check vouched for (a verified token, a signature
/// still to compare), handed to the body check. A relay never looks inside
/// it.
abstract interface class ChecksDeliveryHeaders<V extends Object> {
  /// The source, which names the kind its deliveries are recorded as.
  RelayedEventSource get source;

  /// What [headers] alone decide, at [now].
  HeaderCheck<V> checkHeaders(DeliveryHeaders headers, DateTime now);
}

/// A source's check of its deliveries, for a source whose deliveries are
/// recorded exactly as they arrived: its headers, then its body once in
/// hand.
abstract interface class ChecksDeliveries<V extends Object>
    implements ChecksDeliveryHeaders<V> {
  /// The rest, given what [checkHeaders] vouched for. [body] can't be
  /// written to, so the bytes recorded are the bytes checked. Returns a
  /// verdict, never bytes: on [Record], the relay records its own copy.
  BodyVerdict checkBody(V vouched, Uint8List body);
}

/// A source's check of its deliveries, for a source whose deliveries must
/// not be recorded as they arrived (a Teams activity can carry a person's
/// token in fields no list could name), so only a projection of each one
/// is: the fields its translator reads, built fresh.
///
/// Its verdict has no way to record the raw body, so a source that projects
/// can't fall back to recording what arrived.
abstract interface class ChecksAndProjectsDeliveries<V extends Object>
    implements ChecksDeliveryHeaders<V> {
  /// The rest, given what [checkHeaders] vouched for. [body] can't be
  /// written to. On [RecordProjection], the relay records the projection,
  /// encoded as JSON, in place of the body.
  ProjectedVerdict checkBody(V vouched, Uint8List body);
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

/// What a delivery's body decided, for a [ChecksDeliveries].
sealed class BodyVerdict {}

/// What a delivery's body decided, for a [ChecksAndProjectsDeliveries]:
/// there is no [Record] here, so nothing records the raw body.
sealed class ProjectedVerdict {}

/// Authentic: record it, then answer 2xx with [response] as the body when
/// there is one (Slack's url_verification challenge). [response] goes out
/// only once the delivery is recorded.
final class Record implements BodyVerdict {
  const Record({this.response});
  final JsonObject? response;
}

/// Authentic: record [projection] in place of the body, then answer 2xx
/// with [response] as the body when there is one (a Teams invoke response).
/// [response] goes out only once the projection is recorded.
///
/// The relay encodes [projection] as JSON, and those bytes are what the
/// logbook entry holds where a raw source's entry holds the body.
final class RecordProjection implements ProjectedVerdict {
  const RecordProjection(this.projection, {this.response});
  final JsonObject projection;
  final JsonObject? response;
}

/// Refused on its body: answered [status], not recorded. Both kinds of
/// check refuse the same way.
final class Refuse implements BodyVerdict, ProjectedVerdict {
  const Refuse(this.status, this.reason);
  final RefusalStatus status;

  /// Logged, never sent.
  final String reason;
}

/// The statuses a relay refuses with. None is a 2xx: a 2xx means recorded.
/// The relay server answers nothing else, so a sender's retry logic can read
/// [worthAnotherTry] instead of guessing from the number.
enum RefusalStatus {
  badRequest(400, 'Bad Request', worthAnotherTry: false),
  unauthorized(401, 'Unauthorized', worthAnotherTry: false),
  forbidden(403, 'Forbidden', worthAnotherTry: false),
  notFound(404, 'Not Found', worthAnotherTry: false),
  methodNotAllowed(405, 'Method Not Allowed', worthAnotherTry: false),
  requestTimeout(408, 'Request Timeout', worthAnotherTry: true),
  payloadTooLarge(413, 'Payload Too Large', worthAnotherTry: false),
  tooManyRequests(429, 'Too Many Requests', worthAnotherTry: true),
  internalServerError(500, 'Internal Server Error', worthAnotherTry: true),
  serviceUnavailable(503, 'Service Unavailable', worthAnotherTry: true);

  const RefusalStatus(this.code, this.phrase, {required this.worthAnotherTry});

  /// The HTTP status code.
  final int code;

  /// The reason phrase for the status line.
  final String phrase;

  /// Whether sending the same bytes again may be recorded: the refusal came
  /// from the relay's state (busy, rate bound, a slow body, the logbook, a
  /// check that threw), not from what the delivery is.
  final bool worthAnotherTry;

  /// The refusal whose [code] is [code], or null for a status no relay
  /// refuses with.
  static RefusalStatus? ofCode(int code) =>
      values.where((s) => s.code == code).firstOrNull;
}
