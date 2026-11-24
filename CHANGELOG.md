## 0.2.0

- `RefusalStatus.worthAnotherTry` says whether sending the same bytes again may be recorded (408, 429, 500 and 503 yes; the rest no), and `RefusalStatus.ofCode` reads a status back. `RelayServer` now answers only 200 or a `RefusalStatus`, so a redelivery sweep can read these instead of guessing from the number.
- `constantTimeEquals`, for comparing a signature a sender offered with the one computed. Relays had their own copies.

## 0.1.0

- `ChecksDeliveries`, the check a source supplies, and `RelayServer`, which refuses at the door, reads under a cap and a budget, checks, records in the logbook through is_logbook_client, and answers 2xx only once the delivery is recorded.
- `WriteRateBound`, a per-source bound on recorded deliveries.
