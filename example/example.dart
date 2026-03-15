import 'dart:typed_data';
import 'package:just_zstd/just_zstd.dart';

void main() {
  // A small Zstandard frame (for demonstration purposes).
  // In a real application, you would load this from a file, network, or a
  // base64-decoded TMX layer data string.
  
  // This specific byte sequence represents a minimal valid Zstandard frame.
  // (In this case, an empty frame just for demonstration, or we'll catch the Exception).
  final compressedData = Uint8List.fromList([
    0x28, 0xB5, 0x2F, 0xFD, // Magic Number (little-endian: 0xFD2FB528)
    0x00,                   // Frame Header Descriptor
    0x00,                   // Block Header (last block, raw, size 0)
  ]);

  try {
    print('Starting Zstandard decompression example...');

    // 1. Create a Zstandard decoder instance.
    // The decoder is stateless and can be reused.
    const decoder = ZstdDecoder();

    // 2. Decode the compressed bytes.
    // Use `decodeBytes` to get a Uint8List, or `decode` to get a List<int>.
    final decompressedData = decoder.decodeBytes(compressedData);
    
    print('Success! Decoded ${decompressedData.length} bytes.');
  } on FormatException catch (e) {
    // The decoder throws a FormatException if the data is malformed
    // or incomplete.
    print('Error decoding data: $e');
  } catch (e) {
    print('An unexpected error occurred: $e');
  }
}
