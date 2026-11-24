import Foundation

// MARK: - DIAGS shell command reference
//
// A reference card for the factory DIAGS shell (the `[ECID] :-)` prompt on the
// serial console after booting diag.img4 — see docs/diags-boot.md). The app
// shows it while a pod is in DIAGS mode; nothing here is ever sent to a pod.
//
// Where each entry comes from is recorded on the entry (`source`), because the
// three sources are not equally trustworthy:
//
// - `.factoryScript`  The exact command line appears in one of Apple's own
//                     factory scripts extracted from the ProtoPod build
//                     (audio_tuxedo_reset_script, audio_mlb_reset_script,
//                     sochot.sh, Connectivity.lua). Syntax is verbatim.
// - `.projectNotes`   Used and written down in this project (docs/diags-boot.md).
// - `.benchTested`    Typed at the prompt of a real HomePod and seen to work
//                     exactly as written.
// - `.commandList`    Taken from the full command list of a real HomePod in
//                     factory DIAGS. The command exists and the line is the
//                     one noted there, but it has not been confirmed line by
//                     line from this app yet.
// - `.firmwareAudit`  The command NAME was found in the DIAGS image, but no
//                     usage line has been captured. These entries say so and
//                     carry no invented options.
//
// Every entry also carries a `risk`. Most DIAGS commands only read, but a few
// write the unit's identity (`syscfg add`, `sn`) or wipe it (`syscfg init`),
// and the card must make that impossible to miss. One — `NANDInfoTool` — panics
// the unit outright (`.crashesDevice`): it must never be put behind a button.

/// One DIAGS shell command.
public struct DiagsCommand: Sendable, Equatable, Identifiable {
    public enum Category: String, Sendable, CaseIterable, Identifiable {
        case sysCfg, audio, radio, nand, sensor, power, led, input, deviceInfo, factoryHistory, storage, memory, shell

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .sysCfg: return "SysCfg & Identity"
            case .audio: return "Audio"
            case .radio: return "Wi-Fi & Bluetooth"
            case .nand: return "NAND"
            case .sensor: return "Sensors & Temperature"
            case .power: return "Power (PMU)"
            case .led: return "LED Ring"
            case .input: return "Touch & Buttons"
            case .deviceInfo: return "Device Info"
            case .factoryHistory: return "Factory History"
            case .storage: return "Storage"
            case .memory: return "Memory"
            case .shell: return "Logging & Board Control"
            }
        }

        /// One line on what the group is for at the bench.
        public var blurb: String {
            switch self {
            case .sysCfg: return "The unit's identity and factory calibration. The only group that can write to flash."
            case .audio: return "Bring up and exercise the amp controller, mic codecs and I2S links."
            case .radio: return "Talk to the Wi-Fi and Bluetooth chips and load their calibration."
            case .nand: return "Identify the NAND and read what the controller reports about it."
            case .sensor: return "Read the temperature and touch sensors."
            case .power: return "Read the power-management chip: rails, ADC channels, temperatures, latched fault events."
            case .led: return "Drive the top LED array directly — a quick check of the LED board."
            case .input: return "Check the touch surface and its buttons."
            case .deviceInfo: return "What the board says it is."
            case .factoryHistory: return "Control bits: which factory test stations the unit passed, failed or never saw."
            case .storage: return "Block devices, the NAND filesystem and NVRAM as DIAGS sees them."
            case .memory: return "Heap, RAM and the EFI memory map."
            case .shell: return "Capture output to a file, read the clock, toggle a GPIO."
            }
        }
    }

    /// What running the command can change.
    public enum Risk: String, Sendable, CaseIterable {
        /// Only reads.
        case readOnly
        /// Changes live hardware state (resets a chip, plays sound, lights an
        /// LED). Nothing persists past a reboot.
        case changesState
        /// Writes persistent data to the unit's flash.
        case writesFlash
        /// Not captured well enough to say. Treat as if it could change state.
        case unknown
        /// Known to panic the unit: DIAGS dies and the pod reboots into DFU, so
        /// it has to be booted into DIAGS all over again. Never sent by a
        /// button; a typed line asks for confirmation first.
        case crashesDevice

        public var title: String {
            switch self {
            case .readOnly: return "Read-only"
            case .changesState: return "Changes live state"
            case .writesFlash: return "Writes to flash"
            case .unknown: return "Effect not confirmed"
            case .crashesDevice: return "DANGEROUS — crashes the pod"
            }
        }
    }

    /// Where the entry's syntax comes from.
    public enum Source: Sendable, Equatable {
        /// Appears verbatim in this extracted Apple factory script.
        case factoryScript(String)
        /// Used and documented in this project (docs/diags-boot.md).
        case projectNotes
        /// Typed at the prompt of a real HomePod and seen to work as written.
        case benchTested
        /// From the full command list of a real HomePod in DIAGS; the line
        /// itself has not been confirmed from this app yet.
        case commandList
        /// Name found in the DIAGS image; usage not captured.
        case firmwareAudit

        public var title: String {
            switch self {
            case .factoryScript(let name): return "Apple factory script: \(name)"
            case .projectNotes: return "Project notes (docs/diags-boot.md)"
            case .benchTested: return "Confirmed on a real HomePod at the bench"
            case .commandList: return "From a real HomePod's DIAGS command list — line not yet confirmed from this app"
            case .firmwareAudit: return "Name from the firmware audit — usage not captured"
            }
        }

        /// The usage lines are known to be right.
        public var isConfirmed: Bool {
            if case .firmwareAudit = self { return false }
            return true
        }
    }

    /// A concrete command line with a plain-words explanation.
    public struct Example: Sendable, Equatable, Identifiable {
        public let command: String
        public let explanation: String
        public var id: String { command }

        public init(_ command: String, _ explanation: String) {
            self.command = command
            self.explanation = explanation
        }
    }

    /// The command word, e.g. "syscfg".
    public let name: String
    public let category: Category
    /// Usage lines. Empty when the usage hasn't been captured.
    public let syntax: [String]
    /// What it does, in one or two sentences.
    public let summary: String
    public let examples: [Example]
    public let risk: Risk
    public let source: Source
    /// Why a repair tech would reach for it; `nil` when it has no bench use yet.
    public let repairUse: String?
    /// The ramdisk check that reports the same thing without booting DIAGS.
    public let ramdiskEquivalent: DiagTool?

    public var id: String { name }

    public init(name: String, category: Category, syntax: [String] = [], summary: String,
                examples: [Example] = [], risk: Risk, source: Source,
                repairUse: String? = nil, ramdiskEquivalent: DiagTool? = nil) {
        self.name = name
        self.category = category
        self.syntax = syntax
        self.summary = summary
        self.examples = examples
        self.risk = risk
        self.source = source
        self.repairUse = repairUse
        self.ramdiskEquivalent = ramdiskEquivalent
    }

    /// Text shown where the usage would be when it hasn't been captured.
    public static let usageNotCaptured =
        "Usage not captured yet. Try `help <command>` at the prompt and note what it prints."

    /// Everything searchable about the command, lower-cased.
    var searchText: String {
        ([name, summary, repairUse ?? "", category.title] + syntax + examples.flatMap { [$0.command, $0.explanation] })
            .joined(separator: "\n").lowercased()
    }
}

/// A named sequence of DIAGS commands that does one bench job.
public struct DiagsRecipe: Sendable, Equatable, Identifiable {
    public let title: String
    public let category: DiagsCommand.Category
    /// When to use it.
    public let purpose: String
    /// The command lines, in order.
    public let steps: [String]
    public let risk: DiagsCommand.Risk
    public let source: DiagsCommand.Source
    /// What to look for afterwards.
    public let expect: String?

    public var id: String { title }

    public init(title: String, category: DiagsCommand.Category, purpose: String, steps: [String],
                risk: DiagsCommand.Risk, source: DiagsCommand.Source, expect: String? = nil) {
        self.title = title
        self.category = category
        self.purpose = purpose
        self.steps = steps
        self.risk = risk
        self.source = source
        self.expect = expect
    }
}

public enum DiagsCommandReference {
    /// The prompt the DIAGS shell prints, with the unit's ECID in the brackets.
    public static let prompt = "[ECID] :-)"

    /// Audio blocks the factory scripts address with `-b`. `codec2` is reset by
    /// the factory script although the B238 device tree lists two codec nodes.
    public static let audioBlocks = ["socmca", "audmux", "ampcontroller", "codec0", "codec1", "codec2"]

    // MARK: Test tones

    /// The one block `playaudio --listcaps` marks "(playable)" on a real unit.
    public static let playableAudioBlock = "socmca"
    /// The amp controller only takes 48 kHz / 16-bit (`playaudio --listcaps`),
    /// so every tone is generated in that format.
    public static let toneSampleRate = 48_000
    public static let toneBitDepth = 16

    /// The port on the SoC MCA block — `ap-mca3`, from the factory `audioparam` lines.
    public static let playableAudioPort = "ap-mca3"
    /// One synchronous `playaudio` test-tone line.
    public static func toneLine(hz: Int, ms: Int) -> String {
        "playaudio -b \(playableAudioBlock) -p \(playableAudioPort) -t \(hz) -l \(ms) -r \(toneSampleRate) -d \(toneBitDepth)"
    }

    /// The seal-check sweep, low to high: 100 Hz is the woofer (and the seal),
    /// the top of the range is the seven tweeters.
    public static let toneSweepFrequencies = [100, 500, 1000, 2000, 5000, 10000]
    /// Length of each sweep tone, in milliseconds.
    public static let toneSweepStepMs = 1500
    public static var toneSweepLines: [String] { toneSweepFrequencies.map { toneLine(hz: $0, ms: toneSweepStepMs) } }

    /// Full factory audio initialisation — MLB reset (clocks) + tuxedo reset (amp + routing).
    /// From `audio_mlb_reset_script` and `audio_tuxedo_reset_script` in the ProtoPod dump.
    /// Must run before any `playaudio` command.
    public static let audioInitSequence: [String] = [
        // MLB reset: SoC audio + mux + clock params
        "audio -b socmca",
        "audio -b audmux",
        "audioparam -b socmca -p ap-mca3 -s -n mclk-rate -v 24576000",
        "audioparam -b socmca -p ap-mca3 -s -n bclk-div -v 2",
        "audioparam -b socmca -p ap-mca3 -s -n iface-mode -v mca",
        "audioparam -b socmca -p ap-mca3 -s -n clocking-mode -v master",
        "audioparam -b socmca -p ap-mca3 -s -n master-lrclk-enable -v true",
        // Tuxedo reset: amp init + GPIO toggle + speaker routing
        "audio -b ampcontroller",
        "audio -b codec0",
        "audio -b codec1",
        "audio -b codec2",
        "socgpio --pin 114 --output 0",
        "socgpio --pin 116 --output 1",
        "socgpio --pin 115 --output 0",
        "socgpio --pin 115 --output 1",
        "routeaudio -b ampcontroller -i spk-tdm -o spk-out -r",
    ]

    /// "100 Hz", "1 kHz".
    public static func toneLabel(_ hz: Int) -> String {
        hz >= 1000 && hz % 1000 == 0 ? "\(hz / 1000) kHz" : "\(hz) Hz"
    }

    // MARK: Commands

    public static let all: [DiagsCommand] = sysCfg + audio + radio + nand + sensor + power + led + input + deviceInfo + factoryHistory + storage + memory + shell

    private typealias C = DiagsCommand
    private typealias E = DiagsCommand.Example

    private static let tuxedo = DiagsCommand.Source.factoryScript("audio_tuxedo_reset_script")
    private static let mlb = DiagsCommand.Source.factoryScript("SMT/audio_mlb_reset_script")
    private static let sochot = DiagsCommand.Source.factoryScript("sochot.sh")
    private static let connectivity = DiagsCommand.Source.factoryScript("Connectivity.lua")

    private static func audited(_ name: String, _ category: DiagsCommand.Category, _ summary: String,
                                risk: DiagsCommand.Risk = .unknown, repairUse: String? = nil,
                                ramdiskEquivalent: DiagTool? = nil) -> DiagsCommand {
        C(name: name, category: category, summary: summary, risk: risk, source: .firmwareAudit,
          repairUse: repairUse, ramdiskEquivalent: ramdiskEquivalent)
    }

    /// A command typed bare (no arguments) on a real HomePod and seen to work.
    private static func tested(_ name: String, _ category: DiagsCommand.Category, _ summary: String,
                               risk: DiagsCommand.Risk, repairUse: String? = nil,
                               ramdiskEquivalent: DiagTool? = nil) -> DiagsCommand {
        C(name: name, category: category, syntax: [name], summary: summary, risk: risk, source: .benchTested,
          repairUse: repairUse, ramdiskEquivalent: ramdiskEquivalent)
    }

    /// A command from the real unit's command list (`.commandList`). `syntax`
    /// defaults to the bare command word.
    private static func listed(_ name: String, _ category: DiagsCommand.Category, _ summary: String,
                               syntax: [String]? = nil, examples: [DiagsCommand.Example] = [],
                               risk: DiagsCommand.Risk, repairUse: String? = nil,
                               ramdiskEquivalent: DiagTool? = nil) -> DiagsCommand {
        C(name: name, category: category, syntax: syntax ?? [name], summary: summary, examples: examples,
          risk: risk, source: .commandList, repairUse: repairUse, ramdiskEquivalent: ramdiskEquivalent)
    }

    static let sysCfg: [DiagsCommand] = [
        C(name: "syscfg", category: .sysCfg,
          syntax: ["syscfg list", "syscfg print <KEY>", "syscfg dump", "syscfg stats",
                   "syscfg add <KEY> <value>", "syscfg delete <KEY>", "syscfg init"],
          summary: "Reads and writes SysCfg — the unit's serial number, MAC addresses and factory calibration. `list`, `print`, `dump` and `stats` only read; `add`, `delete` and `init` write to flash.",
          examples: [
            E("syscfg list", "Every key with its value. Save the whole output BEFORE a NAND swap — it is the only copy of the unit's identity and calibration."),
            E("syscfg print SrNm", "One key. Binary keys print as space-separated 32-bit hex words."),
            E("syscfg print WCAL", "The Wi-Fi calibration blob — the factory Connectivity script reads it exactly this way."),
            E("syscfg add SrNm <serial>", "Writes one key. Writes flash."),
            E("syscfg delete Mod#", "Removes one key. Writes flash. First step of a colour change (Reconfigure Model): delete, then `syscfg add Mod# <model>`, then `syscfg print Mod#` to check."),
            E("syscfg add CLCG 0x00000001 0x00000000 0x00000000 0x00000002", "Cover Glass Color. The last word is the colour: 1 = Space Gray, 2 = White. Writes flash. A colour change needs Mod#, CLCG and CLHS (same value as CLCG) — confirmed on real hardware: after a firmware restore the iOS setup prompt shows the new colour."),
            E("syscfg init", "Creates an EMPTY SysCfg. Only for a brand-new NAND: on a working unit this erases its identity and calibration."),
          ],
          risk: .writesFlash, source: .projectNotes,
          repairUse: "The NAND-replacement workflow: `syscfg list` on the old chip, then `syscfg init` and `syscfg add` on the new one, including the calibration keys (WCAL, BCAL, SpEQ, WFEQ, SpGa, MiGa, LEDc, LSCI).",
          ramdiskEquivalent: .factory),
        C(name: "sn", category: .sysCfg, syntax: ["sn"],
          summary: "Shortcut for the serial number (the SrNm key): reads it, and can write it.",
          risk: .writesFlash, source: .projectNotes,
          repairUse: "Quick check that the serial matches the sticker under the base.",
          ramdiskEquivalent: .factory),
    ]

    static let audio: [DiagsCommand] = [
        C(name: "audio", category: .audio, syntax: ["audio -b <block>"],
          summary: "Resets and initialises one audio block. Blocks used by the factory: socmca (the SoC's I2S ports), audmux, ampcontroller (the MCU that drives every speaker amp), codec0 / codec1 / codec2 (the mic codecs).",
          examples: [
            E("audio -b ampcontroller", "Reset the amp controller. If this errors, nothing downstream can make sound — suspect the amp board or its flex."),
            E("audio -b codec0", "Reset mic codec 0. An error here points at the mic array / top assembly."),
            E("audio -b socmca", "Reset the SoC I2S ports. Always the first step."),
          ],
          risk: .changesState, source: tuxedo,
          repairUse: "The fastest \"which part of the audio chain is dead\" test: reset each block in turn and see which one fails to answer.",
          ramdiskEquivalent: .audio),
        C(name: "routeaudio", category: .audio, syntax: ["routeaudio -b <block> -i <input> -o <output> -r"],
          summary: "Connects an input of a block to one of its outputs. The factory routes the amp controller's TDM input to the speaker outputs, and each codec's mic input to its PCM output.",
          examples: [
            E("routeaudio -b ampcontroller -i spk-tdm -o spk-out -r", "Speaker path: TDM data from the SoC out to the drivers."),
            E("routeaudio -b codec0 -i mic-in -o pcm-out -r", "Mic path for codec 0. Repeat for codec1 and codec2."),
          ],
          risk: .changesState, source: tuxedo,
          repairUse: "Needed after the block resets and before any play / record test."),
        C(name: "audioparam", category: .audio, syntax: ["audioparam -b <block> -p <port> -s -n <name> -v <value>"],
          summary: "Sets one parameter on a port of an audio block (`-s` = set). The bare-board script uses it to clock I2S port ap-mca3 as master at 24.576 MHz.",
          examples: [
            E("audioparam -b socmca -p ap-mca3 -s -n mclk-rate -v 24576000", "Master clock 24.576 MHz."),
            E("audioparam -b socmca -p ap-mca3 -s -n bclk-div -v 2", "Bit clock = master clock / 2."),
            E("audioparam -b socmca -p ap-mca3 -s -n iface-mode -v mca", "Interface mode."),
            E("audioparam -b socmca -p ap-mca3 -s -n clocking-mode -v master", "The SoC drives the clocks."),
            E("audioparam -b socmca -p ap-mca3 -s -n master-lrclk-enable -v true", "Enable the frame clock."),
          ],
          risk: .changesState, source: mlb,
          repairUse: "Lets you put a scope on the I2S clock lines of a bare logic board and see whether the SoC is clocking."),
        C(name: "ampcontroller", category: .audio, syntax: ["ampcontroller --init", "ampcontroller -s [TEMP]"],
          summary: "Talks to the amp controller MCU. `--init` brings it up (confirmed on a real unit; changes live state); the factory thermal script reads its temperature sensor with `-s [TEMP]`.",
          examples: [E("ampcontroller --init", "Initialise the amp controller — the first step before anything audible."),
                     E("ampcontroller -s [TEMP]", "Amp controller temperature. A reading at all proves the MCU is alive and answering.")],
          risk: .readOnly, source: sochot,
          repairUse: "A live temperature reading is a cheap proof that the amp board is powered and its serial link works.",
          ramdiskEquivalent: .audio),
        C(name: "playaudio", category: .audio,
          syntax: ["playaudio --listcaps",
                   "playaudio -b <block> [-p <port>] -t <freqHz> -l <lenMs> [-r <rateHz>] [-d 8|16|24|32] [-c <channels>] [--async]",
                   "playaudio -b <block> [-p <port>] -f <wavefile>",
                   "playaudio -b <block> [-p <port>] -u <buffername>"],
          summary: "Plays a generated tone, a WAVE file or a memory buffer out of a playable port of an audio block. Options are from `help playaudio` on a real unit; `--listcaps` there marks socmca as the only playable block and limits the amp controller to 48 kHz / 16-bit. Without `--async` it blocks until the sound has ended. Typed bare it answers \"Both Blockname and Portnames have to be provided!\", and the port names haven't been captured — so the tone lines below, which name no port, are not yet confirmed to play.",
          examples: [
            E("playaudio --listcaps", "Sample rates and bit depths of every audio block, and which blocks are playable. Only reads. Confirmed on a real unit."),
            E(toneLine(hz: 1000, ms: 3000), "1 kHz reference tone for 3 seconds — the Test Tone button. If the shell asks for a port, add `-p <port>`."),
            E(toneLine(hz: 100, ms: toneSweepStepMs), "100 Hz for 1.5 seconds — the first tone of the sweep, and the one that shows a leaking seal."),
            E(toneLine(hz: 10000, ms: toneSweepStepMs), "10 kHz for 1.5 seconds — the last tone of the sweep, tweeters only."),
          ],
          risk: .changesState, source: .projectNotes,
          repairUse: "The audible speaker test the ramdisk can't do. Run `ampcontroller --init` first; if that alone gives silence, run the audio reset recipe (it routes the speaker path) and try again."),
        audited("recordaudio", .audio, "Records from the microphones. Typed bare it only answers \"Both Blockname and Portnames have to be provided!\" — run `help recordaudio` for the block and port arguments.", risk: .changesState,
                repairUse: "The working-microphone test the ramdisk can't do."),
        audited("loopaudio", .audio, "Loops recorded audio back to the speakers.", risk: .changesState),
        audited("stopaudio", .audio, "Stops a play / record session that was started with `--async` (`help playaudio`: \"Use stopaudio to stop the session\"). A synchronous `playaudio` holds the shell until it ends, so there is nothing for this to stop then. Not yet run on a real unit from this app.", risk: .changesState,
                repairUse: "The way out of an `--async` tone that is still sounding."),
        audited("spkid", .audio, "Reports the speaker ID. Not yet run on a real unit from this app.", risk: .readOnly,
                repairUse: "Tells you which speaker assembly the board believes is fitted."),
        audited("getvol", .audio, "Reads the current volume setting. Not yet run on a real unit from this app.", risk: .readOnly),
        audited("setvol", .audio, "Sets the volume. Arguments not captured — run `help setvol`.", risk: .changesState),
    ]

    static let radio: [DiagsCommand] = [
        C(name: "wifi", category: .radio, syntax: ["wifi --send_cmd <command> [args]", "wifi --send_cmd calload <file>"],
          summary: "Sends a command to the Wi-Fi chip. The factory loads the unit's own calibration by saving SysCfg WCAL to a file and passing it to `calload`. Typed bare it only answers \"ERROR: No option specified\"; `--send_cmd` is the one option captured so far — run `help wifi` for the rest.",
          examples: [E("wifi --send_cmd calload nandfs:\\AppleInternal\\Diags\\WiFiFirmware\\WCAL.bin",
                       "Load a calibration file into the chip. The file is the WCAL value with each 32-bit word byte-swapped back to its original order.")],
          risk: .changesState, source: connectivity,
          repairUse: "If this fails on a unit whose WCAL is present, the Wi-Fi module itself is suspect rather than its calibration.",
          ramdiskEquivalent: .radio),
        C(name: "bluetooth", category: .radio, syntax: ["bluetooth --send_raw \"<hex bytes>\""],
          summary: "Sends a raw HCI command to the Bluetooth chip. The factory loads BCAL in 230-byte chunks with the vendor command 01 97 FD E9, three sections, counting the remaining chunks down to zero. Typed bare it does nothing useful; `--send_raw` is the one option captured so far — run `help bluetooth` for the rest.",
          examples: [E("bluetooth --send_raw \"01 97 FD E9 03 <chunks left> 00 <230 data bytes>\"",
                       "One calibration chunk. The last chunk is zero-padded to 230 bytes.")],
          risk: .changesState, source: connectivity,
          repairUse: "A chip that accepts raw HCI commands is alive; one that never answers points at the module or its UART.",
          ramdiskEquivalent: .radio),
    ]

    static let nand: [DiagsCommand] = [
        listed("nand", .nand, "General NAND tests. Typed bare it only answers \"ERROR: No arguments\". `--testlist` lists the available tests WITHOUT running any, and `--getinfo` prints the NAND driver's parameters; both only read. Run `help nand` before trying anything else, since NAND tests may write.",
               syntax: ["nand --testlist", "nand --getinfo"],
               examples: [E("nand --testlist", "The NAND tests this build offers. Lists them; runs none."),
                          E("nand --getinfo", "NAND driver parameters.")],
               risk: .unknown, ramdiskEquivalent: .nand),
        audited("NANDInfoTool", .nand, "DO NOT RUN. Typed bare on a real HomePod it panics DIAGS (null-pointer dereference in TestNand.macho, Translation Fault Level 1) and the pod reboots into DFU, so DIAGS has to be booted again. Use nandcsid, nandppnfwver and nanduid for the same information.",
                risk: .crashesDevice),
        tested("nandcsid", .nand, "Reads the NAND chip ID of every chip enable (two on the unit tested).", risk: .readOnly,
               repairUse: "Confirms a replacement chip is the part you meant to fit.", ramdiskEquivalent: .nand),
        audited("nandppnfwver", .nand, "Prints the NAND's PPN firmware version. Not yet run on a real unit from this app.", risk: .readOnly,
                repairUse: "Record it at intake and again after a NAND swap.", ramdiskEquivalent: .nand),
        audited("nanduid", .nand, "Reads the NAND's unique ID.", risk: .readOnly,
                repairUse: "The ID changes with the chip, so it proves whether the NAND has been replaced.", ramdiskEquivalent: .nand),
        audited("nandsize", .nand, "Reports the NAND capacity.", risk: .readOnly, ramdiskEquivalent: .nand),
    ]

    static let sensor: [DiagsCommand] = [
        C(name: "temperature", category: .sensor, syntax: ["temperature --all"],
          summary: "Reads the temperature sensors. `--all` reads every one. Typed bare it only answers \"ERROR: Invalid Usage\".",
          examples: [E("temperature --all", "Every sensor in one go — the first line of Apple's SoC thermal script.")],
          risk: .readOnly, source: sochot,
          repairUse: "A sensor that reads absurdly high or low, or is missing from the list, locates an open flex or a dead sensor.",
          ramdiskEquivalent: .thermal),
        C(name: "sensor", category: .sensor, syntax: ["sensor -s <sensor> --get <value>"],
          summary: "Reads one value from a named sensor. The factory reads the touch controller's temperature this way. Typed bare it only answers \"Invalid Parameter\" — it needs both `-s` and `--get`.",
          examples: [E("sensor -s touch --get temp", "Touch-controller temperature. An answer proves the top touch board is connected.")],
          risk: .readOnly, source: sochot,
          repairUse: "Quick continuity check of the top (touch / LED) board."),
        audited("thermalmonitor", .sensor, "Monitors temperatures over time.", risk: .readOnly, ramdiskEquivalent: .thermal),
    ]

    static let power: [DiagsCommand] = [
        C(name: "pmutemp", category: .power, syntax: ["pmutemp", "pmutemp --read all"],
          summary: "Reads the power-management chip's temperature sensors. Typed bare it runs the PMU temperature test and prints Pass or Fail (confirmed on a real unit).",
          examples: [E("pmutemp", "The PMU temperature test: one Pass / Fail verdict."),
                     E("pmutemp --read all", "All PMU temperature channels.")],
          risk: .readOnly, source: sochot,
          repairUse: "A hot PMU at idle points at a shorted rail.", ramdiskEquivalent: .power),
        audited("pmuadc", .power, "Reads the PMU's ADC channels (voltages and currents).", risk: .readOnly,
                repairUse: "Rail voltages without a multimeter.", ramdiskEquivalent: .power),
        audited("pmustat", .power, "PMU status. The quick action sends `pmustat all`; that argument hasn't been confirmed on a real unit — if it errors, run `help pmustat`.", risk: .readOnly, ramdiskEquivalent: .power),
        listed("pmureg", .power, "Raw PMU registers. Typed bare it dumps every register (only reads). With arguments it may write a register — run `help pmureg` first.",
               examples: [E("pmureg", "Dump all PMU registers.")],
               risk: .unknown,
               repairUse: "Save the dump from a known-good board and diff it against a faulty one."),
        C(name: "pmurw", category: .power,
          syntax: ["pmurw -r <0xBBRR> <count>"],
          summary: "Reads the power chip's registers by 16-bit address (bank, register). `-r` only reads (confirmed on a real unit: `pmurw -r 0x0426 2`). The write form hasn't been captured — run `help pmurw` before writing anything.",
          examples: [E(PMUBootState.diagsReadCommand, "iBoot's boot bookkeeping in the PMU scratch area: boot-error count, the stage it failed at, and the enter-DFU request byte (0x4014)."),
                     E("pmurw -r 0x0426 2", "PMU GPIO 20 — the Nitrogen amp MCU's reset line.")],
          risk: .unknown, source: .benchTested,
          repairUse: "A board that boot-loops: a nonzero iBoot error count and its stage show where boot gives up."),
        listed("pmuevent", .power, "Prints the PMU's latched events: faults, under- and over-voltage, and what woke or shut down the board.",
               syntax: ["pmuevent all"],
               examples: [E("pmuevent all", "Every latched PMU event.")],
               risk: .readOnly,
               repairUse: "Dead-board triage: a latched under-voltage or fault event names the rail to chase before you reach for the meter."),
        listed("buckcheck", .power, "Checks the PMU's buck converter output voltages.", risk: .readOnly,
               repairUse: "A buck that is out of range points at a shorted or overloaded rail."),
    ]

    static let led: [DiagsCommand] = [
        C(name: "strobe", category: .led, syntax: ["strobe -c led --power on", "strobe -c led --power off", "strobe -c led -s <set> --set <colour> <level>"],
          summary: "Drives the top LED array. `-s All_RGB` addresses every LED; the level is a brightness. Red and blue at level 25 are confirmed on a real unit (the red line is also verbatim in Apple's sochot.sh); green follows the same pattern. Setting red, green and blue one after another gives white.",
          examples: [
            E("strobe -c led -s All_RGB --set red 25", "All LEDs red at level 25. Confirmed on a real unit."),
            E("strobe -c led -s All_RGB --set blue 25", "All LEDs blue at level 25. Confirmed on a real unit."),
            E("strobe -c led -s All_RGB --set green 25", "All LEDs green at level 25. Same pattern as red and blue; not yet confirmed on its own."),
            E("strobe -c led --power off", "LEDs off."),
          ],
          risk: .changesState, source: .benchTested,
          repairUse: "Lights the whole LED board one colour at a time — dead LEDs and dead channels are obvious."),
    ]

    static let input: [DiagsCommand] = [
        audited("button", .input, "Button test.", repairUse: "The place to start for a top surface that ignores + / − or centre taps."),
        audited("buttoncnt", .input, "Listed with the button tests (by its name, a press counter); function not confirmed."),
        audited("key", .input, "Listed with the button tests; function not confirmed."),
        audited("mbt", .input, "Listed with the touch / button tests; function not confirmed."),
    ]

    static let deviceInfo: [DiagsCommand] = [
        tested("sysinfo", .deviceInfo, "System summary.", risk: .readOnly),
        tested("system", .deviceInfo, "Basic unit information.", risk: .readOnly),
        listed("soc", .deviceInfo, "SoC details beyond the chip ID.", risk: .readOnly),
        listed("bootcfg", .deviceInfo, "Prints the boot configuration.", risk: .readOnly),
        C(name: "device", category: .deviceInfo, syntax: ["device -l"],
          summary: "Works with the devices DIAGS knows about. `-l` lists them (confirmed on a real unit; only reads). Other options haven't been captured — run `help device`.",
          examples: [E("device -l", "List the devices.")],
          risk: .unknown, source: .benchTested),
        tested("version", .deviceInfo, "DIAGS build version.", risk: .readOnly),
        tested("chipid", .deviceInfo, "SoC chip ID.", risk: .readOnly),
        tested("boardid", .deviceInfo, "Board ID.", risk: .readOnly),
        tested("boardrev", .deviceInfo, "Board revision.", risk: .readOnly),
    ]

    static let factoryHistory: [DiagsCommand] = [
        C(name: "cbreadall", category: .factoryHistory, syntax: ["cbreadall"],
          summary: "Reads every control bit: one entry per factory test station (256 of them) with that station's recorded result. Confirmed on a real unit. The output is long.",
          examples: [E("cbreadall", "The unit's whole factory station history. Scroll the output, or use Save… to keep it.")],
          risk: .readOnly, source: .benchTested,
          repairUse: "Shows which factory stations this unit passed and which it failed or never reached — a failed audio or connectivity station on a unit with that same complaint is a strong lead."),
        listed("cbdump", .factoryHistory, "Dumps the raw control-bit area.", risk: .readOnly,
               repairUse: "The raw bytes behind `cbreadall`, for when a station's entry needs decoding by hand."),
    ]

    static let storage: [DiagsCommand] = [
        audited("blockdevice", .storage, "Lists the block devices DIAGS can see.", risk: .readOnly, ramdiskEquivalent: .partmap),
        listed("dir", .storage, "Lists a directory on one of the shell's volumes. `fs0:` and `nandfs:` are the NAND filesystem.",
               syntax: ["dir <volume>:", "dir <volume>:\\<path>"],
               examples: [E("dir fs0:", "The top of fs0."),
                          E("dir nandfs:", "The top of the NAND filesystem — the factory scripts keep their files under nandfs:\\AppleInternal\\Diags.")],
               risk: .readOnly,
               repairUse: "A filesystem that lists at all proves the NAND is readable from DIAGS."),
        listed("nvram", .storage, "NVRAM variables. `nvram -p` is meant to print them all, but that option is a GUESS that has not been run on a real unit — if it errors, run `help nvram`. Other options may write NVRAM.",
               syntax: ["nvram -p"],
               examples: [E("nvram -p", "Print every NVRAM variable (unconfirmed option).")],
               risk: .unknown,
               repairUse: "boot-args and auto-boot explain a unit that boots somewhere unexpected."),
    ]

    static let memory: [DiagsCommand] = [
        listed("memory", .memory, "Heap and RAM diagnostics. `--info` summarises memory use and `--list` lists the allocations.",
               syntax: ["memory --info", "memory --list"],
               examples: [E("memory --info", "Memory summary."), E("memory --list", "Allocation list.")],
               risk: .readOnly),
        listed("dumpmemmap", .memory, "Prints the EFI memory map.", risk: .readOnly,
               repairUse: "The RAM size the firmware found — a short map on a board that should have more points at the memory or its solder joints."),
    ]

    static let shell: [DiagsCommand] = [
        C(name: "help", category: .shell, syntax: ["help", "help <command>"],
          summary: "Lists every command, or prints one command's usage. The shell itself points here when a command is given the wrong arguments (\"Type 'help wifi' for usage\").",
          examples: [E("help wifi", "The Wi-Fi command's options."),
                     E("help playaudio", "The block and port arguments the audio player wants.")],
          risk: .readOnly, source: .benchTested,
          repairUse: "The safe first move for any command whose arguments aren't on this card. It only prints text."),
        C(name: "filelog", category: .shell, syntax: ["filelog --on <path>", "filelog --off"],
          summary: "Copies everything the shell prints into a file on the unit until switched off.",
          examples: [E("filelog --on \\AppleInternal\\Diags\\Logs\\B238a\\Sochot0Log.txt", "Start logging to a file."),
                     E("filelog --off", "Stop logging.")],
          risk: .writesFlash, source: sochot,
          repairUse: "Rarely needed at the bench — capturing the serial console on the Mac is simpler and writes nothing to the unit."),
        C(name: "consolerouter", category: .shell, syntax: ["consolerouter --add --src <streams> --dest <destination> --quiet"],
          summary: "Chooses which output streams (errors, warnings, prints, debug) go to which destination.",
          examples: [E("consolerouter --add --src *.{error,warn,print},system.debug.debug --dest file --quiet",
                       "Send errors, warnings, prints and debug output to the log file.")],
          risk: .changesState, source: sochot),
        C(name: "rtc", category: .shell, syntax: ["rtc --get"], summary: "Reads the real-time clock.",
          examples: [E("rtc --get", "Current RTC time.")], risk: .readOnly, source: sochot),
        C(name: "socgpio", category: .shell, syntax: ["socgpio --pin <number> --output <0|1>"],
          summary: "Drives one SoC GPIO pin low or high. The audio reset script uses pins 114, 115 and 116; pin 115 is driven low then high again, which looks like a reset pulse.",
          examples: [E("socgpio --pin 115 --output 0", "Assert (pull low)."), E("socgpio --pin 115 --output 1", "Release.")],
          risk: .changesState, source: tuxedo,
          repairUse: "Lets you hold an audio reset line and probe it. Only drive pins you have identified — the wrong one can fight another driver."),
    ]

    // MARK: Recipes

    public static let recipes: [DiagsRecipe] = [
        DiagsRecipe(title: "Reset the audio chain (assembled unit)", category: .audio,
                    purpose: "No sound, or before any play / record test. Brings every audio block back to a known state and routes speakers and mics.",
                    steps: ["audio -b socmca", "audio -b ampcontroller", "audio -b codec0", "audio -b codec1", "audio -b codec2",
                            "socgpio --pin 114 --output 0", "socgpio --pin 116 --output 1",
                            "socgpio --pin 115 --output 0", "socgpio --pin 115 --output 1",
                            "routeaudio -b ampcontroller -i spk-tdm -o spk-out -r",
                            "routeaudio -b codec0 -i mic-in -o pcm-out -r",
                            "routeaudio -b codec1 -i mic-in -o pcm-out -r",
                            "routeaudio -b codec2 -i mic-in -o pcm-out -r"],
                    risk: .changesState, source: tuxedo,
                    expect: "Every line should return without an error. The first block that errors is the one to chase: ampcontroller = amp board / flex, codecN = mic array / top assembly, socmca = logic board."),
        DiagsRecipe(title: "Speaker seal check (tone sweep)", category: .audio,
                    purpose: "After reassembly: plays six tones from 100 Hz to 10 kHz, 1.5 seconds each (about 9 seconds), to hear whether the enclosure is sealed and every driver works. The Tone Sweep button sends exactly these lines.",
                    steps: ["ampcontroller --init"] + toneSweepLines,
                    risk: .changesState, source: .projectNotes,
                    expect: "100 Hz should be strong, clean bass from the woofer — weak or rattling bass means the enclosure is leaking. 500 Hz and up should be clean with no buzz; the top tones come from the tweeters. These lines name no port: if playaudio asks for one, nothing will sound until `-p <port>` is added."),
        DiagsRecipe(title: "Clock the I2S port (bare logic board)", category: .audio,
                    purpose: "Logic board on the bench with nothing attached. Makes the SoC drive ap-mca3 as I2S master so the clocks can be scoped.",
                    steps: ["audio -b socmca", "audio -b audmux",
                            "audioparam -b socmca -p ap-mca3 -s -n mclk-rate -v 24576000",
                            "audioparam -b socmca -p ap-mca3 -s -n bclk-div -v 2",
                            "audioparam -b socmca -p ap-mca3 -s -n iface-mode -v mca",
                            "audioparam -b socmca -p ap-mca3 -s -n clocking-mode -v master",
                            "audioparam -b socmca -p ap-mca3 -s -n master-lrclk-enable -v true"],
                    risk: .changesState, source: mlb,
                    expect: "24.576 MHz on the master clock and 12.288 MHz on the bit clock. No clocks = SoC-side fault, not the amp board."),
        DiagsRecipe(title: "Thermal and top-board snapshot", category: .sensor,
                    purpose: "One pass over every temperature source plus an LED check — Apple's SoC thermal station, minus the file logging.",
                    steps: ["temperature --all", "pmutemp --read all", "sensor -s touch --get temp", "ampcontroller -s [TEMP]",
                            "strobe -c led --power off", "strobe -c led -s All_RGB --set red 25", "rtc --get"],
                    risk: .changesState, source: sochot,
                    expect: "Four groups of readings (SoC sensors, PMU, touch board, amp controller). A group that errors identifies a board that isn't answering; the LEDs should all light red."),
        DiagsRecipe(title: "Save identity and calibration before a NAND swap", category: .sysCfg,
                    purpose: "Do this first, while the original NAND still works. Without it the unit's calibration is gone for good.",
                    steps: ["syscfg list"],
                    risk: .readOnly, source: .projectNotes,
                    expect: "Capture the full serial output to a file. Check it includes SrNm, MLB#, WMac, BMac, WCAL, BCAL, SpEQ, WFEQ, SpGa and MiGa."),
    ]

    // MARK: Lookup

    public static func commands(in category: DiagsCommand.Category) -> [DiagsCommand] {
        all.filter { $0.category == category }
    }

    public static func recipes(in category: DiagsCommand.Category) -> [DiagsRecipe] {
        recipes.filter { $0.category == category }
    }

    /// Categories that have at least one command, in display order.
    public static var categories: [DiagsCommand.Category] {
        DiagsCommand.Category.allCases.filter { category in all.contains { $0.category == category } }
    }

    /// Exact, case-insensitive match on the command word.
    public static func command(named name: String) -> DiagsCommand? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return all.first { $0.name.lowercased() == wanted }
    }

    /// Commands whose name, summary, usage or examples contain every word of
    /// `query`. An empty query returns everything.
    public static func search(_ query: String) -> [DiagsCommand] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { command in words.allSatisfy { command.searchText.contains($0) } }
    }

    /// The command a typed line starts with — for showing the matching card
    /// (and its risk) as the tech types at the prompt.
    public static func command(forLine line: String) -> DiagsCommand? {
        guard let word = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" }).first else { return nil }
        return command(named: String(word))
    }

    /// Risk of one specific line. `syscfg` is read-only or writing depending on
    /// its subcommand, so the command's own risk would be too coarse.
    public static func risk(ofLine line: String) -> DiagsCommand.Risk? {
        guard let command = command(forLine: line) else { return nil }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" }).map { $0.lowercased() }
        switch command.name {
        case "syscfg":
            guard words.count > 1 else { return .readOnly }
            return ["list", "print", "dump", "stats"].contains(words[1]) ? .readOnly : .writesFlash
        case "sn":
            return words.count > 1 ? .writesFlash : .readOnly
        case "filelog":
            return words.contains("--on") ? .writesFlash : .changesState
        case "ampcontroller":
            return words.contains("--init") ? .changesState : command.risk
        case "playaudio":
            // Listing capabilities only prints; anything else makes sound.
            return words.count == 2 && ["--listcaps", "-o"].contains(words[1]) ? .readOnly : command.risk
        case "nand":
            // Listing the tests and printing driver parameters only read; any
            // other NAND test may write.
            return words.count == 2 && ["--testlist", "--getinfo"].contains(words[1]) ? .readOnly : command.risk
        case "pmureg":
            // Bare, it dumps every register. With arguments it may write one.
            return words.count == 1 ? .readOnly : command.risk
        case "pmurw":
            return words.count >= 2 && words[1] == "-r" ? .readOnly : command.risk
        case "nvram":
            return words.count == 2 && words[1] == "-p" ? .readOnly : command.risk
        case "device":
            return words.count == 2 && words[1] == "-l" ? .readOnly : command.risk
        default:
            return command.risk
        }
    }

    // MARK: Plain text

    /// The whole card as plain text (copy to clipboard / print).
    public static func plainText() -> String {
        var lines: [String] = ["HomePod DIAGS command reference", "Prompt: \(prompt)", ""]
        for category in categories {
            lines.append("== \(category.title) ==")
            lines.append(category.blurb)
            for command in commands(in: category) {
                lines.append("")
                lines.append("\(command.name)  [\(command.risk.title)]")
                lines.append("  \(command.summary)")
                if command.syntax.isEmpty {
                    lines.append("  \(DiagsCommand.usageNotCaptured)")
                } else {
                    for usage in command.syntax { lines.append("    \(usage)") }
                }
                for example in command.examples {
                    lines.append("    > \(example.command)")
                    lines.append("      \(example.explanation)")
                }
                if let use = command.repairUse { lines.append("  Bench use: \(use)") }
                lines.append("  Source: \(command.source.title)")
            }
            for recipe in recipes(in: category) {
                lines.append("")
                lines.append("Recipe: \(recipe.title)  [\(recipe.risk.title)]")
                lines.append("  \(recipe.purpose)")
                for step in recipe.steps { lines.append("    \(step)") }
                if let expect = recipe.expect { lines.append("  Expect: \(expect)") }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - HomePod model variants (colour)
//
// The colour of a 1st-gen HomePod is carried by THREE SysCfg keys, and all
// three have to change for the unit to be a different colour everywhere:
//
//   Mod#  model number          MQHW2 = Space Gray, MQHV2 = White
//   CLCG  Cover Glass Color     four 32-bit words; the LAST is the colour code
//   CLHS  Housing Color         same format and same codes as CLCG
//
//   Space Gray  0x00000001 0x00000000 0x00000000 0x00000001
//   White       0x00000001 0x00000000 0x00000000 0x00000002
//
// Confirmed on real hardware: with all three written and the firmware
// restored, the iOS setup prompt shows the new colour. Writing `Mod#` alone
// only changes the model number shown in Settings.
//
// The region (LL/A, X/A, …) is normally a separate key (`Regn`), but a model
// string that carries a suffix ("MQHW2LL/A") keeps it when the colour is
// changed.

/// One colour of the 1st-gen HomePod: the model number and the CLCG / CLHS
/// colour code that go with it.
public struct HomePodModelVariant: Sendable, Equatable, Identifiable {
    /// The model number without a region suffix, e.g. "MQHW2".
    public let modelBase: String
    /// "Space Gray" or "White".
    public let color: String
    /// The colour code — the last word of `CLCG` and `CLHS`.
    /// 1 = Space Gray, 2 = White.
    public let colorCode: UInt32
    /// SF Symbol for the colour swatch.
    public let sfSymbol: String

    public var id: String { modelBase }

    public init(modelBase: String, color: String, colorCode: UInt32, sfSymbol: String) {
        self.modelBase = modelBase
        self.color = color
        self.colorCode = colorCode
        self.sfSymbol = sfSymbol
    }

    public static let spaceGray = HomePodModelVariant(modelBase: "MQHW2", color: "Space Gray", colorCode: 1, sfSymbol: "circle.fill")
    public static let white = HomePodModelVariant(modelBase: "MQHV2", color: "White", colorCode: 2, sfSymbol: "circle")

    public static let all = [spaceGray, white]

    /// The variant a model string like "MQHW2" or "mqhw2LL/A" belongs to.
    public static func variant(for model: String) -> HomePodModelVariant? {
        let wanted = model.trimmingCharacters(in: .whitespaces).uppercased()
        return all.first { wanted.hasPrefix($0.modelBase) }
    }

    /// The model string for `target`, keeping whatever region suffix `current`
    /// carries ("MQHW2LL/A" → "MQHV2LL/A"). A model that isn't one of the
    /// known variants gives the target's bare model number.
    public static func remodel(_ current: String, to target: HomePodModelVariant) -> String {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        guard let currentVariant = variant(for: trimmed) else { return target.modelBase }
        // Only the leading base is replaced; the suffix is kept as it is.
        return target.modelBase + String(trimmed.dropFirst(currentVariant.modelBase.count))
    }

    // MARK: CLCG / CLHS

    /// The value of `CLCG` (Cover Glass Color) and of `CLHS` (Housing Color)
    /// for this colour: three fixed words, then the colour code.
    public var clcgValue: [UInt32] { [0x00000001, 0x00000000, 0x00000000, colorCode] }

    /// `clcgValue` as it goes on a `syscfg add CLCG …` / `syscfg add CLHS …`
    /// line: "0x00000001 0x00000000 0x00000000 0x00000002".
    public var clcgArgs: String {
        clcgValue.map { "0x" + Self.hex8($0) }.joined(separator: " ")
    }

    /// The colour code alone, as DIAGS prints it: "0x00000002".
    public var colorCodeHex: String { "0x" + Self.hex8(colorCode) }

    /// The variant a `CLCG` / `CLHS` value belongs to, going by its last word
    /// — the colour code. `nil` for an empty value or a code that isn't known.
    public static func variant(forColorWords words: [UInt32]) -> HomePodModelVariant? {
        guard let code = words.last else { return nil }
        return all.first { $0.colorCode == code }
    }

    /// Eight upper-case hex digits, without Foundation's `String(format:)`.
    private static func hex8(_ word: UInt32) -> String {
        let digits = String(word, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }
}
