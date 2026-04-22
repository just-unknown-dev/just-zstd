# Just Zstd

A pure Dart implementation of the Zstandard (RFC 8878) codec.

This package provides a lightweight, dependency-free encoder and decoder for Zstandard (zstd) compressed data, making it suitable for environments where native or FFI-based Zstandard implementations are unavailable or difficult to integrate (such as certain Flutter web scenarios or isolated Dart scripts).

It was originally built for the `just_tiled` package to decompress TMX map layers, and has been extended with encoding support.

## Features

- Pure Dart implementation (no `dart:ffi` or native extensions required)
- Encoding support: create Zstandard frames with raw-block compression
- Decoding support: decompress Zstandard frames and blocks, including raw and compressed blocks

## Getting started

Add `just_zstd` to your `pubspec.yaml`:

```yaml
dependencies:
  just_zstd: ^0.2.0
```

## Usage

### Decoding

```dart
import 'dart:typed_data';
import 'package:just_zstd/just_zstd.dart';

void main() {
  // A hypothetical compressed buffer (e.g., loaded from a file or network)
  final compressedData = Uint8List.fromList([
    0x28, 0xB5, 0x2F, 0xFD, // Magic Number (little-endian: 0xFD2FB528)
    0x00,                   // Frame Header Descriptor
    0x00,                   // Block Header (last block, raw, size 0)
  ]);

  try {
    const decoder = ZstdDecoder();
    
    // Decode directly into a Uint8List
    final decompressedData = decoder.decodeBytes(compressedData);
    
    print('Decoded ${decompressedData.length} bytes.');
  } on FormatException catch (e) {
    print('Invalid Zstandard data: $e');
  }
}
```

### Encoding

```dart
import 'dart:typed_data';
import 'package:just_zstd/just_zstd.dart';

void main() {
  final rawData = Uint8List.fromList([1, 2, 3, 4, 5]);
  
  const encoder = ZstdEncoder();
  final compressed = encoder.encodeBytes(rawData);
  
  print('Encoded ${rawData.length} bytes to ${compressed.length} bytes.');
  
  // Verify with decoder
  const decoder = ZstdDecoder();
  final decompressed = decoder.decodeBytes(compressed);
  
  print('Round-trip successful: ${decompressed.toString() == rawData.toString()}');
}
```

## Limitations

Currently, this is a simplified decoder designed primarily for the specific compression profiles used by tools like the Tiled Map Editor. While it successfully decodes many Zstandard frames, it may not yet fully support all advanced features of the complete Zstandard specification (such as complex dictionary decompression).
