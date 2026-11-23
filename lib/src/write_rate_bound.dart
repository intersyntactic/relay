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
  WriteRateBound({
    required this.perMinute,
    required this.burst,
    DateTime Function() now = DateTime.now,
  }) : assert(perMinute > 0 && burst > 0, 'a bound that admits nothing'),
       _now = now,
       _tokens = burst.toDouble(),
       _at = now();

  /// The steady rate, in writes per minute.
  final int perMinute;

  /// The most writes taken together after a quiet spell.
  final int burst;

  final DateTime Function() _now;
  double _tokens;
  DateTime _at;

  /// Takes one write's room, or says there is none.
  bool take() {
    final now = _now();
    final elapsed = now.difference(_at);
    _at = now;
    // A clock stepped backwards refills nothing, rather than a negative
    // amount that would starve the bucket.
    if (!elapsed.isNegative) {
      _tokens = (_tokens + elapsed.inMicroseconds * perMinute / 60e6).clamp(
        0,
        burst.toDouble(),
      );
    }
    if (_tokens < 1) return false;
    _tokens -= 1;
    return true;
  }

  /// Gives back the room a [take] took, for a write that didn't record.
  void giveBack() => _tokens = (_tokens + 1).clamp(0, burst.toDouble());
}
