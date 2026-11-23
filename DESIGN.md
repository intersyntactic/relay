# is_relay: design

A relay is the public entry point for one outside source (GitHub, Slack,
Teams). It takes a delivery, checks that the source sent it, records it in
the logbook, and only then answers. The logbook is its only way out: nothing
is handed to anything in-process, and downstream reads the logbook.

is_relay holds what every relay shares. A relay package (`is_github_relay`,
`is_slack_relay`, the Teams relay in `teams_module`) keeps only its source's
check and its source's parse.

Round 2, after the first strike (TEMPER.md, all four families RECAST).

## What the relay owns, and what it doesn't

The relay owns **authenticity**: this delivery came from the source. It
does not own **idempotence**, meaning a delivery is not acted on twice. The
docking station already does: each module's translator gives every event an
`EventKey`, "what 'not decided twice' compares … the same for two events
that record one thing, as a redelivery does" (is_docking_station_api,
`translated_event.dart`). A relay restarts and answers 5xx, so it could never
own idempotence anyway. Its in-memory seen set made things worse: a
duplicate answered 200 from "seen" while the original's write was still
pending could end the source's retries for an event that then failed to
record. teams_relay has that race today.

So is_relay has **no seen set and no replay key.** Every authentic delivery
in the wake set is written, and answered on its own write. A duplicate costs
one logbook entry, or none when its bytes match an earlier entry exactly
(see "Storage").

## What a relay does, in order

All of it runs inside **one monotonic budget per source**, shorter than the
source's resend deadline: Slack's 3 s, Teams' 15 s, GitHub's 10 s. The body
read, the check and the logbook write share it. The relay doesn't give each
step its own timeout.

1. **Refuse at the door.** Wrong path or method, a declared length over the
   cap, too many requests in flight, or a header check that fails: answer and
   drop the connection without reading the body (`_refuseUnread` in
   teams_module's `teams_relay.dart`; dart:io's `response.close()` would wait
   for the whole body).
2. **Read the body** under the cap and the budget into one immutable
   snapshot that the relay owns.
3. **Check** the snapshot with the source's check (below).
4. **Write** the snapshot through is_logbook_client's `LogbookWriter.write`,
   as `<source>-event` via `encodeRelayedEvent`.
5. **Answer.** `Written` or `AlreadyRecorded` → 2xx, plus the source's fixed
   response body if it has one (a Teams invoke response, Slack's
   url_verification challenge). Anything else, or the budget running out →
   5xx, so the source sends it again. When the budget runs out mid-write, the
   write may still land. That's safe: the retry is `AlreadyRecorded` or a
   second entry with the same `EventKey`.

is_relay owns every step and the order. The source supplies only the check.

## The delivery check

```dart
abstract interface class ChecksDeliveries<V extends Object> {
  /// What the headers alone decide, before the body is read.
  HeaderCheck<V> checkHeaders(Headers headers, DateTime now);

  /// The rest, given what the header check vouched for. Returns a verdict,
  /// never bytes.
  BodyVerdict checkBody(V vouched, Uint8List body);
}

sealed class BodyVerdict {}
final class Record extends BodyVerdict { final JsonObject? response; }
final class Answer extends BodyVerdict { final JsonObject? response; }  // authentic, not recorded
final class Refuse extends BodyVerdict { final int status; final String reason; }
```

The check returns a verdict. It doesn't return bytes. On `Record`, the
relay writes **the snapshot it read and handed to the check**. Nothing else
can be written, because the relay is the only thing that holds a writer and
the snapshot. No source package can hand it different bytes. That isn't a
proof the check did its cryptography right. That's what review and the
audit are for.

**The wake decision reads only what the check covers.** GitHub's HMAC covers
the body and nothing else, and `X-GitHub-Event` is a header. A filter on
that header lets a replayer relabel a signed body (`webhook_gate.dart` says
so). So the GitHub relay records every HMAC-valid delivery and leaves
classification to the translator. Slack's event type is inside the signed
bytes, so a Slack filter is fine. Teams' type is in the body, which only the
token vouches for (next section).

## What a check vouches for

| Source | Check | Covers |
| --- | --- | --- |
| GitHub | HMAC-SHA256 of the raw body | the body. Not the event-kind header, not a time |
| Slack | HMAC-SHA256 of `v0:<timestamp>:<body>`, timestamp within 5 min | the body and the time |
| Teams | Bot Framework JWT (RS256, Microsoft's keys), `serviceurl` claim and recipient matched to the activity | **the sender only**: the Bot Connector, for this bot, on this service URL |

Coverage is a fixed fact of each source, so the entry's kind
(`teams-event`) already says it. The relay doesn't carry a separate enum.
What matters is how the docking station reads it, and that goes in the
translator contract:

- A `teams-event` body's `from`, card values and invoke payloads are what a
  captured-token holder can write. They are **testimony of the Bot Connector
  session, not of the person named**. The verified facts are `addressedTo`
  (the token's audience) and `replyEndpoint` (its service URL). Anything
  that admits an approval or a close on `from` accepts that trust model, and
  has to say so.
- GitHub's uncovered context (the event kind) reaches the translator, if at
  all, through a field named as unsigned. That field is a format question
  for the docking station (open question 1). Until it's answered, the GitHub
  translator classifies from the body.

## Storage

`{"at", "bytes"}` stays: it is the docking station's format, and nothing
about correctness depends on changing it. With `at`, every write is a new
entry, so a resend is a second entry with the same `EventKey`, which the
docking station decides once.

Recording the bytes alone, with no `at`, would make an exact resend
`AlreadyRecorded` and save the entry. That is an **optional storage
optimisation**, not protection. It only holds while every relay writes
`previous` as `-` (each event starts its own chain). Correctness must not
rest on it.

## Named tradeoffs

- **A captured Teams token is a write capability until it expires** (owner:
  teams_module and the docking station's trust rules). A captured token can
  carry any body, including one that reuses an honest activity's key ahead
  of it. The protocol doesn't let a relay close that. Mitigations: TLS to
  the relay, the token's short life, and the trust rule above. This is the
  first question for the Fable audit.
- **GitHub has no signed time** (owner: is_relay). A captured body that was
  never delivered to us is accepted once. One that was delivered is a no-op,
  because its `EventKey` is the sha256 of its bytes. Capturing one needs a
  position inside GitHub's TLS to us.

## The HTTP front

`RelayServer`: listens on loopback (default 127.0.0.1, port from config)
behind the TLS proxy, one path, POST only. It takes a `ChecksDeliveries`, the
writer (a function, `LogbookWriter(path).write` by default, so tests pass a
fake), a clock, the budget, the body cap, the cap on requests in flight, and
a log. It logs one line per request: the status and the reason, never the
content.

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

- Parsing a source's deliveries into events, and choosing each event's
  `EventKey`. Both belong to the source's module, and its translator reads
  the logbook's bytes.
- The sender table that lets each relay's user write its `<source>-event`
  kind. That belongs to the logbook.

## Review

`/cage-match` on every PR. A scheduled Fable security audit of is_relay and
each relay that uses it, plus one on every release.

## Open questions

1. GitHub's event kind: an optional, explicitly unsigned field in the
   docking station's format, or classify from the body? (Asked of
   docking-station-9b.)
2. Does any admission rest on a Teams `from` in a way that matters? (Asked of
   docking-station-9b. Also the audit's first question.)
3. Are Teams resends byte-identical? Not needed for correctness any more,
   but it decides whether the storage optimisation helps Teams.
