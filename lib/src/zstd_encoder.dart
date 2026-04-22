/// Zstandard (RFC 8878) frame encoder — raw-block implementation.
///
/// Produces valid Zstandard frames decodable by [ZstdDecoder].
/// Blocks are stored as raw (uncompressed) blocks. This means the output
/// is larger than the input by a fixed overhead (~9 bytes), but encoding
/// is O(n) and requires no entropy-coding tables.
///
/// Compression via FSE/Huffman blocks may be added in a future version
/// without changing the `.jgee` binary format (the compression-flag byte
/// in the section header handles the distinction).
library;

import 'dart:typed_data';

/// Magic number for Zstandard frames (0xFD2FB528, little-endian).
const int _zstdMagic = 0xFD2FB528;

/// Maximum raw-block payload size per the Zstandard spec (2^17 - 1 = 131071).
const int _maxBlockSize = 131071;

/// Block type identifier for raw blocks.
const int _blockTypeRaw = 0;

/// Zstandard frame encoder (raw-block mode).
///
/// Usage:
/// ```dart
/// final encoder = ZstdEncoder();
/// final compressed = encoder.encode(rawBytes);
/// // Decompress with:
/// final decoder = ZstdDecoder();
/// final original = decoder.decodeBytes(compressed);
/// ```
class ZstdEncoder {
  const ZstdEncoder();

  /// Encode [input] as a Zstandard frame containing raw (uncompressed) blocks.
  ///
  /// The returned [Uint8List] is a complete, valid Zstandard frame that can be
  /// decoded by [ZstdDecoder.decodeBytes].
  Uint8List encode(List<int> input) {
    final contentSize = input.length;

    // Calculate number of blocks needed.
    final blockCount = contentSize == 0
        ? 1
        : (contentSize + _maxBlockSize - 1) ~/ _maxBlockSize;

    // Pre-calculate total output size:
    //   4 (magic) + 1 (FHD) + 4 (content size FCS) + blockCount * (3 header + payload)
    int totalSize = 4 + 1 + 4;
    for (int i = 0; i < blockCount; i++) {
      final start = i * _maxBlockSize;
      final end = (start + _maxBlockSize < contentSize)
          ? start + _maxBlockSize
          : contentSize;
      totalSize += 3 + (end - start);
    }

    final out = ByteData(totalSize);
    int pos = 0;

    // --- Frame Header ---

    // Magic number (LE uint32).
    out.setUint32(pos, _zstdMagic, Endian.little);
    pos += 4;

    // Frame Header Descriptor:
    //   Bits 7-6 (FCS_Flag)       = 2  → 4-byte Frame_Content_Size
    //   Bit  5   (Single_Segment) = 1  → no Window_Descriptor
    //   Bit  4   (reserved)       = 0
    //   Bit  3   (reserved)       = 0
    //   Bit  2   (Checksum_Flag)  = 0  → no content checksum
    //   Bits 1-0 (Dict_ID_Flag)   = 0  → no dictionary
    //
    // Encoding: (2 << 6) | (1 << 5) = 0x40 | 0x20 = 0x60
    out.setUint8(pos, 0x60);
    pos += 1;

    // Frame_Content_Size — 4 bytes LE (because FCS_Flag == 2).
    out.setUint32(pos, contentSize, Endian.little);
    pos += 4;

    // --- Data Blocks ---
    for (int i = 0; i < blockCount; i++) {
      final start = i * _maxBlockSize;
      final end = (start + _maxBlockSize < contentSize)
          ? start + _maxBlockSize
          : contentSize;
      final blockPayloadSize = end - start;
      final isLast = (i == blockCount - 1) ? 1 : 0;

      // Block_Header (3 bytes LE):
      //   Bit  0        = Last_Block flag
      //   Bits 2-1      = Block_Type (0 = Raw)
      //   Bits 23-3     = Block_Size
      final blockHeader =
          isLast | (_blockTypeRaw << 1) | (blockPayloadSize << 3);

      out.setUint8(pos, blockHeader & 0xFF);
      out.setUint8(pos + 1, (blockHeader >> 8) & 0xFF);
      out.setUint8(pos + 2, (blockHeader >> 16) & 0xFF);
      pos += 3;

      // Raw payload.
      for (int j = start; j < end; j++) {
        out.setUint8(pos, input[j] & 0xFF);
        pos++;
      }
    }

    return out.buffer.asUint8List(0, pos);
  }

  /// Encode a [Uint8List] directly.
  Uint8List encodeBytes(Uint8List input) => encode(input);
}
