"""Makes the Zstandard frames in this folder with the real zstd library.

Run with Python 3.14 or later, whose standard library binds libzstd
(`compression.zstd`, PEP 784):

    python -I test/fixtures/make_fixtures.py test/fixtures

Each frame's content is built from a recipe that test/recipes.dart builds
again, byte for byte, so the frames need no stored originals. The recipes
and the settings each frame was made with are in manifest.json.

tiled_40x30.zst and tiled_256x160.zst are not made here: they are tile
layers Tiled 1.11.2 saved ("Base64 (Zstandard compressed)"), cut from the
maps a Tiled script wrote. Their tiles follow tiledTileAt in recipes.dart.
"""
import json
import os
import sys
from compression import zstd

P = zstd.CompressionParameter

WORDS = [
    'the', 'tile', 'map', 'layer', 'water', 'grass', 'stone', 'tree', 'hero',
    'door', 'key', 'coin', 'castle', 'cave', 'bridge', 'river', 'north',
    'south', 'gate', 'torch', 'spike', 'ladder', 'chest', 'enemy', 'jump',
    'run', 'and', 'of', 'to', 'a', 'in', 'is', 'zstandard',
]


def lcg(seed):
    while True:
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        yield seed


def text(n, seed):
    r = lcg(seed)
    out = bytearray()
    while len(out) < n:
        out += WORDS[(next(r) >> 8) % len(WORDS)].encode()
        s = next(r)
        out += b'.\n' if s % 13 == 0 else (b', ' if s % 7 == 0 else b' ')
    return bytes(out[:n])


def tiles(w, h, seed):
    r = lcg(seed)
    out = bytearray()
    for y in range(h):
        for x in range(w):
            v = next(r)
            gid = 0 if y < h // 3 else 1 + ((x >> 3) + (y >> 2)) % 4
            if v % 16 == 0:
                gid = 20 + (v >> 8) % 10
            if v % 11 == 0:
                gid |= 0x80000000
            out += gid.to_bytes(4, 'little')
    return bytes(out)


def noise(n, seed):
    r = lcg(seed)
    return bytes((next(r) >> 7) & 0xFF for _ in range(n))


def letters(n, k, seed):
    """n letters from the first k of the alphabet: Huffman-coded, but with
    no matches long enough to use."""
    r = lcg(seed)
    return bytes(97 + (next(r) >> 9) % k for _ in range(n))


def runs(n):
    """n runs of 50 a's and a b: every sequence alike."""
    return (b'a' * 50 + b'b') * n


def slices(seed):
    """900 bytes of noise, then 60 slices of it, each after a Z: blocks
    whose only literals are Z's."""
    nz = noise(900, seed)
    return nz + b''.join(
        b'Z' + nz[(i * 37) % 800:(i * 37) % 800 + 40] for i in range(60))


def build(recipe):
    parts = []
    for seg in recipe:
        kind = seg[0]
        if kind == 'text':
            parts.append(text(seg[1], seg[2]))
        elif kind == 'tiles':
            parts.append(tiles(seg[1], seg[2], seg[3]))
        elif kind == 'noise':
            parts.append(noise(seg[1], seg[2]))
        elif kind == 'letters':
            parts.append(letters(seg[1], seg[2], seg[3]))
        elif kind == 'runs':
            parts.append(runs(seg[1]))
        elif kind == 'slices':
            parts.append(slices(seg[1]))
        elif kind == 'fill':
            parts.append(bytes([seg[2]]) * seg[1])
        elif kind == 'again':
            parts.append(parts[seg[1]])
        else:
            raise ValueError(kind)
    return b''.join(parts)


def options(settings):
    names = {
        'level': P.compression_level,
        'checksum': P.checksum_flag,
        'contentSize': P.content_size_flag,
        'windowLog': P.window_log,
        'strategy': P.strategy,
        'ldm': P.enable_long_distance_matching,
    }
    return {names[k]: v for k, v in settings.items()}


# name: (recipe, settings)
FRAMES = {
    'empty': ([], {'level': 3, 'checksum': 1}),
    'one_byte': ([['fill', 1, 120]], {'level': 3, 'checksum': 1}),
    'text_1k_level1': ([['text', 1000, 1]], {'level': 1}),
    'text_1k_level19': ([['text', 1000, 2]], {'level': 19, 'checksum': 1}),
    'text_30k_level3': ([['text', 30000, 3]], {'level': 3, 'checksum': 1}),
    'text_30k_level22': ([['text', 30000, 4]], {'level': 22, 'checksum': 1}),
    'text_20k_fast': ([['text', 20000, 5]], {'level': -5, 'checksum': 1}),
    'tiles_64x64_level19': ([['tiles', 64, 64, 6]], {'level': 19}),
    'tiles_256x256_level3': ([['tiles', 256, 256, 7]], {'level': 3, 'checksum': 1}),
    'tiles_256x256_level19': ([['tiles', 256, 256, 8]], {'level': 19, 'checksum': 1}),
    'noise_5k': ([['noise', 5000, 9]], {'level': 3, 'checksum': 1}),
    'zeros_300k': ([['fill', 300000, 0]], {'level': 3, 'checksum': 1}),
    'mixed_blocks': (
        [['noise', 3000, 10], ['text', 40000, 11], ['fill', 140000, 7],
         ['tiles', 100, 100, 12], ['again', 0]],
        {'level': 9, 'checksum': 1},
    ),
    'far_match': (
        [['noise', 6000, 13], ['fill', 150000, 0], ['again', 0]],
        {'level': 19, 'checksum': 1, 'windowLog': 20},
    ),
    'no_content_size': ([['text', 10000, 14]], {'level': 3, 'checksum': 1, 'contentSize': 0}),
    'small_window': ([['text', 50000, 15]], {'level': 3, 'checksum': 1, 'windowLog': 10}),
    'no_checksum_large': ([['tiles', 200, 200, 16]], {'level': 6}),
    'rle_tables': ([['runs', 200]], {'level': 1, 'checksum': 1}),
    'literals_only': ([['letters', 4000, 16, 22]], {'level': 3, 'checksum': 1}),
    'rle_literals': ([['slices', 21]], {'level': 19, 'checksum': 1, 'windowLog': 10}),
}


def main(out_dir):
    manifest = {'zstd': zstd.zstd_version, 'frames': [], 'concatenated': None,
                'dictionary': None}
    for name, (recipe, settings) in FRAMES.items():
        data = build(recipe)
        frame = zstd.compress(data, options=options(settings))
        assert zstd.decompress(frame) == data
        open(os.path.join(out_dir, name + '.zst'), 'wb').write(frame)
        manifest['frames'].append({'file': name + '.zst', 'recipe': recipe,
                                   'settings': settings, 'size': len(data)})

    # Two frames with a skippable frame between them: one stream.
    a = build([['text', 2000, 17]])
    b = build([['tiles', 32, 32, 18]])
    skippable = (0x184D2A53).to_bytes(4, 'little') + (5).to_bytes(4, 'little') + b'skip!'
    stream = (zstd.compress(a, options=options({'level': 3, 'checksum': 1}))
              + skippable
              + zstd.compress(b, options=options({'level': 19})))
    assert zstd.decompress(stream) == a + b
    open(os.path.join(out_dir, 'concatenated.zst'), 'wb').write(stream)
    manifest['concatenated'] = {'file': 'concatenated.zst',
                                'recipe': [['text', 2000, 17], ['tiles', 32, 32, 18]]}

    # A frame that needs a dictionary, which the decoder doesn't take.
    samples = [text(400, 100 + i) for i in range(200)]
    zdict = zstd.train_dict(samples, 4096)
    frame = zstd.compress(text(400, 999), options=options({'level': 3}), zstd_dict=zdict)
    open(os.path.join(out_dir, 'needs_dictionary.zst'), 'wb').write(frame)
    manifest['dictionary'] = {'file': 'needs_dictionary.zst', 'dictId': zdict.dict_id}

    with open(os.path.join(out_dir, 'manifest.json'), 'w', newline='\n') as f:
        json.dump(manifest, f, indent=1)
        f.write('\n')


if __name__ == '__main__':
    main(sys.argv[1])
