# Just Zstd

A pure Dart implementation of Zstandard (RFC 8878).

`ZstdDecoder` reads Zstandard data the zstd library and the tools built on it write, every block and coding type included, and checks content checksums. `ZstdEncoder` writes valid frames of uncompressed blocks. No `dart:ffi`, native code or dependencies: it runs on native platforms, the web (JavaScript) and Wasm alike.

It was first built for the `just_tiled` package, to read the tile layers Tiled saves as "Base64 (Zstandard compressed)".

## Features

- **The whole format, minus dictionaries**: raw, RLE and compressed blocks; raw, RLE and Huffman-coded literals (one stream or four, a new tree or the last one); FSE-coded sequences in every mode; repeat offsets; any window size; several frames in a row, and skippable frames.
- **Checked**: a frame's content checksum (XXH64) and content size must match; damaged data throws a `FormatException`, never anything else.
- **Capped**: `maxOutputSize` stops data that would decompress to more as soon as it passes the cap, before the memory is taken.
- **Tested against the real thing**: frames from libzstd 1.5.7 and tile layers Tiled 1.11.2 saved decode byte for byte.

## Getting started

Add `just_zstd` to your `pubspec.yaml`:

```yaml
dependencies:
  just_zstd: ^0.3.0
```

## Usage

### Decoding

```dart
import 'dart:typed_data';

import 'package:just_zstd/just_zstd.dart';

void main() {
  // "Hello, Zstandard!" four times, as the zstd library compressed it.
  final compressed = Uint8List.fromList([
    0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x44, 0xCD, 0x00, 0x00, 0x90, 0x48, //
    0x65, 0x6C, 0x6C, 0x6F, 0x2C, 0x20, 0x5A, 0x73, 0x74, 0x61, 0x6E,
    0x64, 0x61, 0x72, 0x64, 0x21, 0x48, 0x01, 0x00, 0xA6, 0x68, 0x86,
    0x01,
  ]);

  try {
    const decoder = ZstdDecoder();
    final bytes = decoder.decode(compressed, maxOutputSize: 1024);
    print(String.fromCharCodes(bytes));
  } on FormatException catch (e) {
    print('Invalid Zstandard data: $e');
  }
}
```

Give `maxOutputSize` whenever you know how big the data should be (a tile layer is `width × height × 4` bytes), or the data comes from somewhere you don't trust. Without it, a few kilobytes of valid data can ask for hundreds of megabytes.

### Encoding

```dart
import 'dart:typed_data';

import 'package:just_zstd/just_zstd.dart';

void main() {
  final rawData = Uint8List.fromList([1, 2, 3, 4, 5]);

  const encoder = ZstdEncoder();
  final frame = encoder.encode(rawData);

  print('Encoded ${rawData.length} bytes as a ${frame.length}-byte frame.');

  const decoder = ZstdDecoder();
  print(decoder.decode(frame)); // [1, 2, 3, 4, 5]
}
```

## Limitations

- **No dictionaries.** A frame that needs one throws a `FormatException` that names the dictionary.
- **The encoder doesn't compress.** It writes raw blocks: a valid frame any decoder reads, 9 bytes (plus 3 per 128 KiB) larger than its input.
- **One call, all in memory.** There is no streaming API: `decode` takes the whole input and returns the whole output.
