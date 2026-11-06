# Changelog

## [0.3.0] - 2026-11-05

The decoder is rewritten to the format's specification (RFC 8878). 0.2.0 read only raw and RLE blocks right: on a compressed block, which is what the zstd library and Tiled write, it returned the wrong bytes without an error (52 bytes, all wrong, for a 40 × 30 tile layer of 4,800).

### Breaking
- `ZstdDecoder.decode` returns a `Uint8List`, and `decodeBytes` is removed: call `decode`, which takes any `List<int>`.
- `ZstdEncoder.encodeBytes` is removed: call `encode`.
- `BitReader`, `FseTable`, `FseEntry`, `HuffmanTable` and `HuffmanEntry` are no longer exported. They were internals, and wrong: the FSE table builder and the Huffman decoder didn't follow the format. The library exports only `ZstdDecoder` and `ZstdEncoder`.

### Added
- **`decode(data, maxOutputSize:)`**, a cap on the output. Data that would decompress to more throws `FormatException` as soon as it passes the cap, before the memory is taken; a frame whose header already says more is refused before any block is read. Give it whenever the expected size is known, or the data is untrusted.
- **Content checksums are checked.** A frame with a checksum must match it (the low 32 bits of XXH64), the same on native, web and Wasm.
- **Several frames in a row** decode as one stream, with skippable frames between them.

### Fixed
- **Compressed blocks decode right**: Huffman-coded literals (one stream or four, a new tree or the last one), RLE literals, FSE-coded sequences in every mode (default, RLE, described, repeat), repeat offsets, and matches reaching back across blocks. Checked byte for byte against libzstd 1.5.7 and Tiled 1.11.2 (below).
- **No output limit**: a 13-byte frame expanded to 65,536 bytes, and a few KB of RLE blocks to hundreds of MB. Each block is now held to its maximum (128 KiB, or the frame's window if smaller) as it is written, as well as to `maxOutputSize`.
- **The encoder wrote frames no decoder could read.** Its header said the content size took 2 bytes and then wrote 4. It now writes `0xA0` (a 4-byte size, single segment); libzstd reads its frames, and the example runs.
- The frame header is read in full: 8-byte content sizes, the window size (which sets the block maximum), and the reserved bit. A frame that needs a dictionary is refused with a `FormatException` naming it, rather than decoded wrong, and the content must be the size the header says.
- Damaged data throws `FormatException`, never a `RangeError` or `StateError`, and never loops.
- The three `dangling_library_doc_comments` infos are gone.

### Tests
- 48, up from 4. Frames the zstd library made (libzstd 1.5.7 through Python's `compression.zstd`; `test/fixtures/make_fixtures.py`) cover every block type, literals section and sequence mode, checksums, frames without a content size, a 1 KiB window, a match 156 KB back, skippable and concatenated frames, and a dictionary frame. Two tile layers Tiled 1.11.2 saved with "Base64 (Zstandard compressed)" decode to the tiles Tiled wrote. Also: the output cap, cut-short frames (every length), 1,500 damaged frames, XXH64 in both forms, the bit readers, and the encoder's bytes.

---

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
