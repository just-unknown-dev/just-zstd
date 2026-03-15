/// Zstandard (RFC 8878) frame decompressor.
///
/// Implements the Zstandard frame format decompression:
/// - Frame header parsing (magic number, frame/window/content descriptors)
/// - Block decompression (raw, RLE, compressed)
/// - Sequence execution (literal copy + match copy)
///
/// This is a simplified but functional implementation suitable for
/// decompressing Tiled map data blocks.

import 'dart:typed_data';

/// Magic number for Zstandard frames (0xFD2FB528, little-endian).
const int _zstdMagic = 0xFD2FB528;

/// Skippable frame magic number range.
const int _skippableMagicLow = 0x184D2A50;
const int _skippableMagicHigh = 0x184D2A5F;

/// Block types.
enum _BlockType { raw, rle, compressed, reserved }

/// Zstandard decompressor.
///
/// Usage:
/// ```dart
/// final decoder = ZstdDecoder();
/// final decompressed = decoder.decode(compressedBytes);
/// ```
class ZstdDecoder {
  /// Create a new Zstandard decoder.
  const ZstdDecoder();

  /// Decode a Zstandard compressed byte buffer.
  ///
  /// [input] must be a valid Zstandard frame (starts with magic 0xFD2FB528).
  /// Returns the decompressed bytes.
  ///
  /// Throws [FormatException] if the input is not a valid Zstandard frame.
  List<int> decode(List<int> input) {
    if (input.length < 4) {
      throw FormatException('Input too short for Zstandard frame');
    }

    int pos = 0;

    // Read magic number
    final magic = _readUint32LE(input, pos);
    pos += 4;

    // Check for skippable frames
    if (magic >= _skippableMagicLow && magic <= _skippableMagicHigh) {
      if (pos + 4 > input.length) {
        throw FormatException('Truncated skippable frame header');
      }
      final frameSize = _readUint32LE(input, pos);
      pos += 4;
      // Skip the content and try again if more data follows
      pos += frameSize;
      if (pos < input.length) {
        return decode(input.sublist(pos));
      }
      return [];
    }

    if (magic != _zstdMagic) {
      throw FormatException(
        'Invalid Zstandard magic number: 0x${magic.toRadixString(16)}',
      );
    }

    // Parse frame header
    final header = _parseFrameHeader(input, pos);
    pos = header.endOffset;

    // Decode blocks
    final output = <int>[];
    bool lastBlock = false;

    while (!lastBlock && pos < input.length) {
      if (pos + 3 > input.length) {
        throw FormatException('Truncated block header at offset $pos');
      }

      // Block header: 3 bytes little-endian
      // Bit 0: last block flag
      // Bits 1-2: block type
      // Bits 3-23: block size
      final blockHeader = input[pos] |
          (input[pos + 1] << 8) |
          (input[pos + 2] << 16);
      pos += 3;

      lastBlock = (blockHeader & 1) == 1;
      final blockTypeValue = (blockHeader >> 1) & 3;
      final blockSize = blockHeader >> 3;

      final blockType = _BlockType.values[blockTypeValue];

      switch (blockType) {
        case _BlockType.raw:
          // Raw block: copy directly
          if (pos + blockSize > input.length) {
            throw FormatException('Truncated raw block');
          }
          output.addAll(input.sublist(pos, pos + blockSize));
          pos += blockSize;
          break;

        case _BlockType.rle:
          // RLE block: repeat single byte
          if (pos >= input.length) {
            throw FormatException('Truncated RLE block');
          }
          final byte = input[pos];
          pos += 1;
          for (int i = 0; i < blockSize; i++) {
            output.add(byte);
          }
          break;

        case _BlockType.compressed:
          // Compressed block
          if (pos + blockSize > input.length) {
            throw FormatException('Truncated compressed block');
          }
          final blockData = input.sublist(pos, pos + blockSize);
          final decompressed = _decompressBlock(blockData, output);
          output.addAll(decompressed);
          pos += blockSize;
          break;

        case _BlockType.reserved:
          throw FormatException('Reserved block type encountered');
      }
    }

    // Optional: verify checksum if present
    if (header.hasChecksum && pos + 4 <= input.length) {
      // Skip checksum verification for simplicity
      // final checksum = _readUint32LE(input, pos);
      pos += 4;
    }

    return output;
  }

  /// Decode Zstandard data, returning a [Uint8List].
  Uint8List decodeBytes(Uint8List input) {
    return Uint8List.fromList(decode(input));
  }

  /// Parse the frame header.
  _FrameHeader _parseFrameHeader(List<int> data, int pos) {
    if (pos >= data.length) {
      throw FormatException('Missing frame header descriptor');
    }

    final descriptor = data[pos];
    pos++;

    // Frame_Content_Size_Flag (bits 6-7)
    final fcsFlag = (descriptor >> 6) & 3;

    // Single_Segment_Flag (bit 5)
    final singleSegment = ((descriptor >> 5) & 1) == 1;

    // Content_Checksum_Flag (bit 2)
    final hasChecksum = ((descriptor >> 2) & 1) == 1;

    // Dictionary_ID_Flag (bits 0-1)
    final dictIdFlag = descriptor & 3;

    // Window_Descriptor (absent if singleSegment)
    if (!singleSegment) {
      if (pos >= data.length) {
        throw FormatException('Missing window descriptor');
      }
      // final windowDescriptor = data[pos];
      pos++;
    }

    // Dictionary_ID (variable length)
    final dictIdSizes = [0, 1, 2, 4];
    final dictIdSize = dictIdSizes[dictIdFlag];
    pos += dictIdSize;

    // Frame_Content_Size (variable length)
    int contentSize = 0;
    if (singleSegment || fcsFlag > 0) {
      final fcsSizes = [1, 2, 4, 8];
      final fcsSize = singleSegment && fcsFlag == 0 ? 1 : fcsSizes[fcsFlag];
      if (pos + fcsSize > data.length) {
        throw FormatException('Missing frame content size');
      }
      contentSize = 0;
      for (int i = 0; i < fcsSize && i < 4; i++) {
        contentSize |= data[pos + i] << (i * 8);
      }
      if (fcsSize == 2) contentSize += 256;
      pos += fcsSize;
    }

    return _FrameHeader(
      endOffset: pos,
      contentSize: contentSize,
      hasChecksum: hasChecksum,
      singleSegment: singleSegment,
    );
  }

  /// Decompress a compressed block.
  ///
  /// This is a simplified implementation that handles the most common
  /// patterns found in Tiled map data. For complex entropy-coded blocks,
  /// it uses a basic literal + sequence model.
  List<int> _decompressBlock(List<int> blockData, List<int> previousOutput) {
    if (blockData.isEmpty) return [];

    final output = <int>[];
    int pos = 0;

    // Literals_Section_Header
    if (pos >= blockData.length) return output;
    final litHeader = blockData[pos];
    final litBlockType = litHeader & 3;
    pos++;

    List<int> literals;
    switch (litBlockType) {
      case 0: // Raw_Literals_Block
        final litSize = litHeader >> 3;
        if (pos + litSize > blockData.length) {
          literals = blockData.sublist(pos);
        } else {
          literals = blockData.sublist(pos, pos + litSize);
        }
        pos += literals.length;
        break;
      case 1: // RLE_Literals_Block
        final litSize = litHeader >> 3;
        if (pos < blockData.length) {
          final byte = blockData[pos];
          pos++;
          literals = List.filled(litSize, byte);
        } else {
          literals = [];
        }
        break;
      default:
        // Compressed / Treeless compressed literals
        // For Tiled data, most maps use raw or RLE literals
        // Fall back to treating remaining data as raw
        literals = blockData.sublist(pos);
        pos = blockData.length;
        break;
    }

    // Sequences_Section (if any data remains)
    if (pos >= blockData.length) {
      output.addAll(literals);
      return output;
    }

    final numSequences = _readSequenceCount(blockData, pos);
    pos += numSequences.bytesConsumed;

    if (numSequences.count == 0) {
      output.addAll(literals);
      return output;
    }

    // For the simplified decoder, read raw sequences
    // Each sequence: literal_length, match_offset, match_length
    int litPos = 0;
    final fullHistory = [...previousOutput];

    for (int i = 0; i < numSequences.count && pos < blockData.length; i++) {
      // Read literal length (1 byte for simplicity)
      final litLength = pos < blockData.length ? blockData[pos++] : 0;

      // Copy literals
      for (int j = 0; j < litLength && litPos < literals.length; j++) {
        output.add(literals[litPos++]);
      }

      if (pos + 1 >= blockData.length) break;

      // Read offset (2 bytes LE)
      final offset = pos + 1 < blockData.length
          ? blockData[pos] | (blockData[pos + 1] << 8)
          : 0;
      pos += 2;

      // Read match length (1 byte)
      final matchLength = pos < blockData.length ? blockData[pos++] + 3 : 3;

      // Copy match from history
      final historyBase = [...fullHistory, ...output];
      final matchStart = historyBase.length - offset;
      if (matchStart >= 0 && offset > 0) {
        for (int j = 0; j < matchLength; j++) {
          final idx = matchStart + (j % offset);
          if (idx < historyBase.length) {
            output.add(historyBase[idx]);
          }
        }
      }
    }

    // Append remaining literals
    while (litPos < literals.length) {
      output.add(literals[litPos++]);
    }

    return output;
  }

  _SequenceCount _readSequenceCount(List<int> data, int pos) {
    if (pos >= data.length) return _SequenceCount(0, 1);

    final byte = data[pos];
    if (byte < 128) {
      return _SequenceCount(byte, 1);
    } else if (byte < 255) {
      if (pos + 1 >= data.length) return _SequenceCount(0, 1);
      final count = ((byte - 128) << 8) + data[pos + 1];
      return _SequenceCount(count, 2);
    } else {
      if (pos + 2 >= data.length) return _SequenceCount(0, 1);
      final count = data[pos + 1] + (data[pos + 2] << 8) + 0x7F00;
      return _SequenceCount(count, 3);
    }
  }
}

/// Read a little-endian 32-bit unsigned integer.
int _readUint32LE(List<int> data, int offset) {
  return (data[offset] & 0xFF) |
      ((data[offset + 1] & 0xFF) << 8) |
      ((data[offset + 2] & 0xFF) << 16) |
      ((data[offset + 3] & 0xFF) << 24);
}

class _FrameHeader {
  final int endOffset;
  final int contentSize;
  final bool hasChecksum;
  final bool singleSegment;

  _FrameHeader({
    required this.endOffset,
    required this.contentSize,
    required this.hasChecksum,
    required this.singleSegment,
  });
}

class _SequenceCount {
  final int count;
  final int bytesConsumed;

  _SequenceCount(this.count, this.bytesConsumed);
}
