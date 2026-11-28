# is_relay

What every Intersyntactic relay shares. A relay is the public entry point for
one outside source (GitHub, Slack, Teams). It takes a delivery, checks it with
the source's check, records it in the logbook, and only then answers. The
logbook is its only way out: downstream reads the logbook.

[DESIGN.md](DESIGN.md) says why it is shaped this way. [TEMPER.md](TEMPER.md)
records the three design reviews it went through.

## A relay

A source supplies its check, and is_relay does the rest:

```dart
final class SlackCheck implements ChecksDeliveries<SlackSignature> {
  @override
  RelayedEventSource get source => RelayedEventSource.parse('slack')!;

  @override
  HeaderCheck<SlackSignature> checkHeaders(DeliveryHeaders h, DateTime now) =>
      ...; // HeadersVouch(signature) or HeadersRefused(status, reason)

  @override
  BodyVerdict checkBody(SlackSignature signature, Uint8List body) =>
      ...; // Record(response: ...) or Refuse(status, reason)
}

final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8090);
await RelayServer(
  check: SlackCheck(...),
  logbook: LogbookSocket.parse('/run/logbook/write.sock')!,
  path: RelayPath.parse('/slack/events')!,
  budget: const Duration(milliseconds: 2500), // inside Slack's 3 s
  rate: WriteRateBound(perMinute: 600, burst: 60),
).serve(server);
```

`RelayServer`:

- **Refuses at the door** (wrong path or method, a length over the cap, too
  many requests in flight, or the header check), dropping the connection
  without reading the body.
- **Reads the body** under the cap and the budget.
- **Checks it.** The check sees a view it can't write to, so for a raw
  source the bytes recorded are the bytes checked.
- **Takes room** from the source's write-rate bound.
- **Writes the delivery** as `<source>-event` via is_docking_station_api's
  `encodeRelayedEvent`, with the budget that remains as the write's timeout.
- **Answers 2xx** only on `Written` or `AlreadyRecorded`. Every other answer
  is a refusal, so the source can send the delivery again.

### A source that mustn't be recorded raw

When a source's deliveries can carry credentials in fields no list could
name (a Teams activity's open `value`), its check implements
`ChecksAndProjectsDeliveries` and returns `RecordProjection` with only the
fields its translator reads. Run it with `RelayServer.projecting`. Its
verdict has no `Record`, so it can't record the raw body on any path:

```dart
@override
ProjectedVerdict checkBody(TeamsToken token, Uint8List body) =>
    ...; // RecordProjection(activity.projection(), response: ...) or Refuse(...)

await RelayServer.projecting(check: TeamsCheck(...), ...).serve(server);
```

The relay encodes the projection as JSON and records it where a raw source's
entry holds the body. A projection must keep the identity its translator
builds the `EventKey` from (Teams: the activity id), or two deliveries are
decided as one. Make it versioned and deterministic too. checked_json
refuses a value JSON can't carry where the `JsonObject` is built, so the
check throws and is answered 500. A projection or response nested more than
64 deep is answered 500 too. Either way nothing is written.

A check turns any input into a `Refuse` or, at worst, an `Exception`
(answered 500). It never throws an `Error`: an `Error` is a bug, and
`serve` doesn't catch it, so the process ends and the deployment restarts
it.

It keeps no record of what it has seen. The docking station decides each
`EventKey` once, so a duplicate costs only a logbook entry.

## Deploy

Run it on loopback behind a TLS proxy. The proxy must log no `Authorization`
header and no request body, and must bound header reads and connections:
dart:io's `HttpServer` doesn't time out a sender that trickles its headers.

## Developing

```sh
dart pub get
dart analyze --fatal-infos
dart test
```
