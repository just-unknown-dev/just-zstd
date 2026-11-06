/// Zstandard decompression (RFC 8878).
library;

import 'dart:typed_data';

import 'bit_readers.dart';
import 'fse_table.dart';
import 'huffman_table.dart';
import 'xxhash64.dart';

/// Decompresses Zstandard data (RFC 8878): one frame, or several one after
/// another, skippable frames included.
///
/// Every block type, literals section type and sequence coding mode is
/// read, and a frame's content checksum is checked when it has one.
/// Frames that need a dictionary are refused.
///
/// Stateless; one instance can be shared.
///
/// ```dart
/// const decoder = ZstdDecoder();
/// final bytes = decoder.decode(compressed, maxOutputSize: 1 << 20);
/// ```
class ZstdDecoder {
  /// A decoder.
  const ZstdDecoder();

  /// The bytes [data] decompresses to.
  ///
  /// [maxOutputSize] caps the output: data that would decompress to more
  /// throws as soon as it passes the cap, before the memory is taken. Give
  /// it whenever the expected size is known, or the data is untrusted.
  ///
  /// Throws [FormatException] if [data] is not valid Zstandard data, needs
  /// a dictionary, fails its checksum, or would decompress to more than
  /// [maxOutputSize] bytes.
  Uint8List decode(List<int> data, {int? maxOutputSize}) {
    if (maxOutputSize != null && maxOutputSize < 0) {
      throw ArgumentError.value(maxOutputSize, 'maxOutputSize', 'negative');
    }
    final input = data is Uint8List ? data : Uint8List.fromList(data);
    final out = _Output(maxOutputSize);
    try {
      var pos = 0;
      do {
        pos = _frame(input, pos, out);
      } while (pos < input.length);
    } on RangeError {
      // Every read is checked; this is a backstop, so that damaged data
      // can only ever throw a FormatException.
      throw const FormatException('zstd: damaged data');
    }
    return out.takeBytes();
  }
}

const _frameMagic = 0xFD2FB528;

/// The largest block the format allows, before any smaller window.
const _maxBlockSize = 128 * 1024;

/// Decodes the frame that starts at [pos] of [input] into [out]; returns
/// where the next frame starts.
int _frame(Uint8List input, int pos, _Output out) {
  if (pos + 4 > input.length) {
    throw const FormatException('zstd: truncated frame');
  }
  final magic = _u32(input, pos);
  if ((magic & 0xFFFFFFF0) == 0x184D2A50) {
    // A skippable frame: its size, then that many bytes of anything.
    if (pos + 8 > input.length) {
      throw const FormatException('zstd: truncated skippable frame');
    }
    final next = pos + 8 + _u32(input, pos + 4);
    if (next > input.length) {
      throw const FormatException('zstd: truncated skippable frame');
    }
    return next;
  }
  if (magic != _frameMagic) {
    throw FormatException(
      'zstd: not a Zstandard frame (magic number 0x'
      '${magic.toRadixString(16).padLeft(8, '0')})',
    );
  }

  // The frame header (RFC 8878 §3.1.1.1).
  var p = pos + 4;
  _need(input, p, 1, 'frame header');
  final descriptor = input[p++];
  final contentSizeFlag = descriptor >> 6;
  final singleSegment = (descriptor >> 5) & 1 == 1;
  if ((descriptor >> 3) & 1 == 1) {
    throw const FormatException('zstd: reserved frame header bit is set');
  }
  final hasChecksum = (descriptor >> 2) & 1 == 1;
  final dictionaryIdSize = const [0, 1, 2, 4][descriptor & 3];

  var blockMax = _maxBlockSize;
  if (!singleSegment) {
    _need(input, p, 1, 'frame header');
    final window = input[p++];
    final windowLog = 10 + (window >> 3);
    if (windowLog < 17) {
      final base = 1 << windowLog;
      final size = base + (base >> 3) * (window & 7);
      if (size < blockMax) blockMax = size;
    }
  }

  _need(input, p, dictionaryIdSize, 'frame header');
  var dictionaryId = 0;
  for (var i = 0; i < dictionaryIdSize; i++) {
    dictionaryId += input[p + i] * (1 << (8 * i));
  }
  p += dictionaryIdSize;
  if (dictionaryId != 0) {
    throw FormatException(
      'zstd: the frame needs dictionary $dictionaryId, '
      'and dictionaries are not supported',
    );
  }

  final contentSizeBytes = contentSizeFlag == 0
      ? (singleSegment ? 1 : 0)
      : const [0, 2, 4, 8][contentSizeFlag];
  _need(input, p, contentSizeBytes, 'frame header');
  int? contentSize;
  switch (contentSizeBytes) {
    case 1:
      contentSize = input[p];
    case 2:
      contentSize = input[p] + (input[p + 1] << 8) + 256;
    case 4:
      contentSize = _u32(input, p);
    case 8:
      contentSize = _u32(input, p) + _u32(input, p + 4) * 0x100000000;
  }
  p += contentSizeBytes;
  if (singleSegment && contentSize! < blockMax) blockMax = contentSize;

  final frameStart = out.length;
  if (contentSize != null) out.expect(contentSize);

  // The blocks (RFC 8878 §3.1.1.2).
  final state = _FrameState();
  var last = false;
  while (!last) {
    _need(input, p, 3, 'block header');
    final header = input[p] | (input[p + 1] << 8) | (input[p + 2] << 16);
    p += 3;
    last = header & 1 == 1;
    final type = (header >> 1) & 3;
    final size = header >> 3;
    if (size > blockMax) {
      throw FormatException(
        'zstd: block of $size bytes is over the maximum of $blockMax',
      );
    }
    switch (type) {
      case 0: // Raw
        _need(input, p, size, 'raw block');
        out.addRange(input, p, p + size);
        p += size;
      case 1: // RLE
        _need(input, p, 1, 'RLE block');
        out.fill(input[p], size);
        p += 1;
      case 2: // Compressed
        _need(input, p, size, 'compressed block');
        out.startBlock(blockMax);
        _compressedBlock(input, p, p + size, out, state, frameStart);
        out.endBlock();
        p += size;
      default:
        throw const FormatException('zstd: reserved block type');
    }
  }

  final produced = out.length - frameStart;
  if (contentSize != null && produced != contentSize) {
    throw FormatException(
      'zstd: frame decompresses to $produced bytes, '
      'but its header says $contentSize',
    );
  }
  if (hasChecksum) {
    _need(input, p, 4, 'content checksum');
    final expected = _u32(input, p);
    p += 4;
    if (out.checksum(frameStart) != expected) {
      throw const FormatException('zstd: content checksum does not match');
    }
  }
  return p;
}

/// What carries over from one block of a frame to the next.
final class _FrameState {
  /// The three most recent offsets, newest first.
  final offsets = [1, 4, 8];

  HuffmanTable? huffman;
  FseTable? literalLengths;
  FseTable? offsetCodes;
  FseTable? matchLengths;
}

/// Decodes the compressed block in bytes [start] to [end] of [input].
void _compressedBlock(
  Uint8List input,
  int start,
  int end,
  _Output out,
  _FrameState state,
  int frameStart,
) {
  // The literals section (RFC 8878 §3.1.1.3.1).
  var p = start;
  _needIn(p, 1, end, 'literals section');
  final b0 = input[p];
  final literalsType = b0 & 3;
  final sizeFormat = (b0 >> 2) & 3;
  Uint8List literals;
  var literalsStart = 0;
  int literalsCount;
  if (literalsType < 2) {
    // Raw or RLE: one size, in 5, 12 or 20 bits.
    final int headerSize;
    switch (sizeFormat) {
      case 1:
        headerSize = 2;
        _needIn(p, 2, end, 'literals header');
        literalsCount = (b0 >> 4) + (input[p + 1] << 4);
      case 3:
        headerSize = 3;
        _needIn(p, 3, end, 'literals header');
        literalsCount = (b0 >> 4) + (input[p + 1] << 4) + (input[p + 2] << 12);
      default:
        headerSize = 1;
        literalsCount = b0 >> 3;
    }
    p += headerSize;
    _checkLiteralsCount(literalsCount);
    if (literalsType == 0) {
      _needIn(p, literalsCount, end, 'raw literals');
      literals = input;
      literalsStart = p;
      p += literalsCount;
    } else {
      _needIn(p, 1, end, 'RLE literals');
      literals = Uint8List(literalsCount)
        ..fillRange(0, literalsCount, input[p]);
      p += 1;
    }
  } else {
    // Huffman-coded, with a new tree or the last one: two sizes, then one
    // stream or four.
    final headerSize = sizeFormat < 2 ? 3 : sizeFormat + 2;
    _needIn(p, headerSize, end, 'literals header');
    final b1 = input[p + 1], b2 = input[p + 2];
    int compressedSize;
    switch (sizeFormat) {
      case 2:
        literalsCount = (b0 >> 4) | (b1 << 4) | ((b2 & 3) << 12);
        compressedSize = (b2 >> 2) | (input[p + 3] << 6);
      case 3:
        literalsCount = (b0 >> 4) | (b1 << 4) | ((b2 & 0x3F) << 12);
        compressedSize = (b2 >> 6) | (input[p + 3] << 2) | (input[p + 4] << 10);
      default:
        literalsCount = (b0 >> 4) | ((b1 & 0x3F) << 4);
        compressedSize = (b1 >> 6) | (b2 << 2);
    }
    p += headerSize;
    _checkLiteralsCount(literalsCount);
    _needIn(p, compressedSize, end, 'Huffman literals');
    final streamsEnd = p + compressedSize;
    HuffmanTable table;
    if (literalsType == 2) {
      final (read, length) = HuffmanTable.read(input, p, streamsEnd);
      table = state.huffman = read;
      p += length;
    } else {
      table =
          state.huffman ??
          (throw const FormatException(
            'zstd: literals reuse a Huffman tree the frame has not had',
          ));
    }
    literals = Uint8List(literalsCount);
    if (sizeFormat == 0) {
      table.decode(input, p, streamsEnd, literals, 0, literalsCount);
    } else {
      // Four streams after a table of the first three's sizes; each gives
      // a quarter of the literals, the last one what is left.
      _needIn(p, 6, streamsEnd, 'Huffman jump table');
      final size1 = input[p] | (input[p + 1] << 8);
      final size2 = input[p + 2] | (input[p + 3] << 8);
      final size3 = input[p + 4] | (input[p + 5] << 8);
      p += 6;
      final size4 = streamsEnd - p - size1 - size2 - size3;
      final quarter = (literalsCount + 3) >> 2;
      if (size4 < 0 || quarter * 3 > literalsCount) {
        throw const FormatException('zstd: damaged Huffman jump table');
      }
      var at = 0;
      for (final (size, count) in [
        (size1, quarter),
        (size2, quarter),
        (size3, quarter),
        (size4, literalsCount - 3 * quarter),
      ]) {
        table.decode(input, p, p + size, literals, at, count);
        p += size;
        at += count;
      }
    }
    p = streamsEnd;
  }
  final literalsEnd = literalsStart + literalsCount;

  // The sequences section (RFC 8878 §3.1.1.3.2).
  _needIn(p, 1, end, 'sequences section');
  final s0 = input[p];
  int count;
  if (s0 < 128) {
    count = s0;
    p += 1;
  } else if (s0 < 255) {
    _needIn(p, 2, end, 'sequences header');
    count = ((s0 - 128) << 8) + input[p + 1];
    p += 2;
  } else {
    _needIn(p, 3, end, 'sequences header');
    count = input[p + 1] + (input[p + 2] << 8) + 0x7F00;
    p += 3;
  }
  if (count == 0) {
    // Literals only.
    if (p != end) {
      throw const FormatException(
        'zstd: data after an empty sequences section',
      );
    }
    out.addRange(literals, literalsStart, literalsEnd);
    return;
  }

  _needIn(p, 1, end, 'sequences header');
  final modes = input[p++];
  if (modes & 3 != 0) {
    throw const FormatException('zstd: reserved sequence mode bits are set');
  }
  final ll = state.literalLengths = _table(
    input,
    end,
    modes >> 6,
    _literalLengthsDefault,
    state.literalLengths,
    maxAccuracyLog: 9,
    maxSymbol: 35,
    at: p,
    advance: (to) => p = to,
  );
  final of = state.offsetCodes = _table(
    input,
    end,
    (modes >> 4) & 3,
    _offsetCodesDefault,
    state.offsetCodes,
    maxAccuracyLog: 8,
    maxSymbol: 31,
    at: p,
    advance: (to) => p = to,
  );
  final ml = state.matchLengths = _table(
    input,
    end,
    (modes >> 2) & 3,
    _matchLengthsDefault,
    state.matchLengths,
    maxAccuracyLog: 9,
    maxSymbol: 52,
    at: p,
    advance: (to) => p = to,
  );

  // The sequences, read backward, each executed as it is read.
  final stream = BackwardBitReader(input, p, end);
  var llState = stream.read(ll.accuracyLog);
  var ofState = stream.read(of.accuracyLog);
  var mlState = stream.read(ml.accuracyLog);
  final offsets = state.offsets;
  var literal = literalsStart;
  for (var i = 0; i < count; i++) {
    final ofCode = of.symbols[ofState];
    final mlCode = ml.symbols[mlState];
    final llCode = ll.symbols[llState];
    final offsetValue = (1 << ofCode) + stream.readLong(ofCode);
    final matchLength =
        _matchLengthBase[mlCode] + stream.read(_matchLengthBits[mlCode]);
    final literalLength =
        _literalLengthBase[llCode] + stream.read(_literalLengthBits[llCode]);

    // Offsets 1 to 3 repeat a recent one (RFC 8878 §3.1.2.5).
    int offset;
    if (offsetValue > 3) {
      offset = offsetValue - 3;
      offsets[2] = offsets[1];
      offsets[1] = offsets[0];
      offsets[0] = offset;
    } else {
      final index = offsetValue - 1 + (literalLength == 0 ? 1 : 0);
      if (index == 0) {
        offset = offsets[0];
      } else {
        offset = index < 3 ? offsets[index] : offsets[0] - 1;
        if (index > 1) offsets[2] = offsets[1];
        offsets[1] = offsets[0];
        offsets[0] = offset;
      }
    }

    if (i < count - 1) {
      llState = ll.bases[llState] + stream.read(ll.bits[llState]);
      mlState = ml.bases[mlState] + stream.read(ml.bits[mlState]);
      ofState = of.bases[ofState] + stream.read(of.bits[ofState]);
    }
    if (stream.overflowed) {
      throw const FormatException('zstd: sequences run past their stream');
    }

    if (literal + literalLength > literalsEnd) {
      throw const FormatException(
        'zstd: sequences take more literals than the block has',
      );
    }
    out.addRange(literals, literal, literal + literalLength);
    literal += literalLength;
    if (offset <= 0 || offset > out.length - frameStart) {
      throw FormatException(
        'zstd: match offset $offset reaches before the start of the frame',
      );
    }
    out.copyMatch(offset, matchLength);
  }
  if (stream.position != 0) {
    throw const FormatException(
      'zstd: sequence stream does not end with its last sequence',
    );
  }
  out.addRange(literals, literal, literalsEnd);
}

/// Throws unless a block may hold [count] literals.
void _checkLiteralsCount(int count) {
  if (count > _maxBlockSize) {
    throw const FormatException('zstd: too many literals for one block');
  }
}

/// The table one sequence field is coded with, by [mode]: the default,
/// one symbol, a table described at [at], or the [previous] block's.
FseTable _table(
  Uint8List input,
  int end,
  int mode,
  FseTable defaultTable,
  FseTable? previous, {
  required int maxAccuracyLog,
  required int maxSymbol,
  required int at,
  required void Function(int) advance,
}) {
  switch (mode) {
    case 0:
      return defaultTable;
    case 1:
      _needIn(at, 1, end, 'sequence table');
      final symbol = input[at];
      if (symbol > maxSymbol) {
        throw const FormatException('zstd: RLE sequence code out of range');
      }
      advance(at + 1);
      return FseTable.rle(symbol);
    case 2:
      final reader = ForwardBitReader(input, at, end);
      final table = FseTable.read(
        reader,
        maxAccuracyLog: maxAccuracyLog,
        maxSymbol: maxSymbol,
      );
      advance(reader.nextByte);
      return table;
    default:
      return previous ??
          (throw const FormatException(
            'zstd: sequences reuse a table the frame has not had',
          ));
  }
}

// The default distributions (RFC 8878 §3.1.1.3.2.2).
final _literalLengthsDefault = FseTable.fromCounts(const [
  4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, //
  2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
  -1, -1, -1, -1,
], 6);

final _matchLengthsDefault = FseTable.fromCounts(const [
  1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
  -1, -1, -1, -1, -1,
], 6);

final _offsetCodesDefault = FseTable.fromCounts(const [
  1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
], 5);

// What each literal length and match length code stands for: a base, and
// how many extra bits are added to it (RFC 8878 §3.1.1.3.2.1.1).
const _literalLengthBase = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
  8192, 16384, 32768, 65536,
];
const _literalLengthBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
  13, 14, 15, 16,
];
const _matchLengthBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, //
  19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
  35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
  4099, 8195, 16387, 32771, 65539,
];
const _matchLengthBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
  12, 13, 14, 15, 16,
];

int _u32(Uint8List data, int at) =>
    data[at] |
    (data[at + 1] << 8) |
    (data[at + 2] << 16) |
    ((data[at + 3] << 24) & 0xFFFFFFFF);

/// Throws unless [count] bytes from [at] are inside [input].
void _need(Uint8List input, int at, int count, String what) =>
    _needIn(at, count, input.length, what);

/// Throws unless [count] bytes from [at] end by [end].
void _needIn(int at, int count, int end, String what) {
  if (at + count > end) throw FormatException('zstd: truncated $what');
}

/// The decompressed bytes, growing as needed, never past the caller's cap
/// or a block's maximum.
final class _Output {
  _Output(this._max);

  final int? _max;
  Uint8List _bytes = Uint8List(0);

  /// How many bytes are written.
  int length = 0;

  /// Where the block being decoded must end by, at the latest.
  int _blockEnd = -1;
  int _blockMax = 0;

  /// A frame of [size] bytes is coming: refuses it now if it is over the
  /// cap, and makes room for it.
  void expect(int size) {
    final max = _max;
    if (max != null && length + size > max) throw _overCap(max);
    // A header can claim anything: reserve no more than 16 MiB on its word.
    _grow(length + (size < (1 << 24) ? size : (1 << 24)));
  }

  /// A compressed block of at most [max] bytes starts here.
  void startBlock(int max) {
    _blockEnd = length + max;
    _blockMax = max;
  }

  /// The compressed block is done.
  void endBlock() => _blockEnd = -1;

  void _ensure(int extra) {
    final needed = length + extra;
    final max = _max;
    if (max != null && needed > max) throw _overCap(max);
    if (_blockEnd >= 0 && needed > _blockEnd) {
      throw FormatException(
        'zstd: block decompresses to more than its maximum of $_blockMax bytes',
      );
    }
    if (needed > _bytes.length) {
      var capacity = _bytes.length * 2;
      if (capacity < needed) capacity = needed;
      if (capacity < 256) capacity = 256;
      if (max != null && capacity > max) capacity = max;
      _grow(capacity);
    }
  }

  void _grow(int capacity) {
    if (capacity <= _bytes.length) return;
    _bytes = Uint8List(capacity)..setRange(0, length, _bytes);
  }

  FormatException _overCap(int max) =>
      FormatException('zstd: data decompresses to more than $max bytes');

  void addRange(Uint8List source, int start, int end) {
    final count = end - start;
    if (count == 0) return;
    _ensure(count);
    _bytes.setRange(length, length + count, source, start);
    length += count;
  }

  void fill(int byte, int count) {
    if (count == 0) return;
    _ensure(count);
    _bytes.fillRange(length, length + count, byte);
    length += count;
  }

  /// Copies [count] bytes from [offset] back, which may overlap what is
  /// being written: a short offset repeats its bytes.
  void copyMatch(int offset, int count) {
    if (count == 0) return;
    _ensure(count);
    final bytes = _bytes;
    var from = length - offset;
    if (offset >= count) {
      bytes.setRange(length, length + count, bytes, from);
    } else {
      final end = length + count;
      for (var to = length; to < end; to++) {
        bytes[to] = bytes[from++];
      }
    }
    length += count;
  }

  /// The checksum of what was written from [start]: the low 32 bits of its
  /// XXH64.
  int checksum(int start) => xxh64Low32(_bytes, start, length);

  /// The bytes written, in a list of their own size.
  Uint8List takeBytes() =>
      _bytes.length == length ? _bytes : _bytes.sublist(0, length);
}
