#!/usr/bin/env python3
"""extract_apac.py CACHE_DIR OUT -- cut Apple's AudioCodecs library out of an audioOS root filesystem.

Nicotine decodes Dolby Atmos (Apple's APAC format) with the decoder audioOS itself uses. That decoder is
Apple's and is not in this repository: this script takes it from the audioOS 18.3 root filesystem the build
already has mounted (the IPSW the user downloaded), and writes it as one file for /usr/libexec/apacdec, which
loads it at its original addresses and supplies the few system functions it calls.

CACHE_DIR is <rootfs>/System/Library/Caches/com.apple.dyld (the "dyld shared cache": every system library,
already linked together, split over about 30 files, plus a .symbols file with the local names).
Python standard library only. Takes about a minute and reads about 1 GB.

Output (little endian):
  magic "NICAPAC1"
  u32 nseg, nimport, nfix, nisland, nentry
  nseg    x { u64 vmaddr; u64 size; u32 prot; u32 fileoff }    bytes to place at their original address
  nimport x { u32 name_off }                                   outside symbols, by index
  nfix    x { u64 addr; u32 import; s32 addend }               8-byte slots to fill with &import + addend
  nisland x { u64 addr; u32 import; u32 pad }                  addresses the code branches to directly
  nentry  x { u64 addr; u32 name_off; u32 pad }                functions inside the library called by name
  u32 strings size, string table, then the segment bytes
"""
import bisect, collections, glob, hashlib, mmap, os, struct, sys


class Cache:
    """an arm64 (not arm64e) dyld shared cache split over sub-files"""
    def __init__(self, d):
        self.maps = []          # (vmaddr, size, mmap, fileoff)
        self.files = {}
        self.symbols = None
        for p in sorted(glob.glob(os.path.join(d, "dyld_shared_cache_arm64*"))):
            if not os.path.isfile(p) or os.path.getsize(p) < 0x200:
                continue
            f = open(p, "rb"); m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
            if m[:7] != b"dyld_v1":
                continue
            if p.endswith(".symbols"):
                self.symbols = m
                continue
            self.files[os.path.basename(p)] = m
            mo, mc = struct.unpack_from("<II", m, 16)
            for i in range(mc):
                a, sz, fo, _, _ = struct.unpack_from("<QQQII", m, mo + 32 * i)
                self.maps.append((a, sz, m, fo))
        if "dyld_shared_cache_arm64" not in self.files:
            raise SystemExit("no dyld_shared_cache_arm64 in %s" % d)
        self.maps.sort(key=lambda x: x[0])
        self._ma = [x[0] for x in self.maps]
        main = self.files["dyld_shared_cache_arm64"]
        io, ic = struct.unpack_from("<II", main, 0x1C0)
        self.images = []
        for i in range(ic):
            a, _, _, po, _ = struct.unpack_from("<QQQII", main, io + 32 * i)
            self.images.append((a, main[po:main.find(b"\0", po)].decode()))
        self.images.sort()
        self.linkedit = None
        for name, m in self.files.items():
            if "linkedit" in name:
                self.linkedit = m
        # local symbols (.symbols file): image address -> (first nlist, count)
        self.local = {}
        S = self.symbols
        if S is not None:
            lo = struct.unpack_from("<Q", S, 0x48)[0]
            self.s_lo = lo
            self.s_nlo, _, self.s_so, _, eo, ec = struct.unpack_from("<IIIIII", S, lo)
            base = self.maps[0][0]
            for i in range(ec):
                off, st, cnt = struct.unpack_from("<QII", S, lo + eo + 16 * i)
                self.local[base + off] = (st, cnt)

    def where(self, vm):
        i = bisect.bisect_right(self._ma, vm) - 1
        if i >= 0:
            a, sz, m, fo = self.maps[i]
            if vm < a + sz:
                return m, fo + (vm - a)
        return None

    def read(self, vm, n):
        w = self.where(vm)
        if not w:
            raise KeyError(hex(vm))
        return w[0][w[1]:w[1] + n]

    def u32(self, vm):
        return struct.unpack("<I", self.read(vm, 4))[0]

    def image(self, suffix):
        for a, p in self.images:
            if p.endswith(suffix):
                return a, p
        raise SystemExit("no %s in this cache" % suffix)


class MachO:
    def __init__(self, c, base):
        self.c, self.base = c, base
        magic, _, _, _, ncmds, _, _, _ = struct.unpack("<IiiIIIII", c.read(base, 32))
        if magic != 0xfeedfacf:
            raise ValueError("not a Mach-O at %#x" % base)
        p = base + 32; self.segs = {}; self.sects = {}; self.symtab = self.dysym = None
        for _ in range(ncmds):
            cmd, csz = struct.unpack("<II", c.read(p, 8)); b = c.read(p, csz)
            if cmd == 0x19:
                name = b[8:24].rstrip(b"\0").decode()
                vmaddr, vmsize, fileoff, filesize, _, _, nsects, _ = struct.unpack_from("<QQQQiiII", b, 24)
                self.segs[name] = (vmaddr, vmsize, fileoff, filesize)
                for s in range(nsects):
                    q = 72 + 80 * s
                    sn = b[q:q + 16].rstrip(b"\0").decode(); sg = b[q + 16:q + 32].rstrip(b"\0").decode()
                    addr, size = struct.unpack_from("<QQ", b, q + 32)
                    self.sects[(sg, sn)] = (addr, size)
            elif cmd == 0x2:
                self.symtab = struct.unpack_from("<IIII", b, 8)
            elif cmd == 0xB:
                self.dysym = struct.unpack_from("<18I", b, 8)
            p += csz

    def nlist(self, i):
        le = self.c.linkedit
        symoff, nsyms, stroff, strsize = self.symtab
        strx, typ, sect, desc, val = struct.unpack_from("<IBBHQ", le, symoff + 16 * i)
        return le[stroff + strx:le.find(b"\0", stroff + strx)].decode("ascii", "replace"), val

    def symbols(self):
        """address -> name: the exported names first, then the local ones"""
        d = {}
        dy = self.dysym
        for i in range(dy[2], dy[2] + dy[3]):
            n, val = self.nlist(i)
            if val:
                d.setdefault(val, n)
        c = self.c
        if self.base in c.local:
            S = c.symbols; st, cnt = c.local[self.base]
            for k in range(st, st + cnt):
                strx, typ, sect, desc, val = struct.unpack_from("<IBBHQ", S, c.s_lo + c.s_nlo + 16 * k)
                o = c.s_lo + c.s_so + strx
                d.setdefault(val, S[o:S.find(b"\0", o)].decode("ascii", "replace"))
        return d


class Namer:
    """names for addresses anywhere in the cache"""
    def __init__(self, c):
        self.c = c; self._syms = {}; self._segmap = None

    def syms(self, img):
        if img not in self._syms:
            self._syms[img] = MachO(self.c, img).symbols()
        return self._syms[img]

    def owner(self, addr):
        if self._segmap is None:
            sm = []
            for a, p in self.c.images:
                try:
                    mo = MachO(self.c, a)
                except Exception:
                    continue
                for n, s in mo.segs.items():
                    if n != "__LINKEDIT" and s[1]:
                        sm.append((s[0], s[0] + s[1], a, p))
            sm.sort(); self._segmap = sm
        sm = self._segmap
        i = bisect.bisect_right(sm, (addr, 1 << 62, 0, "")) - 1
        for j in range(i, max(-1, i - 4), -1):
            lo, hi, a, p = sm[j]
            if lo <= addr < hi:
                return a, p
        return None

    def name(self, addr):
        """(name or None, addend): an address, or one up to 64 bytes into a named object (vtable + 16, say)"""
        o = self.owner(addr)
        if not o:
            return None, 0
        d = self.syms(o[0])
        if addr in d:
            return d[addr], 0
        best = max((a for a in d if a <= addr and addr - a <= 64), default=None)
        if best is not None:
            return d[best], addr - best
        return None, 0


def adrp_target(a, w):
    imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
    if imm & (1 << 20):
        imm -= 1 << 21
    return (a & ~0xFFF) + (imm << 12)


def extract(cache_dir, out):
    c = Cache(cache_dir)
    if c.symbols is None:
        raise SystemExit("dyld_shared_cache_arm64.symbols is missing in %s" % cache_dir)
    base, path = c.image("/AudioCodecs")
    m = MachO(c, base)
    nm = Namer(c)
    segs = [(n, s) for n, s in m.segs.items() if n != "__LINKEDIT"]

    def inside(a):
        return any(s[0] <= a < s[0] + s[1] for _, s in segs)

    # ---- which words of the data files are pointers, and their real values (slide info, version 2)
    slides = []
    for fname, dd in c.files.items():
        if struct.unpack_from("<I", dd, 16)[0] < 0x140:
            continue
        mwo, mwc = struct.unpack_from("<II", dd, 0x138)
        for i in range(mwc):
            a, sz, fo, sio, sis, fl, mp, ip = struct.unpack_from("<QQQQQQII", dd, mwo + 56 * i)
            if sis:
                slides.append((a, sz, fo, sio, dd))

    def pointer_at(addr):
        """the 8 bytes at addr as a pointer (a slot in a region with slide info holds value | chain bits)"""
        raw = struct.unpack("<Q", c.read(addr, 8))[0]
        for a, sz, fo, sio, dd in slides:
            if a <= addr < a + sz:
                ver, psz, pso, psc, peo, pec, dmask, vadd = struct.unpack_from("<IIIIIIQQ", dd, sio)
                v = raw & ~dmask
                return v + vadd if v else 0
        return raw

    def pointers_in(lo, hi):
        """(address, value) of every pointer the slide info lists in [lo, hi)"""
        for a, sz, fo, sio, dd in slides:
            if hi <= a or lo >= a + sz:
                continue
            ver, psz, pso, psc, peo, pec, dmask, vadd = struct.unpack_from("<IIIIIIQQ", dd, sio)
            if ver != 2:
                raise SystemExit("slide info version %d: this is not the cache this script was written for" % ver)
            shift = (dmask & -dmask).bit_length() - 1 - 2
            first = max(0, (lo - a) // psz); last = min(psc - 1, (hi - 1 - a) // psz)
            for pg in range(first, last + 1):
                st = struct.unpack_from("<H", dd, sio + pso + 2 * pg)[0]
                if st == 0x4000:
                    continue
                starts = []
                if st & 0x8000:
                    k = st & 0x3FFF
                    while True:
                        e = struct.unpack_from("<H", dd, sio + peo + 2 * k)[0]; starts.append(e & 0x3FFF); k += 1
                        if e & 0x8000:
                            break
                else:
                    starts.append(st)
                for s in starts:
                    off = s * 4
                    while True:
                        addr = a + pg * psz + off
                        raw = struct.unpack_from("<Q", dd, fo + pg * psz + off)[0]
                        delta = (raw & dmask) >> shift
                        v = raw & ~dmask
                        if v:
                            v += vadd
                        if lo <= addr < hi:
                            yield addr, v
                        if not delta:
                            break
                        off += delta

    imports = {}; strings = bytearray(b"\0"); stroff = {}

    def S(s):
        if s not in stroff:
            stroff[s] = len(strings); strings.extend(s.encode() + b"\0")
        return stroff[s]

    def imp(n):
        if n not in imports:
            imports[n] = len(imports)
        return imports[n]

    fixes = []; images = {}; unnamed = 0
    # ---- the library's own data: copy the bytes, turn stored pointers into real ones
    PROT = {"__TEXT": 5, "__DATA_CONST": 3, "__DATA": 3, "__DATA_DIRTY": 3}
    for n, (va, sz, fo, fs) in segs:
        if n not in PROT:
            raise SystemExit("unexpected segment %s" % n)
        b = bytearray(c.read(va, sz))
        if n != "__TEXT":
            for addr, v in pointers_in(va, va + sz):
                if inside(v) or v == 0:
                    struct.pack_into("<Q", b, addr - va, v)
                elif inside(v & 0x7FFFFFFFFFFFFFFF):          # a type-name pointer with Apple's "not unique" flag
                    struct.pack_into("<Q", b, addr - va, v & 0x7FFFFFFFFFFFFFFF)
                else:
                    name, add = nm.name(v)
                    if name:
                        fixes.append((addr, imp(name), add))
                    else:
                        unnamed += 1
                    struct.pack_into("<Q", b, addr - va, 0)
        images[n] = (va, bytes(b))

    # ---- the code: pointer slots it loads from (adrp + ldr) and branches that leave the library
    slots = collections.OrderedDict(); branches = collections.OrderedDict()
    for sect in ("__text", "__stubs"):                                    # a stub is adrp x16 ; ldr x16 ; br x16
      ta, ts = m.sects[("__TEXT", sect)]
      code = struct.unpack("<%dI" % (ts // 4), c.read(ta, ts // 4 * 4))
      for i, w in enumerate(code):
        if (w & 0x9F000000) == 0x90000000 and i + 1 < len(code):          # adrp xN, page ; ldr xM, [xN, #off]
            w2 = code[i + 1]
            if (w2 & 0xFFC00000) == 0xF9400000 and ((w2 >> 5) & 31) == (w & 31):
                t = adrp_target(ta + 4 * i, w) + ((w2 >> 10) & 0xFFF) * 8
                if not inside(t):
                    slots[t] = 1
        elif (w & 0x7C000000) == 0x14000000 and sect == "__text":         # b / bl
            imm = w & 0x3FFFFFF
            if imm & (1 << 25):
                imm -= 1 << 26
            t = ta + 4 * i + imm * 4
            if not inside(t):
                branches[t] = 1
    got = {}
    for slot in slots:
        p = pointer_at(slot)
        name, add = nm.name(p)
        if name:
            got[slot] = (name, p, add)
    ga, gs = m.sects[("__DATA_CONST", "__got")]
    for slot in range(ga, ga + gs, 8):
        p = pointer_at(slot)
        if p and not inside(p):
            name, add = nm.name(p)
            if name:
                got[slot] = (name, p, add)
    for slot, (name, p, add) in got.items():
        if ga <= slot < ga + gs:
            continue                                        # the library's own table: done with its data above
        fixes.append((slot, imp(name), add))
    done = set(f[0] for f in fixes)
    for slot, (name, p, add) in got.items():                # ... except slots the slide info does not list
        if ga <= slot < ga + gs and slot not in done and not inside(p):
            fixes.append((slot, imp(name), add))

    islands = []
    for t in sorted(branches):
        w = [c.u32(t + 4 * k) for k in range(3)]
        final = t
        if (w[0] & 0x9F00001F) == 0x90000010 and (w[1] & 0xFFC003FF) == 0x91000210 and w[2] == 0xD61F0200:
            final = adrp_target(t, w[0]) + ((w[1] >> 10) & 0xFFF)          # a stub: adrp x16 ; add x16 ; br x16
        o = nm.owner(final)
        name = nm.syms(o[0]).get(final) if o else None
        if name:
            islands.append((t, imp(name)))

    # ---- functions called by name
    syms = m.symbols()
    entries = [(a, n) for a, n in sorted(syms.items()) if n and (n == "_RegisterExternalAudioCodecs" or "APAC" in n and "Decoder" in n)]
    entries.append((m.nlist(m.dysym[2])[1], m.nlist(m.dysym[2])[0]))
    entries = sorted(set(entries))

    segrec = []; blob = bytearray()
    for n, (va, b) in images.items():
        segrec.append((va, len(b), PROT[n], len(blob))); blob += b
    names = sorted(imports, key=imports.get)
    hdr = b"NICAPAC1" + struct.pack("<5I", len(segrec), len(names), len(fixes), len(islands), len(entries))
    body = b"".join(struct.pack("<QQII", *s) for s in segrec)
    body += b"".join(struct.pack("<I", S(n)) for n in names)
    body += b"".join(struct.pack("<QIi", a, i, add) for a, i, add in sorted(fixes))
    body += b"".join(struct.pack("<QII", a, i, 0) for a, i in islands)
    body += b"".join(struct.pack("<QII", a, S(n), 0) for a, n in entries)
    data = hdr + body + struct.pack("<I", len(strings)) + bytes(strings) + bytes(blob)
    with open(out, "wb") as f:
        f.write(data)
    print("    %s: %d segments, %d outside symbols, %d pointers, %d branch targets, %d entries, %.1f MB" % (
        path, len(segrec), len(names), len(fixes), len(islands), len(entries), len(data) / 1e6))
    if unnamed:
        print("    (%d pointers to outside objects without a name were left empty)" % unnamed)
    return hashlib.sha256(data).hexdigest()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(2)
    print(extract(sys.argv[1], sys.argv[2]))
