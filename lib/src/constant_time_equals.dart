/// Comparing a signature a sender offered with the one computed.
library;

/// Whether [a] and [b] are equal, in time that depends only on their
/// length: a `==` on a digest stops at the first difference, so its timing
/// tells a guesser how many leading characters were right. Lengths are
/// compared first, since a digest's length is no secret.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}
