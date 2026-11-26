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
