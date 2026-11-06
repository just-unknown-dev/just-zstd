// The contents of the frames in test/fixtures, built again byte for byte
// from the recipes in manifest.json: the same generators as
// test/fixtures/make_fixtures.py.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _words = [
  'the', 'tile', 'map', 'layer', 'water', 'grass', 'stone', 'tree', 'hero', //
  'door', 'key', 'coin', 'castle', 'cave', 'bridge', 'river', 'north',
  'south', 'gate', 'torch', 'spike', 'ladder', 'chest', 'enemy', 'jump',
  'run', 'and', 'of', 'to', 'a', 'in', 'is', 'zstandard',
];

/// The generator every recipe draws from: 31-bit values.
Iterator<int> _lcg(int seed) => _sequence(seed).iterator;

Iterable<int> _sequence(int seed) sync* {
  while (true) {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    yield seed;
  }
}

int _next(Iterator<int> r) => (r..moveNext()).current;

List<int> _text(int n, int seed) {
  final r = _lcg(seed);
  final out = <int>[];
  while (out.length < n) {
    out.addAll(utf8.encode(_words[(_next(r) >> 8) % _words.length]));
    final s = _next(r);
    out.addAll(
      utf8.encode(
        s % 13 == 0
            ? '.\n'
            : s % 7 == 0
            ? ', '
            : ' ',
      ),
    );
  }
  return out.sublist(0, n);
}

List<int> _tiles(int w, int h, int seed) {
  final r = _lcg(seed);
  final out = ByteData(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = _next(r);
      var gid = y < h ~/ 3 ? 0 : 1 + ((x >> 3) + (y >> 2)) % 4;
      if (v % 16 == 0) gid = 20 + (v >> 8) % 10;
      if (v % 11 == 0) gid |= 0x80000000;
      out.setUint32((y * w + x) * 4, gid, Endian.little);
    }
  }
  return out.buffer.asUint8List();
}

List<int> _noise(int n, int seed) {
  final r = _lcg(seed);
  return [for (var i = 0; i < n; i++) (_next(r) >> 7) & 0xFF];
}

List<int> _letters(int n, int k, int seed) {
  final r = _lcg(seed);
  return [for (var i = 0; i < n; i++) 97 + (_next(r) >> 9) % k];
}

List<int> _runs(int n) => [
  for (var i = 0; i < n; i++) ...[...List.filled(50, 0x61), 0x62],
];

List<int> _slices(int seed) {
  final noise = _noise(900, seed);
  return [
    ...noise,
    for (var i = 0; i < 60; i++) ...[
      0x5A,
      ...noise.sublist((i * 37) % 800, (i * 37) % 800 + 40),
    ],
  ];
}

/// The bytes [recipe] (a list of segments, as in manifest.json) builds.
Uint8List build(List<Object?> recipe) {
  final parts = <List<int>>[];
  for (final segment in recipe.cast<List<Object?>>()) {
    final args = segment.skip(1).cast<int>().toList();
    parts.add(switch (segment.first) {
      'text' => _text(args[0], args[1]),
      'tiles' => _tiles(args[0], args[1], args[2]),
      'noise' => _noise(args[0], args[1]),
      'letters' => _letters(args[0], args[1], args[2]),
      'runs' => _runs(args[0]),
      'slices' => _slices(args[0]),
      'fill' => List.filled(args[0], args[1]),
      'again' => parts[args[0]],
      final kind => throw ArgumentError('unknown recipe kind $kind'),
    });
  }
  return Uint8List.fromList([for (final part in parts) ...part]);
}

/// The raw tile id Tiled saved at ([x], [y]) of the [w] x [h] layers of
/// the tiled_*.zst fixtures (the formula of the script that made them).
int tiledTileAt(int x, int y, int w, int h) {
  final i = y * w + x;
  final r = (i * 7919 + 17) % 65521;
  var id = y < h ~/ 3 ? 0 : 1 + ((x >> 3) + (y >> 2)) % 4;
  if (r % 16 == 0) id = 20 + (r >> 4) % 10;
  if (id == 0) return 0;
  return i % 11 == 0 ? id | 0x80000000 : id;
}

/// A [w] x [h] layer of [tiledTileAt], as little-endian 32-bit ids.
Uint8List tiledLayer(int w, int h) {
  final out = ByteData(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      out.setUint32((y * w + x) * 4, tiledTileAt(x, y, w, h), Endian.little);
    }
  }
  return out.buffer.asUint8List();
}

/// A fixture's bytes.
Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

/// test/fixtures/manifest.json.
Map<String, Object?> manifest() =>
    jsonDecode(File('test/fixtures/manifest.json').readAsStringSync())
        as Map<String, Object?>;
