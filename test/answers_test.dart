import 'package:is_relay/is_relay.dart';
import 'package:test/test.dart';

void main() {
  group('RefusalStatus', () {
    test('ofCode finds every refusal by its code', () {
      for (final s in RefusalStatus.values) {
        expect(RefusalStatus.ofCode(s.code), s);
      }
    });

    test('ofCode is null for a recorded answer and for unknown codes', () {
      expect(RefusalStatus.ofCode(200), isNull);
      expect(RefusalStatus.ofCode(0), isNull);
      expect(RefusalStatus.ofCode(502), isNull);
    });

    test('codes are distinct, so ofCode is unambiguous', () {
      final codes = RefusalStatus.values.map((s) => s.code).toList();
      expect(codes.toSet(), hasLength(codes.length));
    });

    test('a refusal from the relay\'s state is worth another try', () {
      final retried = {
        for (final s in RefusalStatus.values)
          if (s.worthAnotherTry) s.code,
      };
      expect(retried, {408, 429, 500, 503});
    });
  });

  group('constantTimeEquals', () {
    test('equal strings are equal', () {
      expect(constantTimeEquals('abc123', 'abc123'), isTrue);
      expect(constantTimeEquals('', ''), isTrue);
    });

    test('a difference anywhere is unequal', () {
      expect(constantTimeEquals('abc123', 'xbc123'), isFalse);
      expect(constantTimeEquals('abc123', 'abc12x'), isFalse);
    });

    test('different lengths are unequal', () {
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
      expect(constantTimeEquals('abcd', 'abc'), isFalse);
    });
  });
}
