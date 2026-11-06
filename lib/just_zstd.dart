/// Pure Dart Zstandard (RFC 8878): [ZstdDecoder] reads any Zstandard data
/// that needs no dictionary; [ZstdEncoder] writes valid, uncompressed
/// frames.
///
/// ```dart
/// import 'package:just_zstd/just_zstd.dart';
///
/// const decoder = ZstdDecoder();
/// final decompressed = decoder.decode(compressedBytes, maxOutputSize: 4800);
/// ```
library;

export 'src/zstd_decoder.dart' show ZstdDecoder;
export 'src/zstd_encoder.dart' show ZstdEncoder;
