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
// - `.firmwareAudit`  The command NAME was found in the DIAGS image, but no
//                     usage line has been captured. These entries say so and
//                     carry no invented options.
//
// Every entry also carries a `risk`. Most DIAGS commands only read, but a few
// write the unit's identity (`syscfg add`, `sn`) or wipe it (`syscfg init`),
// and the card must make that impossible to miss.

/// One DIAGS shell command.
public struct DiagsCommand: Sendable, Equatable, Identifiable {
    public enum Category: String, Sendable, CaseIterable, Identifiable {
        case sysCfg, audio, radio, nand, sensor, power, led, input, deviceInfo, storage, shell

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
            case .storage: return "Storage"
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
            case .power: return "Read the power-management chip: rails, ADC channels, temperatures."
            case .led: return "Drive the top LED array directly — a quick check of the LED board."
            case .input: return "Check the touch surface and its buttons."
            case .deviceInfo: return "What the board says it is."
            case .storage: return "Block devices as DIAGS sees them."
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

        public var title: String {
            switch self {
            case .readOnly: return "Read-only"
            case .changesState: return "Changes live state"
            case .writesFlash: return "Writes to flash"
            case .unknown: return "Effect not confirmed"
            }
        }
    }

    /// Where the entry's syntax comes from.
    public enum Source: Sendable, Equatable {
        /// Appears verbatim in this extracted Apple factory script.
        case factoryScript(String)
        /// Used and documented in this project (docs/diags-boot.md).
        case projectNotes
        /// Name found in the DIAGS image; usage not captured.
        case firmwareAudit

        public var title: String {
            switch self {
            case .factoryScript(let name): return "Apple factory script: \(name)"
            case .projectNotes: return "Project notes (docs/diags-boot.md)"
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
        "Usage not captured yet. Try `help` or `<command> --help` at the prompt and note what it prints."

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

    // MARK: Commands

    public static let all: [DiagsCommand] = sysCfg + audio + radio + nand + sensor + power + led + input + deviceInfo + storage + shell

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
        C(name: "ampcontroller", category: .audio, syntax: ["ampcontroller -s [TEMP]"],
          summary: "Talks to the amp controller MCU. The factory thermal script reads its temperature sensor this way.",
          examples: [E("ampcontroller -s [TEMP]", "Amp controller temperature. A reading at all proves the MCU is alive and answering.")],
          risk: .readOnly, source: sochot,
          repairUse: "A live temperature reading is a cheap proof that the amp board is powered and its serial link works.",
          ramdiskEquivalent: .audio),
        audited("playaudio", .audio, "Plays a test signal through the speakers.", risk: .changesState,
                repairUse: "The audible speaker test the ramdisk can't do. Run the audio reset recipe first."),
        audited("recordaudio", .audio, "Records from the microphones.", risk: .changesState,
                repairUse: "The working-microphone test the ramdisk can't do."),
        audited("loopaudio", .audio, "Loops recorded audio back to the speakers.", risk: .changesState),
        audited("stopaudio", .audio, "Stops a play / record / loop that is running.", risk: .changesState),
    ]

    static let radio: [DiagsCommand] = [
        C(name: "wifi", category: .radio, syntax: ["wifi --send_cmd <command> [args]", "wifi --send_cmd calload <file>"],
          summary: "Sends a command to the Wi-Fi chip. The factory loads the unit's own calibration by saving SysCfg WCAL to a file and passing it to `calload`.",
          examples: [E("wifi --send_cmd calload nandfs:\\AppleInternal\\Diags\\WiFiFirmware\\WCAL.bin",
                       "Load a calibration file into the chip. The file is the WCAL value with each 32-bit word byte-swapped back to its original order.")],
          risk: .changesState, source: connectivity,
          repairUse: "If this fails on a unit whose WCAL is present, the Wi-Fi module itself is suspect rather than its calibration.",
          ramdiskEquivalent: .radio),
        C(name: "bluetooth", category: .radio, syntax: ["bluetooth --send_raw \"<hex bytes>\""],
          summary: "Sends a raw HCI command to the Bluetooth chip. The factory loads BCAL in 230-byte chunks with the vendor command 01 97 FD E9, three sections, counting the remaining chunks down to zero.",
          examples: [E("bluetooth --send_raw \"01 97 FD E9 03 <chunks left> 00 <230 data bytes>\"",
                       "One calibration chunk. The last chunk is zero-padded to 230 bytes.")],
          risk: .changesState, source: connectivity,
          repairUse: "A chip that accepts raw HCI commands is alive; one that never answers points at the module or its UART.",
          ramdiskEquivalent: .radio),
    ]

    static let nand: [DiagsCommand] = [
        audited("nand", .nand, "General NAND information and tests.", ramdiskEquivalent: .nand),
        audited("NANDInfoTool", .nand, "Detailed NAND report: chip IDs, PPN firmware version, unique IDs, geometry.", risk: .readOnly,
                repairUse: "Record it at intake and again after a NAND swap — the chip ID and unique ID tell you which chip is on the board.",
                ramdiskEquivalent: .nand),
        audited("nandcsid", .nand, "Reads the NAND chip ID.", risk: .readOnly,
                repairUse: "Confirms a replacement chip is the part you meant to fit.", ramdiskEquivalent: .nand),
        audited("nanduid", .nand, "Reads the NAND's unique ID.", risk: .readOnly,
                repairUse: "The ID changes with the chip, so it proves whether the NAND has been replaced.", ramdiskEquivalent: .nand),
        audited("nandsize", .nand, "Reports the NAND capacity.", risk: .readOnly, ramdiskEquivalent: .nand),
    ]

    static let sensor: [DiagsCommand] = [
        C(name: "temperature", category: .sensor, syntax: ["temperature --all"],
          summary: "Reads the temperature sensors. `--all` reads every one.",
          examples: [E("temperature --all", "Every sensor in one go — the first line of Apple's SoC thermal script.")],
          risk: .readOnly, source: sochot,
          repairUse: "A sensor that reads absurdly high or low, or is missing from the list, locates an open flex or a dead sensor.",
          ramdiskEquivalent: .thermal),
        C(name: "sensor", category: .sensor, syntax: ["sensor -s <sensor> --get <value>"],
          summary: "Reads one value from a named sensor. The factory reads the touch controller's temperature this way.",
          examples: [E("sensor -s touch --get temp", "Touch-controller temperature. An answer proves the top touch board is connected.")],
          risk: .readOnly, source: sochot,
          repairUse: "Quick continuity check of the top (touch / LED) board."),
        audited("thermalmonitor", .sensor, "Monitors temperatures over time.", risk: .readOnly, ramdiskEquivalent: .thermal),
    ]

    static let power: [DiagsCommand] = [
        C(name: "pmutemp", category: .power, syntax: ["pmutemp --read all"],
          summary: "Reads the power-management chip's temperature sensors.",
          examples: [E("pmutemp --read all", "All PMU temperature channels.")],
          risk: .readOnly, source: sochot,
          repairUse: "A hot PMU at idle points at a shorted rail.", ramdiskEquivalent: .power),
        audited("pmuadc", .power, "Reads the PMU's ADC channels (voltages and currents).", risk: .readOnly,
                repairUse: "Rail voltages without a multimeter.", ramdiskEquivalent: .power),
        audited("pmustat", .power, "PMU status.", risk: .readOnly, ramdiskEquivalent: .power),
        audited("pmureg", .power, "Reads — and may write — raw PMU registers."),
    ]

    static let led: [DiagsCommand] = [
        C(name: "strobe", category: .led, syntax: ["strobe -c led --power off", "strobe -c led -s <set> --set <colour> <level>"],
          summary: "Drives the top LED array. `-s All_RGB` addresses every LED; the level is a brightness.",
          examples: [
            E("strobe -c led -s All_RGB --set red 25", "All LEDs red at level 25. Repeat with green and blue to find a dead colour channel."),
            E("strobe -c led --power off", "LEDs off."),
          ],
          risk: .changesState, source: sochot,
          repairUse: "Lights the whole LED board one colour at a time — dead LEDs and dead channels are obvious."),
    ]

    static let input: [DiagsCommand] = [
        audited("button", .input, "Button test.", repairUse: "The place to start for a top surface that ignores + / − or centre taps."),
        audited("buttoncnt", .input, "Listed with the button tests (by its name, a press counter); function not confirmed."),
        audited("key", .input, "Listed with the button tests; function not confirmed."),
        audited("mbt", .input, "Listed with the touch / button tests; function not confirmed."),
    ]

    static let deviceInfo: [DiagsCommand] = [
        audited("sysinfo", .deviceInfo, "System summary.", risk: .readOnly),
        audited("system", .deviceInfo, "Listed with the system-information commands; function not confirmed."),
        audited("version", .deviceInfo, "DIAGS build version.", risk: .readOnly),
        audited("chipid", .deviceInfo, "SoC chip ID.", risk: .readOnly),
        audited("boardid", .deviceInfo, "Board ID.", risk: .readOnly),
        audited("boardrev", .deviceInfo, "Board revision.", risk: .readOnly),
    ]

    static let storage: [DiagsCommand] = [
        audited("blockdevice", .storage, "Lists the block devices DIAGS can see.", risk: .readOnly, ramdiskEquivalent: .partmap),
    ]

    static let shell: [DiagsCommand] = [
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
