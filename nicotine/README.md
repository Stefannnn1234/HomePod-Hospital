# Nicotine payload build kit

Everything needed to build a bootable **Nicotine** payload for the 1st-gen HomePod from source.
You normally do not run anything here yourself: `./scripts/build-app.sh` builds a payload with
this kit and puts it inside the app. To build one by hand, from the repository root (macOS,
`python3` only, no pip packages):

    bash nicotine/payload-from-ipsw.sh ~/Downloads/18.3.ipsw ~/nicotine-payload

or, from parts you already have:

    # an unpacked audioOS root filesystem + the IPSW's DeviceTree.b238aap.im4p
    nicotine/build-payload.sh --rootfs <audioOS-rootfs> --devicetree-im4p <DeviceTree.b238aap.im4p> --out <payload-dir>
    # a ready lib/firmware/brcm folder + a raw device tree
    nicotine/build-payload.sh --firmware <brcm-dir> --adt <DeviceTree.bin> --out <payload-dir>

The result can be bundled (`NICOTINE_PAYLOAD_DIR=<payload-dir> ./scripts/build-app.sh`) or
imported in the app (**Import Nicotine payload…**, the folder or a zip of it).
`payload-from-ipsw.sh` and the `--rootfs` form fetch the 11.2.5 WiFi firmware described below;
with `--firmware` you supply the folder yourself.

## What a payload is

    MANIFEST                                 "nicotine-payload 1", then a SHA-256 for every file
    homepod-config.sh                        save / restore a pod's settings from the Mac
    img4/RestoreKernelCache_m1n1-linux.img4  m1n1 + boot arguments + HomePod DTB + kernel + initramfs
    img4/RestoreDeviceTree_b238aap.img4      Apple's B238a device tree
    img4/RestoreTrustCache.img4              an empty trust cache

The boot loaders (iBSS/iBEC) are not part of the payload. The app builds them from Apple's release
audioOS 16.4 files on first use (see `docs/nicotine-boot.md`).

## What's in this kit (all redistributable)

- `prebuilt/` — `Image.gz` (Linux kernel, GPL), `m1n1-idevice.macho` + `monitor-stub.macho`
  (m1n1, MIT), `t7000-b238a.dtb` (and a minimal variant), the empty trust cache, `devnodes.cpio` (see below) and
  `0x7000.im4m`, the generic A8 ticket every IMG4 is wrapped with. The app build also copies that
  ticket into the app as `nicotine-0x7000.im4m` for the boot-loader builder.
- `kernel/` — the sources for the prebuilt kernel, device tree and m1n1: patches against
  HoolockLinux's trees, the kernel config and `build.sh` (Linux host). The binaries are committed
  because the app is built on macOS, which cannot build the kernel. See `kernel/README.md`.
- `rootfs-skeleton.tar.gz` — the Nicotine root filesystem, without the Broadcom firmware, without
  Apple's two audio parts (below) and with no WiFi network in it. The sources of most compiled
  programs in it (BusyBox, dropbear, BlueZ and others) are not in this repository yet; the scripts
  and web UI are readable inside the tarball, the audio programs' sources are in its `/opt/audio`
  (`hpfeed.c`, `hpmix.c` and their headers), and `src/` here has what was written or changed for
  Nicotine: the Atmos decoder's loader (`src/apacdec/`) and the patch for shairport-sync 5.6.3.
  `/usr/lib/nicotine/pysite` in the skeleton is pyatv 0.16.1 with its dependencies, unmodified wheels
  from PyPI for Python 3.14 on musl/aarch64 (MIT, BSD and Apache licences), used to play a room on
  other AirPlay speakers.
- `payload-from-ipsw.sh` — the whole build from one 18.3 IPSW (what `build-app.sh` runs).
- `build-payload.sh` — assembles the payload from the kit plus firmware and device tree.
- `tools/pack.py` — IMG4 packer and `--unwrap`, Python standard library only.
- `tools/extract_wifi.py`, `tools/fetch_launch_wifi.py`, `firmware-manifest.txt` — the firmware
  steps below. `firmware-manifest.txt` lists the `lib/firmware/brcm/*` names and the checksums
  of the validated WiFi files.
- `tools/audio_parts.py`, `tools/extract_apac.py`, `tools/extract_xtc.py`, `audio-manifest.txt` —
  the two audio parts below, and the checksums of the ones Nicotine was tested with.

## Where the Apple parts come from

Nothing Apple-made is stored in this repository. At build time:

- **Device tree**: `DeviceTree.b238aap.im4p` from the 18.3 IPSW. It is LZFSE-compressed;
  `tools/pack.py --unwrap` unwraps and decompresses it (with macOS's own libcompression).
- **Bluetooth patch**: carved out of `/usr/sbin/BlueTool` in the 18.3 root filesystem, which
  embeds it. 18.3 has no separate Bluetooth firmware files. If it is not found, Bluetooth is off
  and everything else still works.
- **WiFi firmware**: version 13.45.26, from Apple's own audioOS 11.2.5 (build 15D59) update.
  `tools/fetch_launch_wifi.py` downloads only the block of that update that holds the WiFi files
  (one HTTP range request, about 7 MB) and checks the files against pinned checksums. The WiFi
  driver was brought up against this version; the newer firmware in 18.3 does not start with it.
  The calibration file gets two lines of our own appended (`msglevel` and a placeholder MAC
  address that is replaced from the pod at run time). If the download fails, the build falls back
  to 18.3's firmware and warns that WiFi will not work.

- **Dolby Atmos decoder**: Apple Music sends Atmos to a HomePod in Apple's own format (APAC), and
  the only decoder for it is Apple's. `tools/extract_apac.py` cuts the library that holds it
  (AudioCodecs) out of the 18.3 root filesystem's system-library cache and writes it as
  `/usr/lib/nicotine/apac.img`. On the pod, `/usr/libexec/apacdec` loads that file at its original
  addresses and supplies the system functions it calls; shairport-sync hands it the Atmos packets.
  The file is used only if it is byte-identical to the tested one (`audio-manifest.txt`). Without
  it the pod does not offer Atmos to senders and plays everything else as before.
- **Virtual-surround filters**: the short filters audioOS plays surround and height channels
  through on a HomePod, from `System/Library/Audio/Tunings/IRs/B238a` in the same root filesystem
  (`tools/extract_xtc.py`, `/usr/lib/nicotine/xtc.bin`). Without them those channels are played
  unfiltered.

Whether you may use Apple's decoder this way, and Dolby's format with it, is a licensing question
this project cannot answer for you; nothing of either is distributed here.

The build log says which you got: `[+] WiFi firmware and calibration are byte-identical to the
validated Nicotine build`, `[+] Atmos decoder: identical to the one Nicotine was tested with` and
`[+] Surround filters: identical to the ones Nicotine was tested with` are the good lines.

## How the image is put together

1. The root filesystem skeleton is unpacked, the firmware is added under `lib/firmware/brcm` and
   the two audio parts under `usr/lib/nicotine`.
2. The initramfs is built. The skeleton has no device nodes, because a normal user on macOS cannot
   create them. `/dev/null` and `/dev/console` come from `prebuilt/devnodes.cpio`, whose entries
   are put in front of the root filesystem's, so the result is one cpio archive in one gzip stream.
   m1n1 accepts nothing else.
3. m1n1, a `chosen.bootargs=` line, the DTB, the kernel and the initramfs are joined in that order
   and wrapped as `rkrn`, with the monitor stub after it. The device tree becomes `rdtr`, the trust
   cache `rtsc`. All three carry `prebuilt/0x7000.im4m`.
4. `homepod-config.sh` is copied and the `MANIFEST` is written.

## Boot sound (build 111)

Nicotine can play a sound once it has started. It is **off by default**; switch it on in the web
UI (Overview tab, "Boot sound" card) or with `homepod-audio bootsound on`.

- The built-in sound is `/usr/share/nicotine/bootsound.wav` in the skeleton (source:
  `sounds/nicoboot.mp3` here). The web UI's "Use my own sound..." takes any audio file the browser
  can play, converts it to 48 kHz 16-bit stereo WAV (20 seconds at most) and stores it on the pod
  as `/etc/homepod-bootsound.wav`. Nothing on the pod decodes MP3.
- **When it plays:** the pod forgets its settings at a power cut, this switch included. So the
  sound plays when the saved settings are put back after a boot (`homepod-config import --apply`,
  which HomePod Hospital does), not at power-on. It plays once per boot, at the speaker's volume,
  and is skipped if something is already playing.
- To hear it right after the speakers come up instead, build the payload with
  `homepod.bootsound` added to `BOOTARGS` (see `build-payload.sh`); that plays the built-in sound
  on every boot regardless of the switch.
- The user's own sound travels in the settings backup, which grows by up to 3.8 MB. A Nicotine
  build before 111 refuses a backup that contains one.
- Commands: `homepod-audio bootsound [status|on|off|play|install FILE|reset]`. The player is
  `/usr/libexec/homepod-chime`; it feeds `hpfeed` through a third input, `/run/homepod/chime.pcm`.

## Sound Glow and equalizer additions (build 114)

Contributed by Stefan (pull request #2). All of it is off or unchanged until you choose it:

- **Sound Glow**: your own colors (one to twelve; more than three take turns), four more
  animations besides the original drifting blobs (pulse, level meter ring, bass / mid / treble
  rings, sparkle), and always-on effects that run without music (solid, breathing, rainbow, comet,
  fire, twinkle, aurora wave, heartbeat). A switch turns the + and - symbol lights off; touch keeps
  working. Commands: `homepod-glow color|mode|effect|lights`; settings `GLOW_COLOR`, `GLOW_MODE`,
  `GLOW_EFFECT`, `TOUCH_LIGHTS` in `/etc/homepod-glow.conf`. Defaults: blobs, no effect, lights on.
- **Equalizer**: eleven more presets (rock, pop, hip-hop, electronic, jazz, classical, acoustic,
  speech, warm, bright, loudness smile).
- **Live tab**: click a tweeter on the ring, or the middle for the woofer, to hear only that driver
  for 5 seconds (the others are turned down, then put back). The Speaker tab's Identify buttons
  work as before: that tweeter alone among the seven for 2 seconds, the woofer still playing.
- The web UI and comments use American spelling (equalizer, color, center).

## Surround and Dolby Atmos (build 113)

- The AirPlay receiver (shairport-sync 5.6.3 with `src/shairport-sync-5.6.3-nicotine.patch`) asks
  senders for what a HomePod asks for, so Apple Music sends Atmos (5.1.2 or 7.1.4) and the Atmos
  badge shows. Everything is handed to the speaker program as one 8-channel layout: front left and
  right, centre, LFE, surround left and right, height left and right. 7.1.4 is folded into that.
- `hpfeed` renders it the way audioOS's own tuning files describe: front, centre and LFE on the
  forward beam, surround and height through the virtual-surround filters onto the ambient beams,
  by placement (free, near a wall, on a shelf) and by whether the pod is half of a pair.
- An AirPlay configuration from a settings backup made with an older build is brought up to the
  8-channel hand-over when the receiver starts. The other way round does not work: a backup made
  with build 113 makes an older build play noise.

## Rooms: several HomePods as one AirPlay speaker (build 113)

Set up on the web UI's Speaker tab ("Room" card). The programs are `homepod-roomd`,
`homepod-roomcast`, `homepod-roomsend` and `room.cgi` in the skeleton.

- Every pod runs `homepod-roomd`. It finds the other Nicotine pods by a WiFi broadcast (UDP 9320),
  so the card lists them by name; "Identify" plays a tone on the chosen one.
- A room is one entry in the AirPlay list, under the room's name; its pods no longer show up on
  their own. One pod (the leader) keeps the AirPlay receiver. It stamps every block of the decoded
  8-channel sound with the moment it is due on its own clock and sends it to the others
  (`homepod-roomcast`, TCP 9322; the clocks are compared over UDP 9323). Every pod, the leader
  included, plays the block at that moment, and follows the leader's volume.
- Each pod (up to 8) has a part: everything, left or right of a stereo pair, mono, one channel
  (centre, a surround, a height...) or a custom mix of the 8 channels.
- **What plays when.** Atmos with height channels is played as mixed. Stereo music has nothing for
  a speaker that plays single channels, so such a speaker fills in: by default with its side of
  the stereo recording; per speaker this can be left, right, both, or silence. With 5.1 or 7.1
  sound (no heights) a height speaker plays half front and half surround of its side.
- **Other AirPlay speakers** (a switch on the card, off by default): the leader also plays the
  room on AirPlay speakers that are not Nicotine pods (`homepod-roomsend`, which uses pyatv as the
  sender, and `/usr/libexec/hpmix`). Each gets a part like a pod, or a pair of channels on its
  left and right, plus a timing trim and a volume offset. Such a speaker wants its sound about a
  second and a half ahead, so while the switch is on the whole room plays 1.3 seconds later: play,
  pause, skip and volume answer that much later, and sound is that far behind a video. Speakers
  that ask for a code or a password are not supported.
- A room can be one pod plus other AirPlay speakers.
- The room file `/etc/homepod-room.conf` is part of the settings backup. Save settings on every pod.
- Tested: a stereo pair by ear, three pods by the pods' own measurements; other AirPlay speakers
  (a stock HomePod, an AirPort Express) only for connecting and for timing against a
  shairport-sync receiver (within 1 ms), not by ear; the stereo fill by the pod's meters; the
  5.1 fill not at all.

## Limits and known problems

- Build 113's boot image is about 67 MB (build 112: 47 MB). The boot loader's limit, read from
  its code, is 127 MB; a boot of the larger image had not been tried when this was written.
- The WiFi calibration file and the Bluetooth patch are the variants for the USI radio module.
  A pod whose module reports Murata worked with them in the one case tested; nothing picks files
  by module vendor yet.
- If the 11.2.5 download fails (no network), the build falls back to the WiFi firmware inside the
  18.3 IPSW and says so. That firmware does not start with this driver, so WiFi will not work on
  the pod. A good build prints "WiFi firmware and calibration are byte-identical to the validated
  Nicotine build".

## Note for `.gitignore`

This folder is lowercase `nicotine/`. A rule `Nicotine/` would also match it on macOS's
case-insensitive filesystem and silently stop tracking the whole kit.
