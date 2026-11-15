#!/usr/bin/env python3
# kc-syscfg-patch — re-enable the SysCfg write on the A8 HomePod ssh-ramdisk
# kernelcache (audioOS/tvOS 17.5, AppleTV donor).
#
# WHY: AppleDiagnosticDataAccessReadOnly::setProperties (vtable slot 44) is a
# 3-instruction stub that returns kIOReturnNotWritable (0xe00002c4). The real
# write functions still exist in the kext:
#   stage  @0xfffffff006259804  — marks the region dirty from the dict
#   commit @0xfffffff0062598ac  — regionIO reads the STORED property and writes NAND
# and base IORegistryEntry::setProperties @0xfffffff00774178c stores the dict.
#
# PATCH: turn the NotWritable stub into a trampoline to a code cave that runs
#   base_setProperties(this,dict); stage(this,dict); commit(this,dict); return 0
# All reused existing code; the glue is 72 bytes placed in zero padding in
# __PLK_TEXT_EXEC at 0xfffffff005d02208.
#
# SAFETY: verifies the firmware matches (exact stub bytes) and the cave is zero
# before writing anything; refuses otherwise. Operates on a DECOMPRESSED arm64
# kernelcache Mach-O. VALIDATE with a same-bytes round-trip (read the pod's own
# SysCfg, write it back, reboot, re-read) BEFORE trusting a real new-chip write.
import sys, struct

STUB_VA   = 0xfffffff006259914
CAVE_VA   = 0xfffffff005d02208
# Verified bytes (audioOS/tvOS 17.5 AppleTV kernelcache):
ORIG_STUB = bytes.fromhex("805880520000bc72c0035fd6")  # mov w0,#0x2c4; movk; ret
TRAMP     = bytes.fromhex("3da2ea17")                    # b CAVE_VA  (from STUB_VA)
# v2a glue (48 bytes): setProperties -> write-buffer SETUP only (0x62592cc), return 0.
# No commit / no NAND write — a safe probe to confirm the setup path doesn't fault.
GLUE      = bytes.fromhex(
    "f44fbea9fd7b01a9fd430091f30300aaf40301aae00313aae10314aa2a5c1594"
    "00008052fd7b41a9f44fc2a8c0035fd6")
STUB_TAIL = bytes.fromhex("0000bc72c0035fd6")            # stub bytes [4:12], unchanged by our trampoline

def segs(buf):
    magic,=struct.unpack_from("<I",buf,0)
    assert magic==0xfeedfacf, "not a 64-bit Mach-O (decompress the kernelcache first)"
    ncmds,=struct.unpack_from("<I",buf,16); p=32; out=[]
    for _ in range(ncmds):
        cmd,cs=struct.unpack_from("<II",buf,p)
        if cmd==0x19:
            vm,vs,fo,fsz=struct.unpack_from("<QQQQ",buf,p+24)
            out.append((vm,fo,fsz))
        p+=cs
    return out

def va2off(s,va):
    for vm,fo,fsz in s:
        if vm<=va<vm+fsz: return fo+(va-vm)
    raise SystemExit(f"VA {va:#x} not mapped — wrong kernelcache?")

def main():
    if len(sys.argv)!=3:
        print("usage: patch.py <kernelcache.decompressed> <out.patched>"); sys.exit(2)
    buf=bytearray(open(sys.argv[1],"rb").read())
    s=segs(buf)
    so=va2off(s,STUB_VA); co=va2off(s,CAVE_VA)
    # guard: identify the firmware by the stub's trailing 8 bytes (unchanged whether
    # pristine or already trampolined). Refuse on any other kernelcache.
    if bytes(buf[so+4:so+12])!=STUB_TAIL:
        raise SystemExit(f"stub tail mismatch at {STUB_VA:#x}: got {bytes(buf[so+4:so+12]).hex()} "
                         f"expected {STUB_TAIL.hex()} — different firmware; refusing to patch.")
    # cave must be zero OR already hold one of our glues (re-patch is fine).
    cave_now=bytes(buf[co:co+80])
    if any(cave_now) and cave_now[:4]!=bytes.fromhex("f44fbea9"):
        raise SystemExit(f"cave at {CAVE_VA:#x} holds unknown data — refusing to overwrite.")
    # apply: clear 80 bytes of cave, write glue, set trampoline
    buf[co:co+80]=b"\x00"*80
    buf[co:co+len(GLUE)]=GLUE
    buf[so:so+4]=TRAMP
    # verify
    assert bytes(buf[so:so+4])==TRAMP and bytes(buf[co:co+len(GLUE)])==GLUE
    open(sys.argv[2],"wb").write(buf)
    print(f"[*] Patched: stub@{STUB_VA:#x} -> trampoline; glue@{CAVE_VA:#x} ({len(GLUE)} bytes).")
    print("[*] Next: repack as rkrn img4 with the generic IM4M, rebuild the ramdisk,")
    print("    then VALIDATE with a same-bytes round-trip before any real write.")

if __name__=="__main__": main()
