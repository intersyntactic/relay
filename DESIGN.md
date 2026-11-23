# is_relay: design

A relay is the public entry point for one outside source (GitHub, Slack,
Teams). It takes a delivery, checks that the source sent it, records it in
the logbook, and only then answers. The logbook is its only way out: nothing
is handed to anything in-process, and downstream reads the logbook.

is_relay holds what every relay shares. A relay package (`is_github_relay`,
`is_slack_relay`, the Teams relay in `teams_module`) keeps only its source's
check and its source's parse.

Round 3, after two strikes (TEMPER.md; all four families RECAST both
times).

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

So is_relay has **no seen set, no replay key and no wake filter.** Every
authentic delivery is written and answered on its own write. Deciding what
is worth acting on belongs to the translator, which returns `NothingToAdmit`
for what it ignores. A duplicate costs
one logbook entry, or none when its bytes match an earlier entry exactly
(see "Storage").

## What a relay does, in order

All of it runs inside **one monotonic budget per source**, shorter than the
source's resend deadline: Slack's 3 s, Teams' 15 s, GitHub's 10 s. Fetching
keys (Teams), reading the body, the check and the logbook write all share
it. The relay doesn't give each step its own timeout.

A request holds its in-flight permit until its write **settles**, not until
it answers: until the writer replies, or is_logbook_client's own timeout
destroys the socket. When the budget runs out, the source gets a 5xx at
once, but the permit stays held. So the in-flight cap bounds unfinished
writes as well as open requests, and a slow logbook turns into refusals at
the door, not a pile of orphaned writes.

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
   5xx, so the source sends it again. A write that lands after its 5xx
   leaves a second entry with the same `EventKey` when the retry lands too.
   The docking station decides it once.

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
final class Handshake extends BodyVerdict { final JsonObject response; }
final class Refuse extends BodyVerdict { final int status; final String reason; }
```

`Handshake` is for a protocol exchange that carries no event, such as
Slack's `url_verification`. It is answered and not recorded. It isn't a way
to skip "quiet" events: an authentic event is always `Record`.

The check returns a verdict. It doesn't return bytes. On `Record`, the
relay writes **the snapshot it read and handed to the check**. Nothing else
can be written, because the relay is the only thing that holds a writer and
the snapshot. No source package can hand it different bytes. That isn't a
proof the check did its cryptography right. That's what review and the
audit are for.

With no wake filter, nothing in the relay reads uncovered data to decide
anything. That matters for GitHub. `X-GitHub-Event` is a header outside the
HMAC, and a filter on it would let a replayer relabel a signed body
(`webhook_gate.dart` says so).

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

- In a genuine Teams activity, the Bot Connector sets `from` from the signed-in
  user, so `from` and `addressedTo` are Microsoft's word. Card values and
  invoke data, including the trajectory id a Close carries, are the user's
  content. **With a captured token, all of it is the token holder's**: the
  JWT doesn't bind the body, so `from` is no harder to forge than a card
  value. The docking station's own decisions never read `from`. Downstream
  readers do, in two places: `ShownMessageJudged.from` (who approved, turned
  into NodeApproval/NodeCorrection in agent_loop) and the withdrawal rule
  for `MessageChanged`. That approval path is the Fable audit's first
  target.
- GitHub's event kind is **not recorded**. The translator classifies from
  the signed body alone, and a body that isn't unambiguously one shape it
  knows is `NothingToAdmit`. `issues` and `issue_comment` both carry
  `issue`, so "unambiguously" is part of the job. A label in the record
  would let whatever arrived first choose the meaning, and no proof that the
  parsers are disjoint would be worth the format change. `NothingToAdmit`
  carries no `EventKey`, so a delivery that admitted nothing consumes
  nothing.

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
- **Approvals through Teams rest on the token staying private** (accepted by
  Nick, 2026-11-24; owners: teams_module and agent_loop).
  `ShownMessageJudged.from` becomes NodeApproval/NodeCorrection in agent_loop,
  and `MessageChanged.from` drives withdrawal. With a captured token, both
  can name anyone. Accepted because a capture needs a TLS break between
  Microsoft and the relay, and the token expires. The alternative, stopping
  a sender-only source from emitting them, would end approvals from Teams.
  This is the Fable audit's first target.
- **Replays and floods each write a permanent entry** (owner: is_relay).
  With `at` in every body, each exact replay is a new entry, and a captured
  Teams token can write distinct ones. The logbook only grows. A coarse
  per-source write-rate bound in `RelayServer` caps both. Bytes-only bodies
  would make exact replays free, but they stay an optimisation (see
  "Storage").
- **GitHub has no signed time** (owner: is_relay). A captured body that was
  never delivered to us is accepted once. One that was delivered is a no-op,
  because its `EventKey` is the sha256 of its bytes. Capturing one needs a
  position inside GitHub's TLS to us.

## The HTTP front

`RelayServer`: listens on loopback (default 127.0.0.1, port from config)
behind the TLS proxy, one path, POST only. It takes a `ChecksDeliveries`, the
writer (a function, `LogbookWriter(path).write` by default, so tests pass a
fake), a clock, the budget, the body cap, the cap on requests in flight
(held until each write settles), the per-source write-rate bound, and a
log. It logs one line per request: the status and the reason, never the
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

1. Are Teams resends byte-identical? Not needed for correctness any more,
   but it decides whether the storage optimisation helps Teams.

