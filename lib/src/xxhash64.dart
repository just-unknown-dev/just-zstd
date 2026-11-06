/// XXH64, the hash a Zstandard frame's content checksum is made from
/// (RFC 8878 §3.1.1: the low 32 bits of XXH64 with seed 0).
///
/// Internal: not exported. Two forms give the same hash: one in 64-bit
/// integers, for the VM and Wasm, and one in 32-bit halves for the web,
/// where integers are doubles.
library;

import 'dart:typed_data';

/// Whether integers are JavaScript numbers (web, compiled to JavaScript).
const bool _jsNumbers = identical(1, 1.0);

/// The low 32 bits of XXH64 (seed 0) of bytes [start] to [end] of [data].
int xxh64Low32(Uint8List data, int start, int end) => _jsNumbers
    ? xxh64Halves(data, start, end).$2
    : xxh64(data, start, end) & 0xFFFFFFFF;

// The five primes, as 32-bit halves.
const _p1Hi = 0x9E3779B1, _p1Lo = 0x85EBCA87;
const _p2Hi = 0xC2B2AE3D, _p2Lo = 0x27D4EB4F;
const _p3Hi = 0x165667B1, _p3Lo = 0x9E3779F9;
const _p4Hi = 0x85EBCA77, _p4Lo = 0xC2B2AE63;
const _p5Hi = 0x27D4EB2F, _p5Lo = 0x165667C5;

/// XXH64 (seed 0) of bytes [start] to [end] of [data], in 64-bit integers,
/// which wrap. Not for the web.
int xxh64(Uint8List data, int start, int end) {
  final p1 = (_p1Hi << 32) | _p1Lo;
  final p2 = (_p2Hi << 32) | _p2Lo;
  final p3 = (_p3Hi << 32) | _p3Lo;
  final p4 = (_p4Hi << 32) | _p4Lo;
  final p5 = (_p5Hi << 32) | _p5Lo;
  int rotl(int x, int r) => (x << r) | (x >>> (64 - r));
  int round(int acc, int lane) => rotl(acc + lane * p2, 31) * p1;
  final view = ByteData.sublistView(data, start, end);
  int lane64(int at) =>
      view.getUint32(at, Endian.little) |
      (view.getUint32(at + 4, Endian.little) << 32);

  final length = end - start;
  var at = 0;
  int h;
  if (length >= 32) {
    var v1 = p1 + p2;
    var v2 = p2;
    var v3 = 0;
    var v4 = -p1;
    for (; at + 32 <= length; at += 32) {
      v1 = round(v1, lane64(at));
      v2 = round(v2, lane64(at + 8));
      v3 = round(v3, lane64(at + 16));
      v4 = round(v4, lane64(at + 24));
    }
    h = rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18);
    for (final v in [v1, v2, v3, v4]) {
      h = (h ^ round(0, v)) * p1 + p4;
    }
  } else {
    h = p5;
  }
  h += length;
  for (; at + 8 <= length; at += 8) {
    h = rotl(h ^ round(0, lane64(at)), 27) * p1 + p4;
  }
  if (at + 4 <= length) {
    h = rotl(h ^ (view.getUint32(at, Endian.little) * p1), 23) * p2 + p3;
    at += 4;
  }
  for (; at < length; at++) {
    h = rotl(h ^ (view.getUint8(at) * p5), 11) * p1;
  }
  h = (h ^ (h >>> 33)) * p2;
  h = (h ^ (h >>> 29)) * p3;
  return h ^ (h >>> 32);
}

/// XXH64 (seed 0) of bytes [start] to [end] of [data], as its high and low
/// 32 bits. Works the same everywhere: every value stays below 2^53.
(int, int) xxh64Halves(Uint8List data, int start, int end) {
  final view = ByteData.sublistView(data, start, end);
  final length = end - start;
  var at = 0;
  _U64 h;
  if (length >= 32) {
    var v1 = _U64(_p1Hi, _p1Lo).plus(_U64(_p2Hi, _p2Lo));
    var v2 = _U64(_p2Hi, _p2Lo);
    var v3 = _U64(0, 0);
    var v4 = _U64(0, 0).minus(_U64(_p1Hi, _p1Lo));
    for (; at + 32 <= length; at += 32) {
      v1 = _round(v1, _lane(view, at));
      v2 = _round(v2, _lane(view, at + 8));
      v3 = _round(v3, _lane(view, at + 16));
      v4 = _round(v4, _lane(view, at + 24));
    }
    h = v1.rotl(1).plus(v2.rotl(7)).plus(v3.rotl(12)).plus(v4.rotl(18));
    for (final v in [v1, v2, v3, v4]) {
      h = h
          .xor(_round(_U64(0, 0), v))
          .times(_U64(_p1Hi, _p1Lo))
          .plus(_U64(_p4Hi, _p4Lo));
    }
  } else {
    h = _U64(_p5Hi, _p5Lo);
  }
  h = h.plus(_U64(0, length));
  for (; at + 8 <= length; at += 8) {
    h = h
        .xor(_round(_U64(0, 0), _lane(view, at)))
        .rotl(27)
        .times(_U64(_p1Hi, _p1Lo))
        .plus(_U64(_p4Hi, _p4Lo));
  }
  if (at + 4 <= length) {
    h = h
        .xor(
          _U64(0, view.getUint32(at, Endian.little)).times(_U64(_p1Hi, _p1Lo)),
        )
        .rotl(23)
        .times(_U64(_p2Hi, _p2Lo))
        .plus(_U64(_p3Hi, _p3Lo));
    at += 4;
  }
  for (; at < length; at++) {
    h = h
        .xor(_U64(0, view.getUint8(at)).times(_U64(_p5Hi, _p5Lo)))
        .rotl(11)
        .times(_U64(_p1Hi, _p1Lo));
  }
  h = h.xor(h.shiftRight(33)).times(_U64(_p2Hi, _p2Lo));
  h = h.xor(h.shiftRight(29)).times(_U64(_p3Hi, _p3Lo));
  h = h.xor(h.shiftRight(32));
  return (h.hi, h.lo);
}

_U64 _lane(ByteData view, int at) => _U64(
  view.getUint32(at + 4, Endian.little),
  view.getUint32(at, Endian.little),
);

_U64 _round(_U64 acc, _U64 lane) =>
    acc.plus(lane.times(_U64(_p2Hi, _p2Lo))).rotl(31).times(_U64(_p1Hi, _p1Lo));

/// An unsigned 64-bit value as two 32-bit halves, with arithmetic that
/// wraps at 2^64 and never leaves the exact range of a double.
final class _U64 {
  const _U64(this.hi, this.lo);

  final int hi;
  final int lo;

  _U64 plus(_U64 other) {
    final low = lo + other.lo;
    final carry = low >= 0x100000000 ? 1 : 0;
    return _U64((hi + other.hi + carry) & 0xFFFFFFFF, low & 0xFFFFFFFF);
  }

  _U64 minus(_U64 other) {
    final low = lo - other.lo;
    final borrow = low < 0 ? 1 : 0;
    return _U64((hi - other.hi - borrow) & 0xFFFFFFFF, low & 0xFFFFFFFF);
  }

  _U64 xor(_U64 other) =>
      _U64((hi ^ other.hi) & 0xFFFFFFFF, (lo ^ other.lo) & 0xFFFFFFFF);

  /// The product, wrapped to 64 bits.
  _U64 times(_U64 other) {
    // lo × lo in full, from 16-bit pieces; the cross terms only matter in
    // their low 32 bits, which land in the high half.
    final a0 = lo & 0xFFFF, a1 = lo >> 16;
    final b0 = other.lo & 0xFFFF, b1 = other.lo >> 16;
    final middle = a0 * b1 + a1 * b0;
    final low = a0 * b0 + (middle & 0xFFFF) * 0x10000;
    final carry = (low / 0x100000000).floor();
    final high =
        a1 * b1 +
        (middle / 0x10000).floor() +
        carry +
        _times32(hi, other.lo) +
        _times32(lo, other.hi);
    return _U64(high % 0x100000000, low % 0x100000000);
  }

  /// The low 32 bits of [a] × [b].
  static int _times32(int a, int b) {
    final a0 = a & 0xFFFF, a1 = a >> 16;
    final b0 = b & 0xFFFF, b1 = b >> 16;
    return (a0 * b0 + ((a0 * b1 + a1 * b0) % 0x10000) * 0x10000) % 0x100000000;
  }

  _U64 rotl(int r) {
    if (r >= 32) return _U64(lo, hi).rotl(r - 32);
    if (r == 0) return this;
    return _U64(
      ((hi << r) | (lo >> (32 - r))) & 0xFFFFFFFF,
      ((lo << r) | (hi >> (32 - r))) & 0xFFFFFFFF,
    );
  }

  _U64 shiftRight(int r) {
    if (r >= 32) return _U64(0, hi >> (r - 32));
    return _U64(hi >> r, ((lo >> r) | (hi << (32 - r))) & 0xFFFFFFFF);
  }
}
