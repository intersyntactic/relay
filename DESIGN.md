# is_relay: design

A relay is the public entry point for one outside source (GitHub, Slack,
Teams). It takes a delivery, checks that the source sent it, records it in
the logbook, and only then answers. The logbook is its only way out: nothing
is handed to anything in-process, and downstream reads the logbook.

is_relay holds what every relay shares. A relay package (`is_github_relay`,
`is_slack_relay`, the Teams relay in `teams_module`) keeps only its source's
check and its source's parse.

After three strikes (TEMPER.md). Round 3's findings are folded in.

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

Each request runs inside **one monotonic budget per source**, shorter than
the source's own deadline: Slack's 3 s, Teams' 15 s, GitHub's 10 s. The
budget bounds the whole request, and nothing a request starts outlives it:

- **Keys are never fetched on a request.** The Teams key set is refreshed in
  the background and read from memory. With no key set yet, the answer is
  503 at the door (as teams_relay does today).
- **The body read is cancelled** at the budget: the socket is destroyed.
- **The check is synchronous, CPU-bound work** on a body no larger than the
  cap: an HMAC, or an RS256 verify and a JSON parse. Its time is bounded by
  the cap, not by a timer.
- **The write's timeout is the budget remaining**, passed to
  is_logbook_client, so the client destroys the socket when the budget
  ends. A write the logbook commits just before that may still land after
  the 5xx. A retry, if any, then leaves a second entry with the same
  `EventKey`, which the docking station decides once.

So a request's in-flight permit is released when its budget ends at the
latest, and the in-flight cap bounds all unfinished work.

1. **Refuse at the door**, with a non-2xx, without reading the body: wrong
   path or method, a declared length over the cap, the in-flight cap full,
   no key set yet, or a header check that fails. Answer and drop the
   connection (`_refuseUnread` in teams_module's `teams_relay.dart`;
   dart:io's `response.close()` would wait for the whole body). A body
   refused partway (too large, too slow) is dropped the same way. Its
   subscription is paused, not cancelled, because cancelling separates
   dart:io's request from its response and the socket can no longer be
   taken.
2. **Read the body** under the cap and the budget into a buffer the relay
   owns. The check gets an unmodifiable view of it (`asUnmodifiableView()`),
   so the bytes written are the bytes checked.
3. **Check** it with the source's check (below). Then take room from the
   source's **write-rate bound**, or answer 429. This comes after the check
   so that only authentic deliveries spend the bound. At the door, an
   unauthenticated sender could use it up and shut out the source.
4. **Write** it through is_logbook_client's `LogbookWriter.write`, as
   `<source>-event` via `encodeRelayedEvent`.
5. **Answer.** `Written` or `AlreadyRecorded` → 2xx, with the check's
   response body if it gave one (a Teams invoke response, Slack's
   url_verification challenge). Anything else, or the budget running out →
   5xx. `Refuse` → its status, never 2xx. Those are the only answers: **no
   2xx without a write.**

### When a failure is retried, by source

A 5xx asks the source to try again, and not every source does:

- **Slack** retries up to three times, with backoff.
- **Teams** resends after 15 s.
- **GitHub never redelivers on its own.** A failed delivery stays failed
  until someone redelivers it. The GitHub relay therefore carries a
  **redelivery sweep** (owner: the GitHub relay's module). Every few minutes
  it lists the hook's recent deliveries through GitHub's REST API
  (`GET /repos/{o}/{r}/hooks/{id}/deliveries`) and redelivers each failed one
  (`POST …/deliveries/{id}/attempts`). A redelivery is the same signed
  bytes, so it lands through the same front door and the same check. Its
  `EventKey`, the sha256 of the bytes, makes a sweep that redelivers twice
  harmless. The sweep holds a GitHub token, so it runs in its own process
  and the relay itself never does.

is_relay owns every step and the order. The source supplies only the check.

## The delivery check

```dart
abstract interface class ChecksDeliveries<V extends Object> {
  /// What the headers alone decide, before the body is read.
  HeaderCheck<V> checkHeaders(Headers headers, DateTime now);

  /// The rest, given what the header check vouched for. [body] can't be
  /// written to. Returns a verdict, never bytes.
  BodyVerdict checkBody(V vouched, Uint8List body);
}

sealed class BodyVerdict {}
final class Record extends BodyVerdict { final JsonObject? response; }
final class Refuse extends BodyVerdict { final int status; final String reason; }  // status is never 2xx
```

Every authentic delivery is `Record`, Slack's `url_verification` included:
it is written, and its translator returns `NothingToAdmit`. A `Record`'s
response body goes out only with a `Written` or `AlreadyRecorded`.

The check returns a verdict. It doesn't return bytes. On `Record`, the
relay writes **the buffer it read**, which the check saw only through a view
it couldn't write to. The relay is the only thing that holds a writer and
the buffer. No source package can substitute or alter the bytes. That isn't
a proof the check did its cryptography right. That's what review and the
audit are for.

The relay has no wake filter, so outside the check nothing reads
uncovered data. For GitHub that matters: `X-GitHub-Event` is a header
outside the HMAC, and a filter on it would let a replayer relabel a signed
body (`webhook_gate.dart` says so). A Teams check does read uncovered
data, the activity's `serviceUrl` and recipient, to match them to the token.
That read happens inside the check and decides only authenticity.

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

**Where a capture happens.** TLS from Microsoft, Slack and GitHub ends at
the box's TLS proxy, and the hop from the proxy to the relay on loopback is
cleartext. So the place a token or a body can be captured is **the box**:
the proxy, its logs, and the loopback hop. Breaking TLS on the internet is
not the only way. The deploy therefore requires that the proxy keeps no
`Authorization` header and no request body in any log. Only root and the
relay's user can read that hop.

The proxy also bounds what the relay can't. dart:io's `HttpServer` has no
timeout on reading request headers. A sender that trickles headers never
reaches the relay's handler, so the in-flight cap can't count it, and enough
such senders would exhaust the box's sockets. The proxy's header-read
timeout and connection limits are the bound.

**What the proxy actually does** (Caddy v2.11.7, audited on 2026-11-24
against `enspyrco/infra` `caddy/Caddyfile` and 14 days of logs).
The relay vhosts are bare `reverse_proxy` blocks, and no access log is
configured. Caddy logs a request's headers only when a handler errors, and it
redacts `Authorization` by default (`log_credentials` is unset). Other
headers, `X-Slack-Signature` among them, do appear in clear, but no body
ever does, so a captured signature can't be replayed without its body. No
body is logged, mirrored or buffered. The header-read timeout is 1 minute,
and a body that stalls is cut after 1 minute idle. Neither limit is in the
Caddyfile, though: both are defaults of an unpinned `caddy:2-alpine` image,
and there's no cap on total body-read time or size. The fix belongs in
`enspyrco/infra`: set these timeouts and `max_header_size` explicitly, pin
the image, and rotate the docker logs. Until that lands, this rule rests on
an image's defaults rather than on config in the repo.

- **Approvals through Teams rest on the token staying private** (accepted by
  Nick, 2026-11-24; owners: teams_module and agent_loop). A captured Bot
  Connector token can carry any body until it expires, including one that
  reuses an honest activity's key ahead of it. `ShownMessageJudged.from`
  becomes NodeApproval/NodeCorrection in agent_loop, and `MessageChanged.from`
  drives withdrawal, so with a captured token both can name anyone. Accepted
  because a capture needs the box (above) and the token expires. The
  alternative, stopping a sender-only source from emitting them, would end
  approvals from Teams. This is the Fable audit's first target.
- **Replays and floods each write a permanent entry** (owner: is_relay).
  With `at` in every body, each exact replay is a new entry, and a captured
  Teams token can write distinct ones. The logbook only grows. A coarse
  per-source write-rate bound, checked after the check, caps both. Its cost is
  the cost of any flood bound: while one source is flooded, its honest
  deliveries are refused too. Slack drops them after three retries, Teams
  after its resends, and GitHub's go to the redelivery sweep. Don't "fix"
  that by raising the bound until it means nothing. Bytes-only bodies would
  make exact replays free, but they stay an optimisation (see "Storage").
- **GitHub has no signed time** (owner: is_relay). A body captured and never
  delivered to us is accepted once, whenever it is replayed. A body captured
  after it was delivered is a no-op, because its `EventKey` is the sha256 of
  its bytes. Slack's five-minute window makes the same capture harmless; for
  GitHub, the proxy's no-body logging rule is the whole defence.

## The HTTP front

`RelayServer`: listens on loopback (default 127.0.0.1, port from config)
behind the TLS proxy, one path, POST only. It takes a `ChecksDeliveries`, the
logbook's write socket (a `LogbookSocket`), a clock, the budget, the body cap,
the cap on requests in flight (each held until its budget ends), the
per-source write-rate bound, and a log. It logs one line per request: the
status and the reason, never the content.

The relay writes through its own `LogbookWriter`, not an injected function.
That writer's timeout is the budget remaining, and it destroys its socket
when the timeout runs out, so no write outlives its request. An injected
writer can't promise that. Tests run a fake logbook on a Unix socket that
speaks the real wire protocol.

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

