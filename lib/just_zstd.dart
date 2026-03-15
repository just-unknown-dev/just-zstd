/// Pure Dart Zstandard (RFC 8878) decompression.
///
/// Provides [ZstdDecoder] for decompressing Zstandard-compressed data.
///
/// ```dart
/// import 'package:just_zstd/just_zstd.dart';
///
/// final decoder = ZstdDecoder();
/// final decompressed = decoder.decode(compressedBytes);
/// ```
library;

export 'src/zstd_decoder.dart';
export 'src/bit_reader.dart';
export 'src/fse_table.dart';
export 'src/huffman_table.dart';
