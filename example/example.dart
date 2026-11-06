import 'dart:typed_data';
import 'package:just_zstd/just_zstd.dart';

void main() {
  // The encoder and decoder are stateless and can be reused.
  const encoder = ZstdEncoder();
  const decoder = ZstdDecoder();

  // --- Encoding ---
  final original = Uint8List.fromList('Hello, Zstandard!'.codeUnits);

  print('Original:   ${original.length} bytes');

  // Encode to a valid Zstandard frame using raw (uncompressed) blocks.
  final frame = encoder.encode(original);

  print('Frame:      ${frame.length} bytes');

  // --- Decoding ---
  // A frame the zstd library compressed (level 19): "Hello, Zstandard!"
  // four times, 68 bytes in 34.
  final compressed = Uint8List.fromList([
    0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x44, 0xCD, 0x00, 0x00, 0x90, 0x48, //
    0x65, 0x6C, 0x6C, 0x6F, 0x2C, 0x20, 0x5A, 0x73, 0x74, 0x61, 0x6E,
    0x64, 0x61, 0x72, 0x64, 0x21, 0x48, 0x01, 0x00, 0xA6, 0x68, 0x86,
    0x01,
  ]);

  try {
    // Cap the output when you know how big it should be: damaged or
    // hostile data then fails fast instead of filling memory.
    final roundTrip = decoder.decode(frame, maxOutputSize: original.length);
    print('Round trip: ${String.fromCharCodes(roundTrip)}');

    final decompressed = decoder.decode(compressed, maxOutputSize: 1024);
    print('Decompressed: ${String.fromCharCodes(decompressed)}');
  } on FormatException catch (e) {
    print('Error decoding data: $e');
  }
}
