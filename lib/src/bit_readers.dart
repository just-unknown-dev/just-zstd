/// The two bit streams of the Zstandard format (RFC 8878 §4.1).
///
/// Internal: not exported. Both readers work in values of at most 32 bits,
/// so they give the same answers on the web, where `int` is a double and
/// bitwise operators work on 32 bits.
library;

import 'dart:typed_data';

/// A little-endian bit stream read forward, lowest bit first: an FSE table
/// description (RFC 8878 §4.1.1).
final class ForwardBitReader {
  /// Reads bytes [start] to [end] of [data].
  ForwardBitReader(this._data, int start, this._end) : _bit = start * 8;

  final Uint8List _data;
  final int _end;

  /// The next bit to read, counted from the start of the data.
  int _bit;

  /// The next [count] bits (at most 24) without consuming them. Bits past
  /// the end read as 0.
  int peek(int count) {
    final first = _bit >> 3;
    var value = 0;
    for (var i = 0; i < 4; i++) {
      final index = first + i;
      if (index >= _end) break;
      value |= _data[index] << (8 * i);
    }
    return (value >> (_bit & 7)) & ((1 << count) - 1);
  }

  /// Consumes [count] bits.
  ///
  /// Throws [FormatException] when that runs past the end.
  void skip(int count) {
    _bit += count;
    if (_bit > _end * 8) {
      throw const FormatException('zstd: truncated FSE table description');
    }
  }

  /// Reads and consumes [count] bits (at most 24).
  int read(int count) {
    final value = peek(count);
    skip(count);
    return value;
  }

  /// The first byte after the bits read so far: where the next field
  /// starts, the stream being padded to a whole byte.
  int get nextByte => (_bit + 7) >> 3;
}

/// A bit stream read backward (RFC 8878 §4.1): from the highest bit of its
/// last byte down to the lowest of its first. The last byte's highest set
/// bit marks where the stream ends and is not part of it.
///
/// Huffman literals and sequences are read this way. Reading past the
/// start gives 0 bits; [position] then goes negative, which is how a
/// decoder tells it overran.
final class BackwardBitReader {
  /// Reads bytes [start] to [end] of [data].
  ///
  /// Throws [FormatException] when the stream is empty or its last byte
  /// is 0 (it has no end mark).
  BackwardBitReader(this._data, this._start, int end)
    : _position = _bitsBefore(_data, _start, end);

  final Uint8List _data;
  final int _start;
  int _position;

  static int _bitsBefore(Uint8List data, int start, int end) {
    if (end <= start) {
      throw const FormatException('zstd: empty bit stream');
    }
    final last = data[end - 1];
    if (last == 0) {
      throw const FormatException('zstd: bit stream has no end mark');
    }
    return (end - start - 1) * 8 + highBit(last);
  }

  /// How many bits are left to read. Negative once a read has gone past the
  /// start of the stream.
  int get position => _position;

  /// Whether a read has gone past the start of the stream.
  bool get overflowed => _position < 0;

  /// Reads the next [count] bits (at most 24), the first one read as the
  /// highest bit of the result.
  int read(int count) {
    if (count == 0) return 0;
    _position -= count;
    if (_position >= 0) return _bitsAt(_position, count);
    if (_position > -count) {
      // Some bits are left: they are the high ones, 0s fill in below.
      final available = count + _position;
      return _bitsAt(0, available) << -_position;
    }
    return 0;
  }

  /// Reads the next [count] bits, up to 31 of them.
  int readLong(int count) {
    if (count <= 24) return read(count);
    final high = read(count - 24);
    return (high << 24) | read(24);
  }

  /// [count] bits (at most 25) starting [bit] bits into the stream.
  int _bitsAt(int bit, int count) {
    final first = _start + (bit >> 3);
    final shift = bit & 7;
    final bytes = (shift + count + 7) >> 3;
    var value = 0;
    for (var i = 0; i < bytes; i++) {
      value |= _data[first + i] << (8 * i);
    }
    return (value >> shift) & ((1 << count) - 1);
  }
}

/// The index of the highest set bit of [value], which must be above 0:
/// `floor(log2(value))`.
int highBit(int value) {
  var bit = 0;
  while (value > 1) {
    value >>= 1;
    bit++;
  }
  return bit;
}
