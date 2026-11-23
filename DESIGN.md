# is_relay: design

A relay is the public entry point for one outside source (GitHub, Slack,
Teams). It takes a delivery, checks that the source sent it, records it in
the logbook, and only then answers. The logbook is its only way out: nothing
is handed to anything in-process, and downstream reads the logbook.

is_relay holds what every relay shares. A relay package (`is_github_relay`,
`is_slack_relay`, the Teams relay in `teams_module`) keeps only its source's
check and its source's parse.

## What a relay does, in order

1. **Refuse at the door.** Wrong path or method, a declared length over the
   cap, or a header check that fails: answer and drop the connection without
   reading the body (`_refuseUnread` in teams_module's `teams_relay.dart`;
   dart:io's `response.close()` would wait for the whole body).
2. **Read the body** under the cap and one deadline for the whole body, not a
   gap between chunks, so a sender trickling bytes can't hold it open.
3. **Check the delivery** with the source's check, which yields a
   `VerifiedDelivery` or a refusal (below).
4. **Filter.** The source's allowlist (Slack team, Teams tenant) and its wake
   set (event types worth recording). A quiet but authentic delivery is
   answered 200 and not recorded.
5. **Record** through is_logbook_client's `LogbookWriter.write`, as
   `<source>-event` via `encodeRelayedEvent` from is_docking_station_api.
6. **Answer.** `Written` or `AlreadyRecorded` → 2xx (plus a source's fixed
   response body, such as a Teams invoke response). Anything else → 5xx, so
   the source sends it again. The whole path stays inside the source's
   deadline (Teams resends after 15 seconds, Slack after 3).

is_relay owns steps 1, 2, 5 and 6, and the order. The source owns 3 and 4.

## The delivery check

```dart
abstract interface class ChecksDeliveries<S extends Object> {
  /// What the headers alone can decide, before the body is read.
  HeaderCheck<S> checkHeaders(Headers headers, DateTime now);

  /// The rest, given what the header check vouched for.
  DeliveryCheck checkBody(S vouched, Uint8List body);
}

sealed class DeliveryCheck {}
final class Verified extends DeliveryCheck { final VerifiedDelivery delivery; }
final class Quiet extends DeliveryCheck { /* authentic, not recorded; may carry a response body */ }
final class Refused extends DeliveryCheck { final int status; final String reason; }
```

`VerifiedDelivery` has a private constructor. is_relay makes one only inside
`Verified`, and a source gets one only by returning it from `checkBody`,
which the relay calls with the body it read. The recording step takes only a
`VerifiedDelivery`, so recording bytes that were never checked doesn't
compile.

**What a check vouches for differs by source, and the type says which.**

| Source | Check | Covers the body? |
| --- | --- | --- |
| GitHub | HMAC-SHA256 of the raw body | yes |
| Slack | HMAC-SHA256 of `v0:<timestamp>:<body>`, timestamp within 5 min | yes |
| Teams | Bot Framework JWT (RS256, Microsoft's keys); `serviceurl` claim and recipient matched to the activity | **no** |

`teams_gate.dart` says so itself: the token vouches for the sender, not the
body, and the Bot Connector reuses one token across many deliveries until it
expires. Someone holding a captured token can post any body with a matching
`serviceUrl` and recipient until it expires. No relay design closes that; it
is the protocol. So `VerifiedDelivery` carries a `Coverage`:

```dart
enum Coverage { bodySigned, senderOnly }
```

and the recorded entry is the same either way. What changes is what may be
built on it, which is the replay section's business.

## Replay

Two kinds of repeat:

- **Exact resends**: the source retrying (Slack after 3 s, Teams after 15 s,
  GitHub's Redeliver button), or someone replaying captured bytes.
- **Edited bodies**: possible only where the check doesn't cover the body
  (Teams, with a captured token).

### What the logbook gives for free

An entry's id is the sha256 of `<kind>\n<previous>\n<body>`, and writing the
same bytes again answers `AlreadyRecorded`. If a relay recorded only the
verified bytes, an exact resend would be refused as a duplicate forever,
across restarts and across every relay. Leads from the handover, checked:

- **The logbook keeps no arrival time.** Its 96 bytes per entry are three
  names: the previous entry, the hash of the writing code, and the object
  (is_logbook 0.3.1, `lib/is_logbook.dart`). So `at` in the body is the only
  record of when a relay took a delivery in.
- **`{"at", "bytes"}` is the docking station's format.** `RelayedEvent.read`
  returns null for any other body. Dropping `at` is a change to
  is_docking_station_api, which is the docking station session's to agree to.
- **Nothing outside tests reads `RelayedEvent.at`.** Not the docking station
  service, the Teams translator or the Slack translator (grep across the org,
  2026-11-24). teams_module's `record_event.dart` says what `at` is for: "each
  entry's own `at` keeps a resent event from being refused as a duplicate".
  That client mapped any `refused` to a 5xx, so a duplicate refusal would
  have made Teams retry forever. is_logbook_client answers `AlreadyRecorded`
  instead, which is a 2xx, so that reason is gone.
- **Slack retries change the signature but not the body** (slack-module-1e).
  slack_relay's signature-digest replay cache misses them; a body hash
  catches them.

### Proposal

Ask the docking station to make `at` optional in its format, or to drop it,
then record the verified bytes alone. Exact resends become `AlreadyRecorded`
for every relay with no cache. Arrival time is lost; each source carries its
own in the body (Teams `timestamp`, Slack `event_time`), which is when the
event happened rather than when it arrived, and nothing reads arrival today.

Until the docking station agrees, keep `{at, bytes}` and an in-memory seen
set keyed by a `ReplayKey`, which only a `VerifiedDelivery` can make:

- `bodySigned`: the sha256 of the verified bytes. Catches Slack retries,
  which the signature digest misses, and GitHub redeliveries.
- `senderOnly` (Teams): the source's own key from the body (conversation id,
  type, activity id, timestamp), as `teams_gate.dart` builds it today. It is
  unsigned, and that is no weaker than the token. Whoever can forge the key
  can already forge the body.

A seen set is forgotten on restart and on a 5xx, so a duplicate can still be
recorded twice. Downstream dedupes by the source's key. That holds today and
stays true under either option.

## The HTTP front

`RelayServer`: listens on loopback (default 127.0.0.1, port from config)
behind the TLS proxy, one path, POST only. It takes a `ChecksDeliveries`, the
writer (a function, `LogbookWriter(path).write` by default, so tests pass a
fake), a clock, the caps and deadlines, and a log. It logs one line per
request: the status and the reason, never the content.

No `/ws`, no `onEvent`. Those existed for when Intersyntactic ran on Nick's
laptop.

## Deploy

One shape for every relay: a `bin/` entry that builds the source's check from
the environment, a Dockerfile, and github_relay's `.github/workflows/publish.yml`
publishing a pinned image to GHCR for the box to pull. is_relay ships a
template Dockerfile and workflow in `deploy/`; each relay copies them. Missing
configuration (no secret, no bot app id) fails closed: the relay starts and
refuses everything, as all three gates do today.

## Not in is_relay

- Parsing a source's deliveries into its events (`slackRecordedEvent`,
  `teamsRecordedEvent`). That is the source package's, and the translators
  call it on the logbook's bytes.
- The sender table that lets each relay's user write its `<source>-event`
  kind. That belongs to the logbook.

## Review

`/cage-match` on every PR. A scheduled Fable security audit of is_relay and
each relay that uses it, and one on every release. The first audit question:
the Teams `senderOnly` coverage and what a captured token can do.

## Open questions

1. Will the docking station drop or relax `at`? (docking-station-9b)
2. Are Teams resends byte-identical? If not, exact-bytes dedupe doesn't help
   Teams, and the activity key stays.
3. Does a GitHub delivery need anything beyond HMAC? `webhook_gate.dart`
   accepted replay because its trigger was idempotent. Once deliveries reach
   the logbook and something acts on their contents, that condition flips,
   as its own comment says it would.
4. Should the header check also be able to refuse on Slack's timestamp before
   the body is read? Yes as designed. Confirm that nothing else needs the body
   to refuse early.
