## 0.8.0

- Requires is_docking_station_api ^0.11.0 (was ^0.10.0), so a module on 0.11, whose `MessageSaid` carries `forTheAgent`, can hold is_relay. `RelayedEventSource`, `encodeRelayedEvent` and the relayed entry are unchanged; 0.11.0 changed only decision and translated-event entries. A minor bump: `ChecksDeliveries.source` exposes `RelayedEventSource`.

## 0.7.0

- Requires checked_json ^0.4.0 (was ^0.3.0) and is_docking_station_api ^0.10.0 (was ^0.9.0). `RelayedEventSource`, `encodeRelayedEvent` and the relayed entry are unchanged. A minor bump: `ChecksDeliveries.source` exposes `RelayedEventSource`.
- checked_json 0.4.0 refuses a value JSON can't carry where a `JsonObject` is built, so a check that builds one (a `DateTime` in a projection or response) now throws a `JsonFieldException` inside the check. It is still answered 500 before anything is written, logged as `body check threw JsonFieldException`. Before, the relay found it when encoding.
- The relay's own encode guard keeps only its 64-level depth bound. The non-JSON checks and the 2^20-value bound are gone: checked_json copies a `JsonObject` all the way down, so nothing in one is shared and it is exactly as large as what the check built.
- A check that wrote `const JsonObject.of(...)` drops the `const`, as checked_json 0.4.0 requires.

## 0.6.0

- Requires checked_json ^0.3.0 (was ^0.2.1) and is_docking_station_api ^0.9.0 (was ^0.8.0), so a tree that holds is_relay can move to the checked_json that refuses duplicate keys. is_relay never decodes JSON text, so checked_json's new refusals don't reach it. `RelayedEventSource`, `encodeRelayedEvent` and the relayed entry's `{"at","bytes"}` are unchanged, and the logbook entry is the same. A minor bump for the same reason as 0.3.0: `ChecksDeliveries.source` exposes `RelayedEventSource`.

## 0.5.1

- Requires is_logbook_client ^0.4.0 (was ^0.3.0), so a tree that holds is_relay can lock the client that reads an is_logbook 0.5.0 service. is_relay only writes, and 0.4.0 changed only `subscribe`, `get` and `Entry`; the write and its `WriteResult` cases are the same. No is_logbook_client type is in is_relay's API, so this is a patch.

## 0.5.0

- `ChecksAndProjectsDeliveries` and `RelayServer.projecting`, for a source whose deliveries mustn't be recorded as they arrived because they can carry credentials in fields no list could name (a Teams activity's open `value`). Its `checkBody` returns a `ProjectedVerdict`: `RecordProjection(projection, response:)` or `Refuse`. It has no `Record`, so a projecting source can't fall back to recording the raw body. The relay encodes the projection as JSON, and the logbook entry keeps its shape.
- `ChecksDeliveryHeaders`, the header half both kinds of check share. `ChecksDeliveries` now implements it; its members are unchanged.
- A projection or `Record` response that JSON can't carry (a `DateTime`, a non-finite double, nesting past 64 levels) is answered 500 before anything is written. It used to throw an `Error` from `jsonEncode` and end the process, and a response was encoded only after the write.
- The body read keeps back the 250 ms an answer needs, as the write already did, so a refusal after a slow body lands inside the budget.
- `RelayServer.defaultMaxBodyBytes` and `defaultMaxInFlight`, shared by both constructors.
- Breaking: `RelayServer.check` is now typed `ChecksDeliveryHeaders<V>`, and `Record` and `Refuse` implement their sealed verdict types instead of extending `BodyVerdict`. A relay that only implements `ChecksDeliveries` and constructs `RelayServer(check: ...)` needs no change.

## 0.4.0

- Requires is_docking_station_api ^0.8.0 (was ^0.7.0). 0.8.0 depends on is_conversation_reply_vocabulary, the renamed is_reply_vocabulary, so a tree that holds is_relay can now move to the new name. Nothing is_relay uses changed, and the logbook entry is the same. A minor bump for the same reason as 0.3.0: `ChecksDeliveries.source` exposes `RelayedEventSource`.

## 0.3.0

- Requires is_docking_station_api ^0.7.0 (was ^0.4.0), so a relay can share a dependency graph with modules that use 0.7.0's reply endpoints. Nothing is_relay uses changed: `RelayedEventSource` and `encodeRelayedEvent` are the same, and the logbook entry it writes is byte-for-byte the same. A minor bump because `ChecksDeliveries.source` exposes `RelayedEventSource`, so a relay moving to this version moves its own is_docking_station_api too.

## 0.2.0

- `RefusalStatus.worthAnotherTry` says whether sending the same bytes again may be recorded (408, 429, 500 and 503 yes; the rest no), and `RefusalStatus.ofCode` reads a status back. `RelayServer` now answers only 200 or a `RefusalStatus`, so a redelivery sweep can read these instead of guessing from the number.
- `constantTimeEquals`, for comparing a signature a sender offered with the one computed. Relays had their own copies.

## 0.1.0

- `ChecksDeliveries`, the check a source supplies, and `RelayServer`, which refuses at the door, reads under a cap and a budget, checks, records in the logbook through is_logbook_client, and answers 2xx only once the delivery is recorded.
- `WriteRateBound`, a per-source bound on recorded deliveries.
