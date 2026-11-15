# HomePod (AudioAccessory1,1 / A8) NAND map — observed from the SSH ramdisk

Observed on a live pod (ECID …6a6f26) over the d235j homepod ssh-ramdisk.
Read raw devices with `dd bs=1m` (512-byte reads return nothing — needs large
aligned blocks).

| device      | size (observed)      | contents |
|-------------|----------------------|----------|
| disk0 / disk0s1 | large (GB)       | main storage, **APFS, encrypted** (high-entropy; tag matches are coincidental noise) |
| disk1 s1–s5 | TBD                  | not yet dumped — next SysCfg candidate |
| disk2       | 4 MB                 | **firmware / LLB+iBoot** — contains `Util_Find_SysCfg`, `Find_Fast_Scan` strings (the SysCfg scanner), BNCH/BORD boot nonce |
| disk3       | ~1 MB                | **panic log** (david used `dd if=/dev/disk3` in 2024) |
| disk4       | 0 bytes via bs=1m    | special/unreadable with 1 MB reads — revisit with other block sizes |

## SysCfg status — READ CONFIRMED
- **Read path proven.** SysCfg is exposed live via the IORegistry property
  `AppleDiagnosticDataSysCfg` on `AppleDiagnosticDataAccessReadOnly`
  (`ioreg -r -c AppleDiagnosticDataAccessReadOnly -l`). The real capture is
  131072 bytes, signature `gfCS`. The app's reversed-key parser carves it to:
  Serial CC4VKKTQHQK8, Wi-Fi d0:81:7a:e3:76:94, BT …:95, Eth …:96,
  Model MQHW2, Region LL/A, RModel A1639 — validated against the on-device dump.
- Write path: plumbing is **ready and safe** (write → read back → byte-compare,
  refuse on mismatch), but **gated** — it refuses until the on-device *sink* (how
  the ramdisk writes SysCfg back to NAND) is validated. The read-only write-probe
  (bundled into Pull diagnostics; `SSHRamdiskTransport.writeProbeCommand`)
  enumerates candidates (`AppleNANDConfigAccess` node, CLIs) so the sink can be
  pinned without guessing. Candidate: symmetric to the read via `AppleNANDConfigAccess`.
- SysCfg is NOT a plaintext block in disk0/disk0s1/disk2/disk3.
- disk2's LLB has `Util_Find_SysCfg` + `Fast Copy B` / wear-leveled scan code →
  SysCfg lives in a reserved, wear-leveled zone the firmware scans for, not a
  fixed offset. This is the "semi-hidden nand partition" tihmstar described.
- Container magic in code is `SysCfg` (forward). Reviv expects reversed `gfCS`
  for the data block — not yet located on this device.
- Next: dump disk1 s1–s5.

## Diagnostics feature — IMPLEMENTED
Read-only "Pull diagnostics (panic log)" in the Check-health menu:
boot ssh-ramdisk → `dd if=/dev/rdisk3 bs=1m` (panic log) + `ioreg -l` snapshot →
save to a folder the tech picks (paniclog.bin, ioreg.txt, notes.txt). No writes,
no brick risk. Shares the booter with SysCfg read (DiagnosticsController).

## SSH-ramdisk boot modes (app)
The SysCfg + diagnostics flows pick a RamdiskBooter by `syscfgBootMode`:
- **preBooted** — tech booted the pod via SSHRD; app connects + auto-forwards
  iproxy. Works today.
- **sshrd** — app drives the proven d235j boot sequence natively
  (gaster pwn/reset → irecovery -f iBSS/iBEC/logo/ramdisk/devicetree/trustcache/
  kernelcache → bootx) from a built SSHRD `sshramdisk/` (SSHRDLayout, default
  `~/SSHRD_Script`). The "no terminal" goal; needs the ramdisk built once.
- **legacy** — old in-app gaster+ra1nsn0w path; kept only as a fallback.
