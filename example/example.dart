import 'dart:typed_data';
import 'package:just_zstd/just_zstd.dart';

void main() {
  // The encoder and decoder are stateless and can be reused.
  const encoder = ZstdEncoder();
  const decoder = ZstdDecoder();

  // --- Encoding ---
  final original = Uint8List.fromList('Hello, Zstandard!'.codeUnits);

  print('Original:   ${original.length} bytes');

  // Encode to a valid Zstandard frame using raw blocks.
  final compressed = encoder.encodeBytes(original);

  print('Compressed: ${compressed.length} bytes');

  // --- Decoding ---
  try {
    final decompressed = decoder.decodeBytes(compressed);

    print('Decompressed: ${decompressed.length} bytes');
    print('Round-trip OK: ${String.fromCharCodes(decompressed)}');
  } on FormatException catch (e) {
    print('Error decoding data: $e');
  }
}
