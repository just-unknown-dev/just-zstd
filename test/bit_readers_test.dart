// The two bit streams: forward, lowest bit first; backward, from the bit
// under the last byte's end mark down, 0s past the start.

import 'dart:typed_data';

import 'package:just_zstd/src/bit_readers.dart';
import 'package:test/test.dart';

void main() {
  group('ForwardBitReader', () {
    test('reads the lowest bits first, across bytes', () {
      final reader = ForwardBitReader(Uint8List.fromList([0xFF, 0x00]), 0, 2);
      expect(reader.read(4), 0x0F);
      expect(reader.read(4), 0x0F);
      expect(reader.read(8), 0x00);
      expect(reader.nextByte, 2);
    });

    test('single bits, and peeking without consuming', () {
      final reader = ForwardBitReader(Uint8List.fromList([0x05]), 0, 1);
      expect(reader.peek(3), 5);
      expect([reader.read(1), reader.read(1), reader.read(1)], [1, 0, 1]);
      expect(reader.nextByte, 1);
    });

    test('reading past the end is a FormatException', () {
      final reader = ForwardBitReader(Uint8List.fromList([0x05]), 0, 1);
      expect(() => reader.read(9), throwsA(isA<FormatException>()));
    });
  });

  group('BackwardBitReader', () {
    test('starts under the end mark and reads high bits first', () {
      // 0b0001_0110 0b1000_0001: the mark is the top bit of the last byte;
      // the stream below it is 0000001 then 00010110.
      final reader = BackwardBitReader(Uint8List.fromList([0x16, 0x81]), 0, 2);
      expect(reader.position, 15);
      expect(reader.read(7), 0x01);
      expect(reader.read(8), 0x16);
      expect(reader.position, 0);
      expect(reader.overflowed, isFalse);
    });

    test('past the start it gives 0s and goes negative', () {
      final reader = BackwardBitReader(Uint8List.fromList([0x03]), 0, 1);
      expect(reader.read(3), 0x4); // the one bit 1, then two 0s
      expect(reader.position, -2);
      expect(reader.overflowed, isTrue);
      expect(reader.read(4), 0);
    });

    test('reads up to 31 bits at once', () {
      // 31 bits under the mark: 0x12345678.
      final data = Uint8List.fromList([0x78, 0x56, 0x34, 0x92]);
      final reader = BackwardBitReader(data, 0, 4);
      expect(reader.readLong(31), 0x12345678);
      expect(reader.position, 0);
    });

    test('an empty stream, or one with no end mark, is refused', () {
      expect(
        () => BackwardBitReader(Uint8List(2), 1, 1),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => BackwardBitReader(Uint8List.fromList([1, 0]), 0, 2),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
