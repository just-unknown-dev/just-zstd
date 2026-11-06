// ZstdEncoder writes frames any Zstandard decoder reads. 0.2.0 marked its
// 4-byte content size as a 2-byte one, so no decoder could read them.

import 'dart:typed_data';

import 'package:just_zstd/just_zstd.dart';
import 'package:test/test.dart';

import 'recipes.dart';

void main() {
  const encoder = ZstdEncoder();
  const decoder = ZstdDecoder();

  test('writes the frame libzstd reads', () {
    // libzstd 1.5.7 decodes exactly these bytes to "Hello, Zstandard!".
    expect(encoder.encode('Hello, Zstandard!'.codeUnits), [
      0x28, 0xB5, 0x2F, 0xFD, // magic number
      0xA0, // single segment, 4-byte content size
      0x11, 0x00, 0x00, 0x00, // 17 bytes
      0x89, 0x00, 0x00, // the last block, raw, 17 bytes
      ...'Hello, Zstandard!'.codeUnits,
    ]);
  });

  test('round trips through the decoder, empty to several blocks', () {
    for (final data in [
      Uint8List(0),
      Uint8List.fromList([7]),
      build([
        ['text', 1000, 1],
      ]),
      build([
        ['noise', 131071, 2],
      ]),
      build([
        ['tiles', 200, 200, 3],
      ]),
    ]) {
      final frame = encoder.encode(data);
      expect(
        decoder.decode(frame, maxOutputSize: data.length),
        data,
        reason: '${data.length} bytes',
      );
      // The header, then a 3-byte header per block of up to 131,071 bytes.
      final blocks = data.isEmpty ? 1 : (data.length + 131070) ~/ 131071;
      expect(frame.length, 9 + 3 * blocks + data.length);
    }
  });
}
