"""Exits 0 when a simulator screenshot is still blank (the app has not drawn yet), 1 when it shows something.

A slow simulator can be captured before the app draws its first frame: the picture is then one flat color
with only the status bar. Its pixel rows, once unpacked, are almost all zero, while any drawn screen has
far more change in it (measured: blank 0.0004, the plainest real screen 0.0157).
"""
import struct
import sys
import zlib


def busyness(path):
    data = open(path, 'rb').read()
    position, pixels = 8, b''
    while position < len(data):
        length, kind = struct.unpack('>I4s', data[position:position + 8])
        if kind == b'IDAT':
            pixels += data[position + 8:position + 8 + length]
        position += 12 + length
    raw = zlib.decompress(pixels)[::7]
    return sum(1 for byte in raw if byte) / max(1, len(raw))


if __name__ == '__main__':
    sys.exit(0 if busyness(sys.argv[1]) < 0.003 else 1)
