# Sources written or changed for Nicotine

The Nicotine root filesystem (`../rootfs-skeleton.tar.gz`) holds compiled programs. Most are stock
builds of other projects. What was written for Nicotine, or changed, is here or inside the skeleton:

| Program in the skeleton | Source |
|---|---|
| `/opt/audio/hpfeed` (the speaker program) | `/opt/audio/hpfeed.c` and the `hp*.h`, `apple_b238a*.h`, `meter2.h` headers next to it, in the skeleton |
| `/usr/libexec/hpmix` (mixer for other AirPlay speakers) | `/opt/audio/hpmix.c` in the skeleton |
| `/usr/libexec/apacdec` (runs Apple's Atmos decoder) | `apacdec/` here |
| `/usr/bin/shairport-sync` (AirPlay receiver) | shairport-sync 5.6.3 with `shairport-sync-5.6.3-nicotine.patch` here |
| `homepod-*` in `/usr/sbin`, the web UI in `/www` | scripts, readable in the skeleton |

All are static aarch64 binaries, built on Linux with `aarch64-linux-gnu-gcc` 13:

    # hpfeed, hpmix (in /opt/audio of the unpacked skeleton)
    aarch64-linux-gnu-gcc -O2 -static -Wall -Wextra -pthread -o hpfeed hpfeed.c -lm
    aarch64-linux-gnu-gcc -O2 -static -Wall -Wextra -o hpmix hpmix.c -lm
    # apacdec
    cd apacdec && aarch64-linux-gnu-gcc -O2 -g -static -fno-omit-frame-pointer -o apacdec apacdec.c codec.c loader.c \
        shims_base.c shims_cxx.c shims_cf.c shims_atc.c shims_vdsp.c shims_str.c afmt.c -lm -lsupc++

## apacdec

Apple's AudioCodecs library is not here and not in the skeleton; the build takes it from the user's
audioOS IPSW (`../tools/extract_apac.py`, which writes `apac.img`). `apacdec` is everything around it:

- `loader.c` places the library's segments at their original addresses, fills its pointer slots and
  branch targets with the functions below, and finds its entry points by name.
- `shims_*.c` are those functions: the C library and C++ runtime the library expects (with Apple's
  layout of `std::string` and of exceptions), a small CoreFoundation, the vDSP routines it uses, and
  the channel-layout lookups (`afmt.c`; `afmt_layouts.h` is the table of standard layouts, tag to
  channel labels).
- `codec.c` talks to the codec the way AudioToolbox does (the component's selector table).
- `apacdec.c` is the helper process shairport-sync starts: packets in on stdin, 32-bit float PCM out
  on stdout. It first runs the library's own encoder once to get the configuration block the
  decoder wants.

It was written against the AudioCodecs of audioOS 18.3 and supplies what that version calls; the
build therefore only uses a library with the checksum in `../audio-manifest.txt`.

## shairport-sync patch

Against the 5.6.3 tag. It adds: the `model` setting; TXT records and the second service in the
built-in mDNS responder; the control pipe (`homepod_control.c`); classic AirPlay streams announced
as plain PCM; the format list a HomePod advertises, so that senders offer Atmos; APAC streams
decoded by the `apacdec` helper into the 5.1.2 layout; and a note of the stream's kind
(`/run/homepod/airplay.format`) for the room relay. Configure line and libraries: static build
with OpenSSL, avahi, libplist, a minimal FFmpeg (AAC, ALAC, PCM decoders, swresample), nqptp 1.2.9
alongside.
