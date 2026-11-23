/// What every Intersyntactic relay shares: take a delivery from an outside
/// source, check it with the source's check, record it in the logbook, and
/// only then answer. The logbook is a relay's only way out.
library;

export 'src/checks_deliveries.dart';
export 'src/relay_server.dart' show RelayServer, WritesEntry, writerAt;
export 'src/write_rate_bound.dart';
