#!/usr/bin/env python3
"""extract_xtc.py ROOTFS OUT -- the HomePod's virtual-surround filters, from an audioOS root filesystem.

audioOS plays the surround and height channels of 5.1 and Atmos sound through pairs of short filters (crosstalk
cancellation, AUSpatialMixer with built-in speaker output). The filters are Apple's tuning data and are not in
this repository: this script reads them from the audioOS root filesystem the build has mounted and writes them
as one small file for hpfeed (/usr/lib/nicotine/xtc.bin). Without the file hpfeed still plays those channels,
unfiltered. Python standard library only.

In:  ROOTFS/System/Library/Audio/Tunings/IRs/B238a/b238a_XTCIR_default_5.ir   one speaker
                                                   b238a_XTCIR_default_20.ir  a member of a stereo pair
     (u32 length, a property list, then one record per direction: elevation f32, azimuth f32, one delay f32
     per channel, FilterLength x int16 per channel, to be multiplied by FilterScaleFactor)
Out: "NICXTC1\\0", u32 taps (128), then float32 [set][input][output][tap]: set 0 one speaker, 1 pair member;
     input SL, SR, HL, HR; output left, right.
"""
import hashlib, os, plistlib, struct, sys

TAPS = 128
# (elevation, azimuth) of the four inputs, as the rendering graph places them
WANT = ((0.0, 250.0), (0.0, 110.0), (30.0, 330.0), (30.0, 30.0))


def load(path):
    d = open(path, "rb").read()
    hl = struct.unpack_from("<I", d, 0)[0]
    p = plistlib.loads(d[4:4 + hl]); r = d[4 + hl:]
    n, length, ch = p["TotalNumCoordinates"], p["FilterLength"], p["NumChannels"]
    if length != TAPS or ch != 2:
        raise SystemExit("%s: %d taps, %d channels: not the filters this script was written for" % (path, length, ch))
    rec = len(r) // n; scale = p["FilterScaleFactor"]
    out = {}
    for i in range(n):
        b = r[i * rec:(i + 1) * rec]
        el, az = struct.unpack_from("<ff", b, 0)
        taps = struct.unpack_from("<%dh" % (ch * length), b, 8 + 4 * ch)
        out[(round(el, 1), round(az, 1))] = [[taps[c * length + k] * scale for k in range(length)] for c in range(ch)]
    return out


def extract(rootfs, out):
    d = os.path.join(rootfs, "System/Library/Audio/Tunings/IRs/B238a")
    data = b"NICXTC1\0" + struct.pack("<I", TAPS)
    for name in ("b238a_XTCIR_default_5.ir", "b238a_XTCIR_default_20.ir"):
        recs = load(os.path.join(d, name))
        for key in WANT:
            if key not in recs:
                raise SystemExit("%s has no filter for elevation %g, azimuth %g" % (name, key[0], key[1]))
            for c in range(2):
                data += struct.pack("<%df" % TAPS, *recs[key][c])
    with open(out, "wb") as f:
        f.write(data)
    return hashlib.sha256(data).hexdigest()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(2)
    print(extract(sys.argv[1], sys.argv[2]))
