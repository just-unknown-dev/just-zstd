// XXH64, which checks a frame's content: known values, and the 64-bit form
// (VM, Wasm) agreeing with the 32-bit-halves form (web) at every length a
// stripe, a lane and a tail can make.

import 'dart:math';
import 'dart:typed_data';

import 'package:just_zstd/src/xxhash64.dart';
import 'package:test/test.dart';

import 'recipes.dart';

void main() {
  int halves(List<int> bytes) {
    final data = Uint8List.fromList(bytes);
    final (hi, lo) = xxh64Halves(data, 0, data.length);
    return (hi << 32) | lo;
  }

  int native(List<int> bytes) {
    final data = Uint8List.fromList(bytes);
    return xxh64(data, 0, data.length);
  }

  test('known values', () {
    // The xxHash reference values for seed 0. Their low halves are what
    // libzstd writes as the checksums of these contents.
    final cases = {
      '': (0xEF46DB37 << 32) | 0x51D8E999,
      'a': (0xD24EC4F1 << 32) | 0xA98C6E5B,
      'abc': (0x44BC2CF5 << 32) | 0xAD770999,
    };
    for (final MapEntry(key: text, value: hash) in cases.entries) {
      expect(native(text.codeUnits), hash, reason: '"$text"');
      expect(halves(text.codeUnits), hash, reason: '"$text"');
    }
  });

  test('both forms agree at every length up to 100, and at random', () {
    final random = Random(1);
    final bytes = [for (var i = 0; i < 4096; i++) random.nextInt(256)];
    for (var n = 0; n <= 100; n++) {
      expect(halves(bytes.sublist(0, n)), native(bytes.sublist(0, n)));
    }
    for (var i = 0; i < 50; i++) {
      final start = random.nextInt(2000);
      final slice = bytes.sublist(start, start + random.nextInt(2000));
      expect(halves(slice), native(slice));
    }
  });

  test("the low half matches libzstd's checksum of a frame", () {
    // text_30k_level3.zst ends with the low 32 bits of the XXH64 of its
    // 30,000-byte content.
    final frame = fixture('text_30k_level3.zst');
    final stored = ByteData.sublistView(
      frame,
    ).getUint32(frame.length - 4, Endian.little);
    final content = build([
      ['text', 30000, 3],
    ]);
    expect(xxh64Low32(content, 0, content.length), stored);
    expect(halves(content) & 0xFFFFFFFF, stored);
  });
}
