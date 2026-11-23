/// A bound on how many deliveries one source may record in a span of time.
library;

/// A token bucket: up to [burst] writes at once, refilled at [perMinute].
///
/// The logbook only grows, so a flood of authentic deliveries (exact
/// replays, which a fresh `at` makes new entries, or new bodies under a
/// captured token) would grow it without limit. This caps that. Its cost is
/// any flood bound's: while a source is flooded, its honest deliveries are
/// refused too, and the source retries or drops them.
final class WriteRateBound {
  /// [elapsed] is a monotonic clock, time since some fixed start: a wall
  /// clock stepped forward would refill the bucket with time that never
  /// passed. A started [Stopwatch] unless given.
  WriteRateBound({
    required this.perMinute,
    required this.burst,
    Duration Function()? elapsed,
  }) : assert(perMinute > 0 && burst > 0, 'a bound that admits nothing'),
       _elapsed = elapsed ?? (Stopwatch()..start()).elapsedFunction,
       _tokens = burst.toDouble() {
    _at = _elapsed();
  }

  /// The steady rate, in writes per minute.
  final int perMinute;

  /// The most writes taken together after a quiet spell.
  final int burst;

  final Duration Function() _elapsed;
  double _tokens;
  late Duration _at;

  /// Takes one write's room, or says there is none.
  bool take() {
    final now = _elapsed();
    _tokens = (_tokens + (now - _at).inMicroseconds * perMinute / 60e6).clamp(
      0,
      burst.toDouble(),
    );
    _at = now;
    if (_tokens < 1) return false;
    _tokens -= 1;
    return true;
  }

  /// Gives back the room a [take] took, for a write certainly not recorded.
  void giveBack() => _tokens = (_tokens + 1).clamp(0, burst.toDouble());
}

extension on Stopwatch {
  Duration Function() get elapsedFunction =>
      () => elapsed;
}
