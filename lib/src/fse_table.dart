/// Finite State Entropy decoding tables (RFC 8878 §4.1.1): what literal
/// lengths, match lengths, offsets and Huffman weights are coded with.
///
/// Internal: not exported.
library;

import 'dart:typed_data';

import 'bit_readers.dart';

/// An FSE decoding table: for each state, the symbol it stands for, and
/// how the next state is read (that many bits, added to a base).
final class FseTable {
  FseTable._(this.accuracyLog, this.symbols, this.bits, this.bases);

  /// A table of `1 << accuracyLog` states from [counts], the normalized
  /// count of each symbol from 0 up: -1 for "less than 1", which takes one
  /// state at the end of the table.
  ///
  /// Throws [FormatException] when the counts don't fill the table exactly.
  factory FseTable.fromCounts(List<int> counts, int accuracyLog) {
    final size = 1 << accuracyLog;
    final symbols = Uint8List(size);
    final bits = Uint8List(size);
    final bases = Uint16List(size);
    final next = List<int>.filled(counts.length, 0);

    // "Less than 1" symbols take a state each, from the end.
    var high = size;
    for (var s = 0; s < counts.length; s++) {
      if (counts[s] == -1) {
        if (high == 0) throw _corrupt;
        symbols[--high] = s;
        next[s] = 1;
      }
    }

    // The others are spread over the rest, skipping those states.
    final step = (size >> 1) + (size >> 3) + 3;
    final mask = size - 1;
    var position = 0;
    var placed = 0;
    for (var s = 0; s < counts.length; s++) {
      final count = counts[s];
      if (count <= 0) continue;
      next[s] = count;
      for (var i = 0; i < count; i++) {
        if (++placed > high) throw _corrupt;
        symbols[position] = s;
        do {
          position = (position + step) & mask;
        } while (position >= high);
      }
    }
    if (position != 0 || placed != high) throw _corrupt;

    // Each state of a symbol reads enough bits to reach the next one.
    for (var state = 0; state < size; state++) {
      final symbol = symbols[state];
      final n = next[symbol]++;
      final b = accuracyLog - highBit(n);
      bits[state] = b;
      bases[state] = (n << b) - size;
    }
    return FseTable._(accuracyLog, symbols, bits, bases);
  }

  /// A table of one state, which always stands for [symbol] and reads no
  /// bits: a sequence field in RLE mode.
  factory FseTable.rle(int symbol) =>
      FseTable._(0, Uint8List(1)..[0] = symbol, Uint8List(1), Uint16List(1));

  /// Reads an FSE table description (RFC 8878 §4.1.1) from [reader] and
  /// builds its table. The reader is left after the description, which
  /// takes whole bytes.
  ///
  /// Throws [FormatException] when the description is damaged, its
  /// accuracy log is over [maxAccuracyLog], or it counts symbols past
  /// [maxSymbol].
  factory FseTable.read(
    ForwardBitReader reader, {
    required int maxAccuracyLog,
    required int maxSymbol,
  }) {
    final accuracyLog = reader.read(4) + 5;
    if (accuracyLog > maxAccuracyLog) {
      throw FormatException(
        'zstd: FSE accuracy log $accuracyLog is over $maxAccuracyLog',
      );
    }
    var remaining = 1 << accuracyLog;
    final counts = <int>[];
    while (remaining > 0) {
      if (counts.length > maxSymbol) throw _tooManySymbols;
      // Values 0 to remaining + 1 are possible: the small ones take a bit
      // less than the rest.
      final bits = highBit(remaining + 1) + 1;
      final lowMask = (1 << (bits - 1)) - 1;
      final threshold = (1 << bits) - 1 - (remaining + 1);
      var value = reader.peek(bits);
      if ((value & lowMask) < threshold) {
        value &= lowMask;
        reader.skip(bits - 1);
      } else {
        if (value > lowMask) value -= threshold;
        reader.skip(bits);
      }
      final count = value - 1;
      remaining -= count < 0 ? -count : count;
      counts.add(count);
      if (count == 0) {
        // Two-bit flags say how many more zeros follow; 3 means "and more".
        int repeat;
        do {
          repeat = reader.read(2);
          for (var i = 0; i < repeat; i++) {
            counts.add(0);
          }
        } while (repeat == 3);
        if (counts.length > maxSymbol + 1) throw _tooManySymbols;
      }
    }
    if (remaining != 0) throw _corrupt;
    return FseTable.fromCounts(counts, accuracyLog);
  }

  /// The log2 of the number of states.
  final int accuracyLog;

  /// The symbol each state stands for.
  final Uint8List symbols;

  /// How many bits each state reads for the next state.
  final Uint8List bits;

  /// What each state adds those bits to.
  final Uint16List bases;

  static const _corrupt = FormatException('zstd: damaged FSE table');
  static const _tooManySymbols = FormatException(
    'zstd: FSE table describes too many symbols',
  );
}
