# Verifies a PNG written by src/png.lua: chunk CRCs, zlib stream, and pixel bytes.
import struct, sys, zlib
d = open(sys.argv[1], 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n'
p, chunks = 8, []
while p < len(d):
    n, = struct.unpack('>I', d[p:p+4]); kind = d[p+4:p+8]; body = d[p+8:p+8+n]
    crc, = struct.unpack('>I', d[p+8+n:p+12+n]); assert zlib.crc32(kind + body) == crc, kind
    chunks.append((kind, body)); p += 12 + n
w, h, depth, ctype = struct.unpack('>IIBB', chunks[0][1][:10]); assert (depth, ctype) == (8, 6)
raw = zlib.decompress(b''.join(b for k, b in chunks if k == b'IDAT'))
assert len(raw) == h * (1 + 4 * w)
print('png ok', w, h, list(raw[1:13]))
