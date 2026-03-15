/// Finite State Entropy (FSE) table builder and decoder.
///
/// FSE is the entropy coding scheme used by Zstandard for encoding
/// literal lengths, match lengths, and offset codes. This implements
/// the tANS (table-based Asymmetric Numeral Systems) variant.

import 'bit_reader.dart';

/// A single entry in the FSE decoding table.
class FseEntry {
  /// The symbol this entry decodes to.
  final int symbol;

  /// Number of bits to read for the next state.
  final int bitsToRead;

  /// Base value to add the read bits to for computing the next state.
  final int baseline;

  const FseEntry({
    required this.symbol,
    required this.bitsToRead,
    required this.baseline,
  });
}

/// FSE decoding table.
class FseTable {
  /// The decoding table entries, indexed by state.
  final List<FseEntry> entries;

  /// The accuracy log (log2 of table size).
  final int accuracyLog;

  /// Table size = 1 << accuracyLog.
  int get tableSize => 1 << accuracyLog;

  const FseTable({required this.entries, required this.accuracyLog});

  /// Build an FSE decoding table from a normalized probability distribution.
  ///
  /// [normalizedProbs] maps symbol → probability count.
  /// Sum of probabilities must equal `1 << accuracyLog`.
  /// Probabilities of -1 indicate "less than 1" symbols.
  factory FseTable.build(
    Map<int, int> normalizedProbs,
    int accuracyLog,
  ) {
    final tableSize = 1 << accuracyLog;
    final tableMask = tableSize - 1;
    final step = (tableSize >> 1) + (tableSize >> 3) + 3;

    // Allocate symbol table (maps position → symbol)
    final symbolTable = List<int>.filled(tableSize, 0);

    // Distribute "less than 1" probability symbols first
    int highThreshold = tableSize - 1;
    for (final entry in normalizedProbs.entries) {
      if (entry.value == -1) {
        symbolTable[highThreshold] = entry.key;
        highThreshold--;
      }
    }

    // Distribute remaining symbols using the stepping algorithm
    int position = 0;
    for (final entry in normalizedProbs.entries) {
      final symbol = entry.key;
      final prob = entry.value;
      if (prob <= 0) continue; // skip "less than 1" (-1) and zero

      for (int i = 0; i < prob; i++) {
        symbolTable[position] = symbol;
        // Advance position, skipping occupied high-threshold slots
        do {
          position = (position + step) & tableMask;
        } while (position > highThreshold);
      }
    }

    // Build the actual decoding entries
    final entries = List<FseEntry>.filled(
      tableSize,
      const FseEntry(symbol: 0, bitsToRead: 0, baseline: 0),
    );

    // Cumulative occurrences per symbol
    final cumulativeOccurrences = <int, int>{};
    for (final entry in normalizedProbs.entries) {
      final prob = entry.value;
      cumulativeOccurrences[entry.key] = prob <= 0 ? (prob == -1 ? 1 : 0) : prob;
    }

    final nextState = <int, int>{};
    for (final entry in normalizedProbs.entries) {
      final prob = entry.value;
      final effectiveProb = prob == -1 ? 1 : (prob <= 0 ? 0 : prob);
      // Smallest power-of-2 >= effectiveProb
      if (effectiveProb > 0) {
        nextState[entry.key] = effectiveProb;
      }
    }

    for (int i = 0; i < tableSize; i++) {
      final symbol = symbolTable[i];
      final prob = normalizedProbs[symbol] ?? 0;
      final effectiveProb = prob == -1 ? 1 : (prob <= 0 ? 0 : prob);

      if (effectiveProb == 0) continue;

      // Number of bits: accuracyLog - floor(log2(effectiveProb))
      final stateIndex = nextState[symbol]!;
      final highBit = _highBit(stateIndex);
      final bitsToRead = accuracyLog - highBit;
      final baseline = (stateIndex << bitsToRead) - tableSize;

      entries[i] = FseEntry(
        symbol: symbol,
        bitsToRead: bitsToRead,
        baseline: baseline < 0 ? 0 : baseline,
      );

      nextState[symbol] = stateIndex + 1;
    }

    return FseTable(entries: entries, accuracyLog: accuracyLog);
  }

  /// Decode a single symbol from the bit stream, updating [state] in place.
  ///
  /// Returns the decoded symbol.
  int decode(BitReader reader, List<int> stateHolder) {
    final entry = entries[stateHolder[0]];
    final symbol = entry.symbol;
    final bits = reader.readBits(entry.bitsToRead);
    stateHolder[0] = entry.baseline + bits;
    return symbol;
  }

  /// Read the normalized distribution from a compressed header.
  ///
  /// Returns `{symbol: probability}` map and consumes bytes from [reader].
  static (Map<int, int>, int) readNormalizedDistribution(
    BitReader reader,
    int maxSymbol,
  ) {
    final accuracyLog = 5 + reader.readBits(4);
    final tableSize = 1 << accuracyLog;
    int remaining = tableSize;
    final probs = <int, int>{};
    int symbol = 0;

    while (remaining > 0 && symbol <= maxSymbol) {
      // Determine number of bits to read
      final threshold = _highBit(remaining + 1) + 1;
      final lowBits = threshold - 1;
      int value = reader.readBits(lowBits);

      if (value < (1 << threshold) - 1 - remaining) {
        // value is correct as-is
      } else {
        value = (value << 1) | reader.readBit();
        if (value >= (1 << threshold) - 1) {
          value -= (1 << threshold) - 1 - remaining;
        }
      }

      final prob = value - 1; // -1 means "less-than-1"
      if (prob == 0) {
        // Repeat zeros
        // This symbol gets probability 0 (not present)
        probs[symbol] = 0;
        symbol++;
        continue;
      }

      probs[symbol] = prob;
      if (prob > 0) {
        remaining -= prob;
      } else {
        remaining -= 1; // prob == -1, uses 1 slot
      }
      symbol++;
    }

    reader.alignToByte();
    return (probs, accuracyLog);
  }
}

/// Return floor(log2(x)). x must be > 0.
int _highBit(int x) {
  if (x <= 0) return 0;
  int bits = 0;
  while ((1 << (bits + 1)) <= x) {
    bits++;
  }
  return bits;
}
