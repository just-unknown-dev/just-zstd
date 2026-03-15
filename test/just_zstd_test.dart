import 'package:test/test.dart';
import 'package:just_zstd/just_zstd.dart';

void main() {
  group('BitReader', () {
    test('reads bits correctly', () {
      final reader = BitReader([0xFF, 0x00]);
      expect(reader.readBits(4), equals(0x0F));
      expect(reader.readBits(4), equals(0x0F));
      expect(reader.readBits(8), equals(0x00));
    });

    test('reads single bit', () {
      final reader = BitReader([0x05]); // 0b00000101
      expect(reader.readBit(), equals(1));
      expect(reader.readBit(), equals(0));
      expect(reader.readBit(), equals(1));
    });
  });

  group('ZstdDecoder', () {
    test('throws on invalid magic number', () {
      expect(
        () => const ZstdDecoder().decode([0, 0, 0, 0]),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws on input too short', () {
      expect(
        () => const ZstdDecoder().decode([0, 0]),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
