// ZstdDecoder against frames the real zstd library made (libzstd 1.5.7,
// through Python's compression.zstd; test/fixtures/make_fixtures.py) and
// tile layers Tiled 1.11.2 saved. Between them the frames hold every block
// type (raw, RLE, compressed), every literals section (raw, RLE, Huffman
// with one stream and four, Huffman reusing the last tree), every sequence
// table mode (default, RLE, FSE, repeat), literals-only blocks, repeat
// offsets, matches across blocks, content checksums, frames without a
// content size, a 1 KiB window, skippable frames and several frames in a
// row. just_zstd 0.2.0 read none of the compressed ones right.

import 'dart:math';
import 'dart:typed_data';

import 'package:just_zstd/just_zstd.dart';
import 'package:test/test.dart';

import 'recipes.dart';

const _decoder = ZstdDecoder();
final _formatError = throwsA(isA<FormatException>());

void main() {
  final frames = (manifest()['frames'] as List).cast<Map<String, Object?>>();

  group('decodes what libzstd made', () {
    for (final frame in frames) {
      final name = frame['file'] as String;
      test('$name (${frame['settings']})', () {
        final expected = build(frame['recipe'] as List<Object?>);
        expect(expected.length, frame['size']);
        expect(_decoder.decode(fixture(name)), expected);
      });
    }

    test('two frames and a skippable one between them, as one stream', () {
      final entry = manifest()['concatenated'] as Map<String, Object?>;
      expect(
        _decoder.decode(fixture(entry['file'] as String)),
        build(entry['recipe'] as List<Object?>),
      );
    });

    test('from any list of ints, not only a Uint8List', () {
      expect(
        _decoder.decode(List<int>.of(fixture('text_1k_level19.zst'))),
        build([
          ['text', 1000, 2],
        ]),
      );
    });
  });

  group('decodes the tile layers Tiled saved', () {
    test('40 x 30: one block of Huffman literals and FSE sequences', () {
      expect(
        _decoder.decode(fixture('tiled_40x30.zst'), maxOutputSize: 4800),
        tiledLayer(40, 30),
      );
    });

    test('256 x 160: two blocks, the second reusing the first tables', () {
      expect(
        _decoder.decode(
          fixture('tiled_256x160.zst'),
          maxOutputSize: 256 * 160 * 4,
        ),
        tiledLayer(256, 160),
      );
    });
  });

  group('maxOutputSize', () {
    test('exactly the size reads; one byte less is refused', () {
      for (final name in ['tiles_256x256_level19.zst', 'zeros_300k.zst']) {
        final frame = fixture(name);
        final size = _decoder.decode(frame).length;
        expect(_decoder.decode(frame, maxOutputSize: size), hasLength(size));
        expect(
          () => _decoder.decode(frame, maxOutputSize: size - 1),
          _formatError,
          reason: name,
        );
      }
    });

    test('a frame whose header claims more is refused before decoding', () {
      // A 4-byte content size of 4 GiB - 1, then one empty raw block.
      final frame = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, 0xA0, 0xFF, 0xFF, 0xFF, 0xFF, //
        0x01, 0x00, 0x00,
      ]);
      expect(
        () => _decoder.decode(frame, maxOutputSize: 4800),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('more than 4800 bytes'),
          ),
        ),
      );
    });

    test('RLE blocks of 128 KiB from 4 bytes each are cut off at the cap', () {
      // No content size, a 128 KiB window, then 1000 RLE blocks: 4 KB that
      // would unpack to 131 MB.
      final block = 1 << 1 | 131072 << 3;
      final frame = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x38, //
        for (var i = 0; i < 1000; i++) ...[
          (block | (i == 999 ? 1 : 0)) & 0xFF,
          (block >> 8) & 0xFF,
          block >> 16,
          0x41,
        ],
      ]);
      expect(() => _decoder.decode(frame, maxOutputSize: 4800), _formatError);
      final head = Uint8List.sublistView(frame, 0, 6 + 4 * 2);
      head[6 + 4] |= 1; // the second block is the last
      expect(_decoder.decode(head), hasLength(2 * 131072));
    });

    test('a negative cap is an argument error', () {
      expect(
        () => _decoder.decode(fixture('one_byte.zst'), maxOutputSize: -1),
        throwsArgumentError,
      );
    });
  });

  group('refuses, with a FormatException', () {
    test('a frame that needs a dictionary', () {
      final entry = manifest()['dictionary'] as Map<String, Object?>;
      expect(
        () => _decoder.decode(fixture(entry['file'] as String)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('dictionary ${entry['dictId']}'),
          ),
        ),
      );
    });

    test('content that fails its checksum', () {
      final frame = fixture('text_30k_level3.zst');
      frame[frame.length - 1] ^= 0x01;
      expect(() => _decoder.decode(frame), _formatError);
    });

    test('content of another size than the header says', () {
      // One raw block of 3 bytes, under a content size of 4.
      expect(
        () => _decoder.decode([
          0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x04, //
          0x19, 0x00, 0x00, 0x61, 0x62, 0x63,
        ]),
        _formatError,
      );
    });

    test('too short to be a frame, and the wrong magic number', () {
      expect(() => _decoder.decode(const []), _formatError);
      expect(() => _decoder.decode(const [0x28, 0xB5]), _formatError);
      expect(() => _decoder.decode(const [0, 0, 0, 0]), _formatError);
    });

    test('a frame with its reserved bit set', () {
      expect(
        () => _decoder.decode([0x28, 0xB5, 0x2F, 0xFD, 0x28, 0x00, 1, 0, 0]),
        _formatError,
      );
    });

    test('bytes after the last frame that are not a frame', () {
      expect(
        () => _decoder.decode([...fixture('one_byte.zst'), 1, 2, 3, 4]),
        _formatError,
      );
    });

    test('every cut-short frame', () {
      for (final name in [
        'text_1k_level19.zst',
        'tiles_64x64_level19.zst',
        'rle_literals.zst',
        'tiled_40x30.zst',
      ]) {
        final frame = fixture(name);
        for (var length = 0; length < frame.length; length++) {
          expect(
            () => _decoder.decode(Uint8List.sublistView(frame, 0, length)),
            _formatError,
            reason: '$name cut to $length bytes',
          );
        }
      }
    });
  });

  test('damaged frames decode or throw FormatException, nothing else', () {
    final random = Random(7);
    for (final name in [
      'text_30k_level22.zst',
      'tiles_64x64_level19.zst',
      'rle_literals.zst',
      'small_window.zst',
      'tiled_40x30.zst',
    ]) {
      final original = fixture(name);
      for (var i = 0; i < 300; i++) {
        final frame = Uint8List.fromList(original);
        final at = random.nextInt(frame.length);
        frame[at] ^= 1 << random.nextInt(8);
        try {
          _decoder.decode(frame, maxOutputSize: 1 << 20);
        } on FormatException {
          // Refused: fine.
        } catch (e) {
          fail('$name with byte $at changed threw ${e.runtimeType}: $e');
        }
      }
    }
  });
}
