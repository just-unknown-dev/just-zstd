/// Huffman decoding of compressed literals (RFC 8878 §4.2).
///
/// Internal: not exported.
library;

import 'dart:typed_data';

import 'bit_readers.dart';
import 'fse_table.dart';

/// A Huffman decoding table: indexed by the next [maxBits] bits of a
/// stream, the symbol they start with and how many of them its code takes.
final class HuffmanTable {
  HuffmanTable._(this.maxBits, this.symbols, this.bits);

  /// Reads a Huffman tree description (RFC 8878 §4.2.1) from bytes
  /// [start] to [end] of [data]. Returns the table and how many bytes the
  /// description took.
  ///
  /// Throws [FormatException] when the description is damaged.
  static (HuffmanTable, int) read(Uint8List data, int start, int end) {
    if (start >= end) throw _truncated;
    final header = data[start];
    final weights = Uint8List(_maxSymbols);
    int count;
    int length;
    if (header >= 128) {
      // Weights written directly, four bits each.
      count = header - 127;
      length = 1 + ((count + 1) >> 1);
      if (start + length > end) throw _truncated;
      for (var i = 0; i < count; i++) {
        final byte = data[start + 1 + (i >> 1)];
        weights[i] = i.isEven ? byte >> 4 : byte & 0xF;
      }
    } else {
      // Weights compressed with FSE: two states take turns.
      length = 1 + header;
      if (header == 0 || start + length > end) throw _truncated;
      final streamEnd = start + length;
      final description = ForwardBitReader(data, start + 1, streamEnd);
      final table = FseTable.read(
        description,
        maxAccuracyLog: 6,
        maxSymbol: 255,
      );
      final stream = BackwardBitReader(data, description.nextByte, streamEnd);
      count = _readWeights(table, stream, weights);
    }
    return (HuffmanTable._fromWeights(weights, count), length);
  }

  /// Decodes FSE-compressed weights into [weights]; returns how many.
  static int _readWeights(
    FseTable table,
    BackwardBitReader stream,
    Uint8List weights,
  ) {
    var count = 0;
    // At most 255 weights are written: the last symbol's is worked out.
    void add(int weight) {
      if (count >= _maxSymbols - 1) throw _corrupt;
      weights[count++] = weight;
    }

    var state1 = stream.read(table.accuracyLog);
    var state2 = stream.read(table.accuracyLog);
    // Until the stream runs out: the state that overran gives no more
    // symbols, the other gives its last.
    while (true) {
      add(table.symbols[state1]);
      state1 = table.bases[state1] + stream.read(table.bits[state1]);
      if (stream.overflowed) {
        add(table.symbols[state2]);
        return count;
      }
      add(table.symbols[state2]);
      state2 = table.bases[state2] + stream.read(table.bits[state2]);
      if (stream.overflowed) {
        add(table.symbols[state1]);
        return count;
      }
    }
  }

  /// The canonical table for [count] symbols' [weights]; the last symbol's
  /// weight is the one that makes the code lengths complete.
  factory HuffmanTable._fromWeights(Uint8List weights, int count) {
    var total = 0;
    for (var i = 0; i < count; i++) {
      final w = weights[i];
      if (w > _maxBitsLimit) throw _corrupt;
      if (w > 0) total += 1 << (w - 1);
    }
    if (total == 0) throw _corrupt;
    final maxBits = highBit(total) + 1;
    if (maxBits > _maxBitsLimit) throw _corrupt;
    final leftOver = (1 << maxBits) - total;
    if (leftOver & (leftOver - 1) != 0) throw _corrupt;
    weights[count] = highBit(leftOver) + 1;
    final symbolCount = count + 1;

    // Code lengths, and how many codes of each length.
    final lengths = Uint8List(symbolCount);
    final perLength = List<int>.filled(_maxBitsLimit + 1, 0);
    for (var s = 0; s < symbolCount; s++) {
      final w = weights[s];
      if (w == 0) continue;
      final length = maxBits + 1 - w;
      lengths[s] = length;
      perLength[length]++;
    }

    // The longest codes take the lowest table indices; within a length,
    // symbols keep their order.
    final size = 1 << maxBits;
    final symbols = Uint8List(size);
    final bits = Uint8List(size);
    final next = List<int>.filled(_maxBitsLimit + 2, 0);
    for (var length = maxBits; length >= 1; length--) {
      next[length - 1] =
          next[length] + perLength[length] * (1 << (maxBits - length));
    }
    if (next[0] != size) throw _corrupt;
    for (var length = maxBits; length >= 1; length--) {
      bits.fillRange(next[length], next[length - 1], length);
    }
    for (var s = 0; s < symbolCount; s++) {
      final length = lengths[s];
      if (length == 0) continue;
      final span = 1 << (maxBits - length);
      final at = next[length];
      symbols.fillRange(at, at + span, s);
      next[length] = at + span;
    }
    return HuffmanTable._(maxBits, symbols, bits);
  }

  /// The longest code's length: how many bits index the table.
  final int maxBits;

  /// The symbol a code starting with each [maxBits]-bit index stands for.
  final Uint8List symbols;

  /// How many bits that code takes.
  final Uint8List bits;

  /// Decodes [count] symbols from the stream in bytes [start] to [end] of
  /// [data] into [out], from [at].
  ///
  /// Throws [FormatException] unless the stream ends exactly with the last
  /// symbol.
  void decode(
    Uint8List data,
    int start,
    int end,
    Uint8List out,
    int at,
    int count,
  ) {
    final stream = BackwardBitReader(data, start, end);
    final mask = (1 << maxBits) - 1;
    var state = stream.read(maxBits);
    for (var i = 0; i < count; i++) {
      out[at + i] = symbols[state];
      final n = bits[state];
      state = ((state << n) | stream.read(n)) & mask;
    }
    // The state was read maxBits ahead: those bits come from before the
    // start, and nothing else may be left.
    if (stream.position != -maxBits) {
      throw const FormatException(
        'zstd: Huffman stream does not end with its last literal',
      );
    }
  }

  /// At most 256 symbols: every byte value.
  static const _maxSymbols = 256;

  /// The longest code the format allows.
  static const _maxBitsLimit = 12;

  static const _truncated = FormatException(
    'zstd: truncated Huffman tree description',
  );
  static const _corrupt = FormatException('zstd: damaged Huffman tree');
}
