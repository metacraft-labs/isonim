"""Convert a binary PPM (P6, maxval 255) from capture.sh to PNG.

usage: ppm_to_png.py in.ppm out.png [x y w h [scale]]

An optional crop box and an integer downscale keep a full-screen capture small
enough to read. Standard library only.
"""
import sys, zlib, struct
def read_ppm(path):
    """Returns (width, height, rgb bytes) of a binary PPM."""
    data = open(path, 'rb').read()
    pos = 0
    def token():
        nonlocal pos
        while data[pos:pos+1].isspace(): pos += 1
        start = pos
        while not data[pos:pos+1].isspace(): pos += 1
        return data[start:pos]
    assert token() == b'P6'
    w = int(token()); h = int(token()); assert token() == b'255'
    pos += 1
    return w, h, data[pos:pos + w*h*3]
def write_png(path, w, h, rgb):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += rgb[y*w*3:(y+1)*w*3]
    def chunk(tag, body):
        return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag + body) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 6)) + chunk(b'IEND', b'')
    open(path, 'wb').write(png)
if __name__ == '__main__':  # command-line use
    src, dst = sys.argv[1], sys.argv[2]
    W, H, rgb = read_ppm(src)
    x, y, w, h = (0, 0, W, H)
    scale = 1
    if len(sys.argv) >= 7:
        x, y, w, h = map(int, sys.argv[3:7])
    if len(sys.argv) >= 8:
        scale = int(sys.argv[7])
    out = bytearray()
    ow, oh = w // scale, h // scale
    for oy in range(oh):
        for ox in range(ow):
            i = ((y + oy*scale) * W + (x + ox*scale)) * 3
            out += rgb[i:i+3]
    write_png(dst, ow, oh, bytes(out))
    print(dst, ow, oh)
