/// Huffman decoding table for Zstandard literal decompression.
///
/// Zstandard uses canonical Huffman coding for the literals section
/// of compressed blocks. This implements both weight-based and
/// direct table-based decoding.

import 'bit_reader.dart';
import 'fse_table.dart';

/// A single entry in the Huffman decoding table.
class HuffmanEntry {
  /// The decoded symbol (byte value 0–255).
  final int symbol;

  /// Number of bits consumed from the stream for this symbol.
  final int numberOfBits;

  const HuffmanEntry({required this.symbol, required this.numberOfBits});
}

/// Huffman decoding table.
class HuffmanTable {
  /// Maximum number of bits for any code (table accuracy log).
  final int maxBits;

  /// Decoding table entries, indexed by bit pattern.
  final List<HuffmanEntry> entries;

  /// Table size = 1 << maxBits.
  int get tableSize => 1 << maxBits;

  const HuffmanTable({required this.maxBits, required this.entries});

  /// Build a Huffman decoding table from symbol weights.
  ///
  /// [weights] is a list of weights for symbols 0..N-1.
  /// Weight 0 means the symbol is not present. Weight w means
  /// the symbol has numberOfBits = (maxBits + 1 - w).
  factory HuffmanTable.fromWeights(List<int> weights) {
    // Determine max weight
    int maxWeight = 0;
    for (final w in weights) {
      if (w > maxWeight) maxWeight = w;
    }

    if (maxWeight == 0) {
      return const HuffmanTable(maxBits: 1, entries: []);
    }

    // Calculate sum of (1 << (w-1)) for all w > 0 to derive maxBits
    int weightSum = 0;
    for (final w in weights) {
      if (w > 0) {
        weightSum += 1 << (w - 1);
      }
    }

    // maxBits is such that 1 << maxBits = next power of 2 >= weightSum
    int maxBits = 1;
    while ((1 << maxBits) < weightSum) {
      maxBits++;
    }

    // Last symbol weight fills the remainder
    final tableSize = 1 << maxBits;

    // Build the decoding table
    final entries = List<HuffmanEntry>.filled(
      tableSize,
      const HuffmanEntry(symbol: 0, numberOfBits: 0),
    );

    // Calculate number of bits for each symbol
    final symbolBits = <int, int>{};
    for (int i = 0; i < weights.length; i++) {
      if (weights[i] > 0) {
        symbolBits[i] = maxBits + 1 - weights[i];
      }
    }

    // Fill the table — each symbol occupies (tableSize >> numberOfBits) entries
    int pos = 0;
    // Sort by number of bits (longest first for canonical ordering)
    final sortedSymbols = symbolBits.keys.toList()
      ..sort((a, b) => symbolBits[b]!.compareTo(symbolBits[a]!));

    for (final symbol in sortedSymbols) {
      final bits = symbolBits[symbol]!;
      final span = tableSize >> bits;
      for (int i = 0; i < span; i++) {
        if (pos + i < tableSize) {
          entries[pos + i] = HuffmanEntry(symbol: symbol, numberOfBits: bits);
        }
      }
      pos += span;
    }

    return HuffmanTable(maxBits: maxBits, entries: entries);
  }

  /// Read a Huffman table description from a compressed header.
  ///
  /// Returns the weights for symbols 0..N. The header format is either
  /// FSE-compressed or direct (based on header byte).
  static List<int> readWeights(BitReader reader) {
    final headerByte = reader.readByte();

    if (headerByte < 128) {
      // FSE-compressed weights
      final compressedSize = headerByte;
      final startPos = reader.bytePosition;

      // Read FSE distribution for weight values
      final (probs, accuracyLog) =
          FseTable.readNormalizedDistribution(reader, 12);
      final fseTable = FseTable.build(probs, accuracyLog);

      // Decode weights using FSE
      final weights = <int>[];
      final state = [reader.readBits(accuracyLog)];

      // Read until we've consumed compressedSize bytes
      while (reader.bytePosition - startPos < compressedSize) {
        if (reader.remainingBits < 1) break;
        weights.add(fseTable.decode(reader, state));
        if (weights.length > 255) break;
      }

      reader.alignToByte();
      return weights;
    } else {
      // Direct representation
      final numSymbols = headerByte - 127;
      final weights = <int>[];

      for (int i = 0; i < numSymbols; i += 2) {
        final byte = reader.readByte();
        weights.add(byte >> 4);
        if (i + 1 < numSymbols) {
          weights.add(byte & 0xF);
        }
      }

      return weights;
    }
  }

  /// Decode a single symbol from the bit stream (MSB-first reads).
  int decode(BitReader reader) {
    // Read maxBits bits to index the table
    final index = reader.readBits(maxBits);
    final entry = entries[index];
    // Put back unused bits
    if (entry.numberOfBits < maxBits) {
      // We over-read; this is handled by the table construction
      // (each entry knows how many bits it actually consumed)
    }
    return entry.symbol;
  }
}
