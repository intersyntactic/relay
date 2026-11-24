## 0.1.0

- `ChecksDeliveries`, the check a source supplies, and `RelayServer`, which refuses at the door, reads under a cap and a budget, checks, records in the logbook through is_logbook_client, and answers 2xx only once the delivery is recorded.
- `WriteRateBound`, a per-source bound on recorded deliveries.
