/// Bit-level stream reader for entropy decoding.
///
/// Reads bits from a byte buffer in LSB-first order, which is the convention
/// used by the Zstandard compressed format.
class BitReader {
  final List<int> _data;
  int _bytePos;
  int _bitPos = 0;

  /// Create a [BitReader] over [data] starting at byte offset [offset].
  BitReader(this._data, [this._bytePos = 0]);

  /// Current byte position in the underlying buffer.
  int get bytePosition => _bytePos;

  /// Current bit offset within the current byte (0–7).
  int get bitPosition => _bitPos;

  /// Whether the reader has reached the end of the buffer.
  bool get isExhausted => _bytePos >= _data.length;

  /// Total number of remaining bits.
  int get remainingBits =>
      (_data.length - _bytePos) * 8 - _bitPos;

  /// Read [count] bits (LSB-first) and return as an unsigned integer.
  ///
  /// [count] must be in the range 0–32.
  int readBits(int count) {
    assert(count >= 0 && count <= 32, 'count must be 0..32');
    if (count == 0) return 0;

    int result = 0;
    int bitsRead = 0;

    while (bitsRead < count) {
      if (_bytePos >= _data.length) {
        throw StateError('BitReader: attempted to read past end of buffer');
      }

      final bitsAvailable = 8 - _bitPos;
      final bitsToRead = (count - bitsRead) < bitsAvailable
          ? (count - bitsRead)
          : bitsAvailable;

      final mask = (1 << bitsToRead) - 1;
      final bits = (_data[_bytePos] >> _bitPos) & mask;

      result |= bits << bitsRead;
      bitsRead += bitsToRead;
      _bitPos += bitsToRead;

      if (_bitPos >= 8) {
        _bitPos = 0;
        _bytePos++;
      }
    }

    return result;
  }

  /// Read a single bit.
  int readBit() => readBits(1);

  /// Read a full byte (8 bits), respecting the current bit alignment.
  int readByte() => readBits(8);

  /// Align the reader to the next byte boundary.
  void alignToByte() {
    if (_bitPos > 0) {
      _bitPos = 0;
      _bytePos++;
    }
  }

  /// Read [count] raw bytes (must be byte-aligned).
  List<int> readBytes(int count) {
    alignToByte();
    if (_bytePos + count > _data.length) {
      throw StateError('BitReader: attempted to read $count bytes past end');
    }
    final result = _data.sublist(_bytePos, _bytePos + count);
    _bytePos += count;
    return result;
  }

  /// Skip [count] bits.
  void skipBits(int count) {
    _bitPos += count;
    _bytePos += _bitPos ~/ 8;
    _bitPos = _bitPos % 8;
  }

  /// Read a little-endian 32-bit unsigned integer (byte-aligned).
  int readUint32LE() {
    alignToByte();
    if (_bytePos + 4 > _data.length) {
      throw StateError('BitReader: attempted to read uint32 past end');
    }
    final value = _data[_bytePos] |
        (_data[_bytePos + 1] << 8) |
        (_data[_bytePos + 2] << 16) |
        (_data[_bytePos + 3] << 24);
    _bytePos += 4;
    return value & 0xFFFFFFFF;
  }

  /// Read a little-endian 16-bit unsigned integer (byte-aligned).
  int readUint16LE() {
    alignToByte();
    if (_bytePos + 2 > _data.length) {
      throw StateError('BitReader: attempted to read uint16 past end');
    }
    final value = _data[_bytePos] | (_data[_bytePos + 1] << 8);
    _bytePos += 2;
    return value & 0xFFFF;
  }
}
