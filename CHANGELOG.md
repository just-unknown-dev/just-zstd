# Changelog

## [0.2.0] - 2026-04-22

### Added

- **ZstdEncoder** — Zstandard frame encoder producing raw (uncompressed) blocks.
  - `encode(List<int>)` and `encodeBytes(Uint8List)` for creating valid Zstandard frames.
  - Frame header generation: magic number, frame descriptor, content size, and block headers.
  - Raw block encoding for O(n) performance with minimal overhead.
  - Output is fully compatible with `ZstdDecoder`.

## [0.1.0] - 2026-03-15

### Added

- **ZstdDecoder** — main decompressor implementing the Zstandard (RFC 8878) frame format.
  - `decode(List<int>)` and `decodeBytes(Uint8List)` for decompressing Zstandard frames.
  - Frame header parsing: magic number validation, frame descriptor, window size, optional dictionary ID and content checksum flags.
  - Three block types: raw (direct copy), RLE (run-length), and compressed (entropy-coded).
  - Skippable frame support (`0x184D2A50`–`0x184D2A5F`).
  - Descriptive `FormatException` on malformed input.
- **BitReader** — LSB-first bit-level stream reader.
  - `readBits()`, `readBit()`, `readByte()`, `readBytes()`, `readUint32LE()`, `readUint16LE()`.
  - Byte/bit position tracking, alignment helpers, and buffer-overrun guards.
- **FseTable** / **FseEntry** — tANS (table-based Asymmetric Numeral Systems) entropy decoder.
  - `FseTable.build()` constructs a decoding table from a normalised probability distribution.
  - `readNormalizedDistribution()` reads the compressed distribution header from the bitstream.
  - Used for literal-length, match-length, and offset codes in compressed blocks.
- **HuffmanTable** / **HuffmanEntry** — canonical Huffman decoder for the literals section.
  - `HuffmanTable.fromWeights()` builds the table from symbol weights.
  - `readWeights()` supports both FSE-compressed and direct weight header formats.
- Pure Dart implementation — no `dart:ffi`, no native extensions, no external dependencies.
- Unit tests for `BitReader` and `ZstdDecoder` error handling.
- Example usage in `example/just_zstd_example.dart`.
