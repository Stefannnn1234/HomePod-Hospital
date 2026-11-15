import Foundation

// MARK: - "Puffin" audio calibration
//
// "Puffin" is the audio-driver codename for the 1st-gen HomePod (B238). Its
// HAL plug-in, PuffinPlugin.driver, ships four property lists; the two that
// matter for repair are the calibration TEMPLATES:
//
//   PuffinSpeakerCalibration.plist   one entry per driver, each naming the DSP
//                                    "trim" box that receives that driver's
//                                    factory EQ and overall gain
//   PuffinMicCalibration.plist       one entry per microphone, each naming the
//                                    trim box that receives its gain
//
// The templates hold NO per-unit numbers. They only say WHERE the numbers go
// (box name + AUNBandEQ parameter id) and which filter shape each band uses.
// The numbers themselves are measured on the production line and stored in the
// unit's SysCfg:
//
//   SpEQ  tweeter EQ         -> trim0 … trim6
//   WFEQ  woofer EQ          -> wooferTrim
//   MiGa  far-field mic gain -> extMicTrim0 … extMicTrim5
//   SpGa  speaker gain
//
// iBoot copies them into the device tree (calibration-SpEQ / calibration-WFEQ
// on the amp-controller node `audio-nitro`, calibration-MiGa / calibration-SpGa
// on `audio-codec0`) and the plug-in applies them at start-up.
//
// So a tech has two things to compare:
//   1. the SHAPE Apple expects      — this file's `factory` templates
//   2. the VALUES this unit carries — `PuffinUnitCalibration`, decoded from the
//                                     SysCfg payloads the pod reports
//
// What is confirmed and what is inferred:
// - Template structure: read from the ProtoPod plists (B238a internal build).
// - Driver count: the speaker template has EIGHT entries — `wooferTrim` plus
//   `trim0`…`trim6`, i.e. one woofer and SEVEN tweeters. A production unit's
//   SpEQ agrees: 452 bytes = one version word + 7 × 16 words.
// - Mic count: the mic template has SEVEN entries — `intMicTrim` (the internal
//   mic) plus `extMicTrim0`…`extMicTrim5` (the six far-field mics). SysCfg MiGa
//   holds SIX values, so the internal mic appears to have no stored trim.
// - Payload layout (little-endian 32-bit words, word 0 = format version 1, then
//   overall gain + bands of frequency / gain / bandwidth): worked out from one
//   production unit, where it lines up exactly with the template (3 woofer
//   bands, 5 tweeter bands) and decodes to sensible audio frequencies.
// - Units: frequency is plainly Hz. Gain and bandwidth are stored as integers;
//   hundredths (centi-dB, 1/100 octave) is an INFERENCE from their magnitudes.
//   The raw integers are always kept, so nothing depends on that scale.

// MARK: Filter types

/// AUNBandEQ filter types (the values of the template's `FilterType`).
public enum PuffinFilterType: Int, Codable, Sendable, CaseIterable {
    case parametric = 0
    case lowPass = 1
    case highPass = 2
    case resonantLowPass = 3
    case resonantHighPass = 4
    case bandPass = 5
    case bandStop = 6
    case lowShelf = 7
    case highShelf = 8
    case resonantLowShelf = 9
    case resonantHighShelf = 10

    public var title: String {
        switch self {
        case .parametric: return "Parametric"
        case .lowPass: return "Low-pass"
        case .highPass: return "High-pass"
        case .resonantLowPass: return "Resonant low-pass"
        case .resonantHighPass: return "Resonant high-pass"
        case .bandPass: return "Band-pass"
        case .bandStop: return "Band-stop"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        case .resonantLowShelf: return "Resonant low shelf"
        case .resonantHighShelf: return "Resonant high shelf"
        }
    }

    /// Short form for tables: "LS", "HS", "PEQ"…
    public var shortTitle: String {
        switch self {
        case .parametric: return "PEQ"
        case .lowPass, .resonantLowPass: return "LP"
        case .highPass, .resonantHighPass: return "HP"
        case .bandPass: return "BP"
        case .bandStop: return "BS"
        case .lowShelf, .resonantLowShelf: return "LS"
        case .highShelf, .resonantHighShelf: return "HS"
        }
    }
}

// MARK: Templates (the plists)

/// One `{BoxName, ParameterID[, ParameterValue]}` dictionary: a DSP box and the
/// parameter on it that a calibration value is written to. When
/// `parameterValue` is present the value is FIXED by the template (the filter
/// type and the bypass flag); when absent it comes from the unit's calibration.
public struct PuffinParameterRef: Codable, Sendable, Equatable {
    public let boxName: String
    public let parameterID: Int
    public let parameterValue: Double?

    public init(boxName: String, parameterID: Int, parameterValue: Double? = nil) {
        self.boxName = boxName
        self.parameterID = parameterID
        self.parameterValue = parameterValue
    }

    /// The template fixes this parameter; the unit's calibration doesn't set it.
    public var isFixed: Bool { parameterValue != nil }

    enum CodingKeys: String, CodingKey {
        case boxName = "BoxName"
        case parameterID = "ParameterID"
        case parameterValue = "ParameterValue"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boxName = try c.decode(String.self, forKey: .boxName)
        // The shipped plist stores some ids as reals (1001.0), some as integers.
        if let i = try? c.decode(Int.self, forKey: .parameterID) {
            parameterID = i
        } else {
            parameterID = Int(try c.decode(Double.self, forKey: .parameterID).rounded())
        }
        if let d = try? c.decodeIfPresent(Double.self, forKey: .parameterValue) {
            parameterValue = d
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .parameterValue) {
            parameterValue = Double(i)
        } else {
            parameterValue = nil
        }
    }
}

/// One EQ band of a driver's trim box. The five parameters are AUNBandEQ's:
/// bypass 1000+n, filter type 2000+n, frequency 3000+n, gain 4000+n,
/// bandwidth 5000+n (n = band index).
public struct PuffinEQBandTemplate: Codable, Sendable, Equatable {
    public let bandwidth: PuffinParameterRef
    public let bypass: PuffinParameterRef
    public let decibelGain: PuffinParameterRef
    public let filterType: PuffinParameterRef
    public let frequency: PuffinParameterRef

    public init(bandwidth: PuffinParameterRef, bypass: PuffinParameterRef, decibelGain: PuffinParameterRef,
                filterType: PuffinParameterRef, frequency: PuffinParameterRef) {
        self.bandwidth = bandwidth
        self.bypass = bypass
        self.decibelGain = decibelGain
        self.filterType = filterType
        self.frequency = frequency
    }

    enum CodingKeys: String, CodingKey {
        case bandwidth = "Bandwidth"
        case bypass = "Bypass"
        case decibelGain = "DecibelGain"
        case filterType = "FilterType"
        case frequency = "Frequency"
    }

    /// The filter shape the template fixes for this band.
    public var filter: PuffinFilterType? {
        filterType.parameterValue.flatMap { PuffinFilterType(rawValue: Int($0.rounded())) }
    }

    /// The template leaves the band switched on (`Bypass` = 0).
    public var isEnabled: Bool { (bypass.parameterValue ?? 0) == 0 }
}

/// What kind of driver a speaker-template entry is.
public enum PuffinDriverRole: Sendable, Equatable, Hashable {
    case woofer
    /// Zero-based tweeter index (`trim0` … `trim6`).
    case tweeter(Int)

    public var title: String {
        switch self {
        case .woofer: return "Woofer"
        case .tweeter(let n): return "Tweeter \(n + 1)"
        }
    }

    /// The DSP trim box that carries this driver's calibration.
    public var boxName: String {
        switch self {
        case .woofer: return "wooferTrim"
        case .tweeter(let n): return "trim\(n)"
        }
    }

    /// Role for a trim-box name; `nil` for a box that isn't a driver trim.
    public init?(boxName: String) {
        if boxName == "wooferTrim" { self = .woofer; return }
        guard boxName.hasPrefix("trim"), let n = Int(boxName.dropFirst(4)), n >= 0 else { return nil }
        self = .tweeter(n)
    }
}

/// One driver (speaker) entry: its EQ bands and its overall-gain parameter.
public struct PuffinDriverTemplate: Codable, Sendable, Equatable {
    public let eq: [PuffinEQBandTemplate]
    public let overallDecibelGain: PuffinParameterRef

    public init(eq: [PuffinEQBandTemplate], overallDecibelGain: PuffinParameterRef) {
        self.eq = eq
        self.overallDecibelGain = overallDecibelGain
    }

    enum CodingKeys: String, CodingKey {
        case eq = "EQ"
        case overallDecibelGain = "OverallDecibelGain"
    }

    public var boxName: String { overallDecibelGain.boxName }
    public var role: PuffinDriverRole? { PuffinDriverRole(boxName: boxName) }
    public var bandCount: Int { eq.count }
    /// Filter shape of each band, in order.
    public var filters: [PuffinFilterType?] { eq.map(\.filter) }

    /// A driver with `bands` AUNBandEQ bands on `boxName`, laid out the way
    /// the shipped plist is.
    public static func make(boxName: String, filters: [PuffinFilterType]) -> PuffinDriverTemplate {
        let bands = filters.enumerated().map { index, filter in
            PuffinEQBandTemplate(
                bandwidth: PuffinParameterRef(boxName: boxName, parameterID: 5000 + index),
                bypass: PuffinParameterRef(boxName: boxName, parameterID: 1000 + index, parameterValue: 0),
                decibelGain: PuffinParameterRef(boxName: boxName, parameterID: 4000 + index),
                filterType: PuffinParameterRef(boxName: boxName, parameterID: 2000 + index,
                                               parameterValue: Double(filter.rawValue)),
                frequency: PuffinParameterRef(boxName: boxName, parameterID: 3000 + index))
        }
        return PuffinDriverTemplate(eq: bands,
                                    overallDecibelGain: PuffinParameterRef(boxName: boxName, parameterID: 0))
    }
}

/// `PuffinSpeakerCalibration.plist`.
public struct PuffinSpeakerCalibrationTemplate: Codable, Sendable, Equatable {
    public let speakers: [PuffinDriverTemplate]

    public init(speakers: [PuffinDriverTemplate]) { self.speakers = speakers }

    enum CodingKeys: String, CodingKey { case speakers = "Speakers" }

    /// Reads the plist as shipped (binary or XML).
    public init(plist data: Data) throws {
        self = try PropertyListDecoder().decode(PuffinSpeakerCalibrationTemplate.self, from: data)
    }

    public var woofers: [PuffinDriverTemplate] { speakers.filter { $0.role == .woofer } }
    public var tweeters: [PuffinDriverTemplate] {
        speakers.filter { if case .tweeter = $0.role { return true } else { return false } }
    }
    public var driverCount: Int { speakers.count }

    /// The template exactly as the ProtoPod build ships it: `wooferTrim` with
    /// three bands (resonant low shelf, then two parametric), and `trim0` …
    /// `trim6` with five bands each (resonant low shelf, resonant high shelf,
    /// then three parametric). Built in code so the app carries the STRUCTURE
    /// without shipping Apple's file; `PuffinCalibrationTests` checks it
    /// against the real plist when one is available.
    public static let factory = PuffinSpeakerCalibrationTemplate(speakers:
        [PuffinDriverTemplate.make(boxName: "wooferTrim", filters: wooferFilters)]
        + (0..<tweeterCount).map { PuffinDriverTemplate.make(boxName: "trim\($0)", filters: tweeterFilters) })

    public static let tweeterCount = 7
    public static let wooferFilters: [PuffinFilterType] = [.resonantLowShelf, .parametric, .parametric]
    public static let tweeterFilters: [PuffinFilterType] =
        [.resonantLowShelf, .resonantHighShelf, .parametric, .parametric, .parametric]
}

/// One microphone entry: only an overall gain.
public struct PuffinMicTemplate: Codable, Sendable, Equatable {
    public let overallDecibelGain: PuffinParameterRef

    public init(overallDecibelGain: PuffinParameterRef) { self.overallDecibelGain = overallDecibelGain }

    enum CodingKeys: String, CodingKey { case overallDecibelGain = "OverallDecibelGain" }

    public var boxName: String { overallDecibelGain.boxName }
    /// `intMicTrim` — the single internal microphone.
    public var isInternal: Bool { boxName.hasPrefix("intMic") }
    /// `extMicTrimN` — one of the far-field array microphones.
    public var isFarField: Bool { boxName.hasPrefix("extMic") }

    public var title: String {
        if isInternal { return "Internal mic" }
        if isFarField, let n = Int(boxName.dropFirst("extMicTrim".count)) { return "Far-field mic \(n + 1)" }
        return boxName
    }
}

/// `PuffinMicCalibration.plist`.
public struct PuffinMicCalibrationTemplate: Codable, Sendable, Equatable {
    public let mics: [PuffinMicTemplate]

    public init(mics: [PuffinMicTemplate]) { self.mics = mics }

    enum CodingKeys: String, CodingKey { case mics = "Mics" }

    public init(plist data: Data) throws {
        self = try PropertyListDecoder().decode(PuffinMicCalibrationTemplate.self, from: data)
    }

    public var micCount: Int { mics.count }
    public var internalMics: [PuffinMicTemplate] { mics.filter(\.isInternal) }
    public var farFieldMics: [PuffinMicTemplate] { mics.filter(\.isFarField) }

    public static let farFieldCount = 6

    /// As shipped: `intMicTrim`, then `extMicTrim0` … `extMicTrim5`.
    public static let factory = PuffinMicCalibrationTemplate(mics:
        [PuffinMicTemplate(overallDecibelGain: PuffinParameterRef(boxName: "intMicTrim", parameterID: 0))]
        + (0..<farFieldCount).map {
            PuffinMicTemplate(overallDecibelGain: PuffinParameterRef(boxName: "extMicTrim\($0)", parameterID: 0))
        })
}

// MARK: Power parameter mapping

/// `PuffinPowerParameterMapping.plist`: how the audio limiters tighten as the
/// system's "control effort" (0 = unconstrained, 1 = maximum power/thermal
/// throttling) rises. Not per-unit data, but it explains a symptom techs hear:
/// a unit that is running hot or power-limited loses bass and peak level BY
/// DESIGN, which is easy to mistake for a failing woofer or amp.
public struct PuffinPowerParameterMapping: Sendable, Equatable {
    public struct Point: Codable, Sendable, Equatable {
        public let controlEffort: Double
        public let parameterValue: Double

        public init(controlEffort: Double, parameterValue: Double) {
            self.controlEffort = controlEffort
            self.parameterValue = parameterValue
        }

        enum CodingKeys: String, CodingKey {
            case controlEffort = "ControlEffort"
            case parameterValue = "ParameterValue"
        }
    }

    public struct Curve: Codable, Sendable, Equatable, Identifiable {
        /// Plist key, e.g. "BassKoenig Excursion".
        public var name: String
        /// Four-character DSP parameter code, e.g. "xlim".
        public let parameterID: String
        public let points: [Point]

        public var id: String { name }

        public init(name: String, parameterID: String, points: [Point]) {
            self.name = name
            self.parameterID = parameterID
            self.points = points
        }

        enum CodingKeys: String, CodingKey {
            case parameterID = "ParameterID"
            case points = "Points"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = ""
            parameterID = try c.decode(String.self, forKey: .parameterID)
            points = try c.decode([Point].self, forKey: .points)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(parameterID, forKey: .parameterID)
            try c.encode(points, forKey: .points)
        }

        /// Linear interpolation between the points; clamped at both ends.
        public func value(atControlEffort effort: Double) -> Double? {
            let sorted = points.sorted { $0.controlEffort < $1.controlEffort }
            guard let first = sorted.first, let last = sorted.last else { return nil }
            if effort <= first.controlEffort { return first.parameterValue }
            if effort >= last.controlEffort { return last.parameterValue }
            for (a, b) in zip(sorted, sorted.dropFirst()) where effort <= b.controlEffort {
                let span = b.controlEffort - a.controlEffort
                guard span > 0 else { return b.parameterValue }
                return a.parameterValue + (b.parameterValue - a.parameterValue) * (effort - a.controlEffort) / span
            }
            return last.parameterValue
        }

        /// What the curve means for someone listening to the unit.
        public var meaning: String {
            switch parameterID {
            case "xlim": return "Woofer excursion limit — how far the cone is allowed to travel."
            case "whsf": return "Bass limiter start frequency — bass below this is progressively reduced."
            case "ingn": return "Input gain trim ahead of the limiters (dB)."
            case "wltc": return "Woofer peak-power limit."
            default: return "DSP parameter \(parameterID)."
            }
        }
    }

    public let curves: [Curve]

    public init(curves: [Curve]) { self.curves = curves }

    public init(plist data: Data) throws {
        let raw = try PropertyListDecoder().decode([String: Curve].self, from: data)
        curves = raw.keys.sorted().map { key in
            var curve = raw[key]!
            curve.name = key
            return curve
        }
    }

    public func curve(parameterID: String) -> Curve? { curves.first { $0.parameterID == parameterID } }

    private static func curve(_ name: String, _ id: String, _ pairs: [(Double, Double)]) -> Curve {
        Curve(name: name, parameterID: id, points: pairs.map { Point(controlEffort: $0.0, parameterValue: $0.1) })
    }

    /// As shipped in the ProtoPod build.
    public static let factory = PuffinPowerParameterMapping(curves: [
        curve("BassKoenig Excursion", "xlim", [(0, 8), (0.4, 6.7), (0.7, 5.7), (1, 5)]),
        curve("BassKoenig Start Freq", "whsf", [(0, 30), (0.4, 50.5), (0.7, 70), (1, 80)]),
        curve("ControlFreak Input Gain", "ingn", [(0, 0), (0.7, 0.05), (0.8, -0.5), (0.9, -1.4), (1, -4)]),
        curve("PeakPowerGuard Limit @ TC", "wltc", [(0, 54), (0.3, 38), (0.7, 24), (1, 18.2)]),
    ])
}

// MARK: DSP database

/// `PuffinDSPDatabase.plist`: which DSP graph and tuning strips the plug-in
/// loads for each operating mode. The useful part for diagnosis is the list of
/// modes — it shows that the speaker tuning depends on the stereo ROLE and the
/// room POSITION the unit detected, and that separate "Calibration",
/// "Measurement" and "Raw" graphs exist for factory use.
public struct PuffinDSPDatabase: Sendable, Equatable {
    public enum Direction: String, Sendable, Equatable, CaseIterable {
        case input = "PuffinInput"
        case output = "PuffinOutput"
    }

    public struct Tuning: Sendable, Equatable, Identifiable {
        public let direction: Direction
        /// Plist key, e.g. "Stereo Left Wall".
        public let name: String
        /// `DSPDeviceProperties` selectors: "mode", "role", "posi", "cali".
        public let properties: [String: String]
        /// Graph / strip files, in load order.
        public let files: [String]

        public var id: String { "\(direction.rawValue)/\(name)" }
        /// "defa" default, "meas" measurement, "raww" raw, "tphn" telephony.
        public var mode: String? { properties["mode"] }
        /// "solo", "stereoleft", "stereoright".
        public var role: String? { properties["role"] }
        /// "free" (open space), "wall", "book" (bookshelf).
        public var position: String? { properties["posi"] }
        /// The factory-calibration variant of the graph.
        public var isCalibration: Bool { properties["cali"] == "1" }

        public init(direction: Direction, name: String, properties: [String: String], files: [String]) {
            self.direction = direction
            self.name = name
            self.properties = properties
            self.files = files
        }
    }

    /// Board the database is for, e.g. "b238a".
    public let board: String
    public let tunings: [Tuning]

    public init(board: String, tunings: [Tuning]) {
        self.board = board
        self.tunings = tunings
    }

    public var inputs: [Tuning] { tunings.filter { $0.direction == .input } }
    public var outputs: [Tuning] { tunings.filter { $0.direction == .output } }

    /// Reads the plist as shipped. Unknown shapes are skipped, not fatal.
    public init(plist data: Data) throws {
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let board = root.keys.sorted().first, let devices = root[board] as? [String: Any] else {
            throw PuffinCalibrationError.malformedPlist("PuffinDSPDatabase: no board dictionary")
        }
        var out: [Tuning] = []
        for direction in Direction.allCases {
            guard let modes = devices[direction.rawValue] as? [String: Any] else { continue }
            for name in modes.keys.sorted() {
                guard let mode = modes[name] as? [String: Any] else { continue }
                var properties: [String: String] = [:]
                for entry in (mode["DSPDeviceProperties"] as? [[String: Any]]) ?? [] {
                    guard let selector = entry["Selector"] as? String else { continue }
                    if let s = entry["Value"] as? String { properties[selector] = s }
                    else if let n = entry["Value"] as? NSNumber { properties[selector] = n.stringValue }
                }
                var files: [String] = []
                for key in ["Input", "Output"] {
                    for stage in (mode[key] as? [[String: Any]]) ?? [] {
                        for hardware in (stage["Hardware"] as? [[String: Any]]) ?? [] {
                            if let path = hardware["Path"] as? String { files.append(path) }
                        }
                    }
                }
                out.append(Tuning(direction: direction, name: name, properties: properties, files: files))
            }
        }
        self.board = board
        self.tunings = out
    }
}

// MARK: - Unit calibration (SysCfg payloads)

public enum PuffinCalibrationError: Error, LocalizedError, Equatable {
    case malformedPlist(String)
    /// Not a whole number of 32-bit words, or too short to hold a version word.
    case truncated(tag: String, bytes: Int)
    /// Every byte 0x00 or every byte 0xFF: erased / never-written flash.
    case blank(tag: String)
    /// The payload doesn't divide into whole units of the expected size.
    case unexpectedSize(tag: String, bytes: Int, expected: Int)

    public var errorDescription: String? {
        switch self {
        case .malformedPlist(let why): return why
        case .truncated(let tag, let bytes): return "\(tag) is \(bytes) bytes — too short or not a whole number of 32-bit words."
        case .blank(let tag): return "\(tag) is blank (erased flash) — the unit has no factory value for it."
        case .unexpectedSize(let tag, let bytes, let expected):
            return "\(tag) is \(bytes) bytes; the factory layout is \(expected) bytes."
        }
    }
}

/// The four SysCfg tags that carry Puffin's per-unit audio calibration.
public enum PuffinCalibrationTag: String, Codable, Sendable, CaseIterable, Identifiable {
    case speakerEQ = "SpEQ"
    case wooferEQ = "WFEQ"
    case micGain = "MiGa"
    case speakerGain = "SpGa"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .speakerEQ: return "Tweeter EQ"
        case .wooferEQ: return "Woofer EQ"
        case .micGain: return "Mic Gain"
        case .speakerGain: return "Speaker Gain"
        }
    }

    /// Payload size on a factory-calibrated production unit.
    public var expectedBytes: Int {
        switch self {
        case .speakerEQ: return 4 + PuffinSpeakerCalibrationTemplate.tweeterCount * PuffinUnitCalibration.tweeterWords * 4   // 452
        case .wooferEQ: return 4 + PuffinUnitCalibration.wooferWords * 4                                                      // 44
        case .micGain: return 4 + PuffinMicCalibrationTemplate.farFieldCount * 4                                              // 28
        case .speakerGain: return 16
        }
    }

    /// Device-tree property iBoot fills from this tag, and the node it is on.
    public var deviceTreeProperty: (node: String, property: String) {
        switch self {
        case .speakerEQ: return ("audio-nitro", "calibration-SpEQ")
        case .wooferEQ: return ("audio-nitro", "calibration-WFEQ")
        case .micGain: return ("audio-codec0", "calibration-MiGa")
        case .speakerGain: return ("audio-codec0", "calibration-SpGa")
        }
    }

    /// What a customer notices when the tag is missing.
    public var consequence: String {
        switch self {
        case .speakerEQ:
            return "The seven tweeters play without their individual factory correction — beam-forming and tonal balance are off, most audibly in the treble."
        case .wooferEQ:
            return "The woofer plays without its factory correction — bass level and tuning are generic rather than matched to this driver."
        case .micGain:
            return "The six far-field microphones aren't level-matched — \"Hey Siri\" pickup and room sensing get less reliable."
        case .speakerGain:
            return "The overall speaker level trim is missing."
        }
    }
}

/// One calibrated EQ band as the unit stores it.
public struct PuffinEQBandValue: Sendable, Equatable {
    public let index: Int
    /// Centre / corner frequency in Hz.
    public let frequencyHz: Int
    /// Gain exactly as stored (signed integer).
    public let gainRaw: Int
    /// Bandwidth exactly as stored (integer).
    public let bandwidthRaw: Int
    /// Filter shape, from the template.
    public let filter: PuffinFilterType?

    public init(index: Int, frequencyHz: Int, gainRaw: Int, bandwidthRaw: Int, filter: PuffinFilterType?) {
        self.index = index
        self.frequencyHz = frequencyHz
        self.gainRaw = gainRaw
        self.bandwidthRaw = bandwidthRaw
        self.filter = filter
    }

    /// Gain in dB, ASSUMING hundredths of a dB (see the file header).
    public var gainDB: Double { Double(gainRaw) / PuffinUnitCalibration.inferredScale }
    /// Bandwidth, ASSUMING hundredths (see the file header).
    public var bandwidth: Double { Double(bandwidthRaw) / PuffinUnitCalibration.inferredScale }

    /// A band no real driver calibration would contain.
    public var isPlausible: Bool {
        (PuffinUnitCalibration.plausibleFrequencyHz).contains(frequencyHz)
            && abs(gainRaw) <= PuffinUnitCalibration.plausibleGainRawLimit
            && bandwidthRaw > 0
    }

    /// "LS 500 Hz −0.96 dB bw 0.70".
    public var summary: String {
        let shape = filter?.shortTitle ?? "band \(index + 1)"
        return "\(shape) \(frequencyHz) Hz \(PuffinUnitCalibration.signedText(gainDB)) dB bw \(PuffinUnitCalibration.fixed(bandwidth))"
    }
}

/// One driver's calibration as the unit stores it.
public struct PuffinDriverCalibration: Sendable, Equatable, Identifiable {
    public let role: PuffinDriverRole
    /// Overall gain exactly as stored (signed integer).
    public let overallGainRaw: Int
    public let bands: [PuffinEQBandValue]

    public init(role: PuffinDriverRole, overallGainRaw: Int, bands: [PuffinEQBandValue]) {
        self.role = role
        self.overallGainRaw = overallGainRaw
        self.bands = bands
    }

    public var id: String { role.boxName }
    public var boxName: String { role.boxName }
    /// Overall gain in dB, ASSUMING hundredths of a dB.
    public var overallGainDB: Double { Double(overallGainRaw) / PuffinUnitCalibration.inferredScale }
    public var isPlausible: Bool {
        abs(overallGainRaw) <= PuffinUnitCalibration.plausibleGainRawLimit && bands.allSatisfy(\.isPlausible)
    }
    /// Every stored value is zero: a placeholder entry, not a measurement.
    public var isAllZero: Bool {
        overallGainRaw == 0 && bands.allSatisfy { $0.frequencyHz == 0 && $0.gainRaw == 0 && $0.bandwidthRaw == 0 }
    }
}

/// A unit's audio calibration, decoded from its SysCfg payloads.
///
/// Every payload is little-endian 32-bit words; word 0 is a format version (1
/// on the units seen). Signed values are stored as a 16-bit two's-complement
/// number in the low half of the word (−96 is `A0 FF 00 00`).
public struct PuffinUnitCalibration: Sendable, Equatable {
    /// Words per tweeter in SpEQ: overall gain + 5 × (frequency, gain, bandwidth).
    public static let tweeterWords = 1 + PuffinSpeakerCalibrationTemplate.tweeterFilters.count * 3
    /// Words for the woofer in WFEQ: overall gain + 3 × (frequency, gain, bandwidth).
    public static let wooferWords = 1 + PuffinSpeakerCalibrationTemplate.wooferFilters.count * 3
    /// The only format version seen so far.
    public static let knownVersion = 1
    /// Divisor that turns stored gain / bandwidth integers into dB / bandwidth.
    /// INFERRED from value magnitudes, not documented by Apple.
    public static let inferredScale = 100.0
    /// Audio band; a calibration frequency outside it is corrupt data.
    public static let plausibleFrequencyHz = 20...24_000
    /// ±24 dB at the inferred scale — far beyond any real trim.
    public static let plausibleGainRawLimit = 2_400

    /// SpEQ: one entry per tweeter, `trim0` first.
    public var tweeters: [PuffinDriverCalibration] = []
    /// WFEQ.
    public var woofer: PuffinDriverCalibration?
    /// MiGa: one stored value per far-field mic, `extMicTrim0` first.
    public var micGainsRaw: [Int] = []
    /// SpGa: the single non-zero value it carries.
    public var speakerGainRaw: Int?
    /// Format version of each payload that was decoded.
    public var versions: [PuffinCalibrationTag: Int] = [:]
    /// Why a payload that was offered could not be decoded.
    public var failures: [PuffinCalibrationTag: PuffinCalibrationError] = [:]

    public init() {}

    /// Decodes whichever payloads are supplied. A payload that can't be decoded
    /// is recorded in `failures`; it never throws away the others.
    public init(payloads: [PuffinCalibrationTag: Data]) {
        for tag in PuffinCalibrationTag.allCases {
            guard let data = payloads[tag] else { continue }
            do {
                switch tag {
                case .speakerEQ:
                    let (version, drivers) = try Self.decodeSpeakerEQ(data)
                    tweeters = drivers
                    versions[tag] = version
                case .wooferEQ:
                    let (version, driver) = try Self.decodeWooferEQ(data)
                    woofer = driver
                    versions[tag] = version
                case .micGain:
                    let (version, gains) = try Self.decodeMicGain(data)
                    micGainsRaw = gains
                    versions[tag] = version
                case .speakerGain:
                    let (version, gain) = try Self.decodeSpeakerGain(data)
                    speakerGainRaw = gain
                    versions[tag] = version
                }
            } catch let error as PuffinCalibrationError {
                failures[tag] = error
            } catch {
                failures[tag] = .truncated(tag: tag.rawValue, bytes: data.count)
            }
        }
    }

    /// Drivers that carry calibration: woofer first, then the tweeters.
    public var drivers: [PuffinDriverCalibration] { (woofer.map { [$0] } ?? []) + tweeters }
    public var driverCount: Int { drivers.count }
    public var micCount: Int { micGainsRaw.count }
    public var isEmpty: Bool { drivers.isEmpty && micGainsRaw.isEmpty && speakerGainRaw == nil }

    /// Mic gains ASSUMING hundredths — on the unit seen they sit around 1.0
    /// (0.73 … 1.07), i.e. they read like linear level-matching factors.
    public var micGains: [Double] { micGainsRaw.map { Double($0) / Self.inferredScale } }

    // MARK: Payload decoders

    /// SpEQ → (version, tweeters). Any whole number of tweeters is accepted so
    /// a unit that differs from the template is REPORTED rather than rejected.
    public static func decodeSpeakerEQ(_ data: Data) throws -> (version: Int, tweeters: [PuffinDriverCalibration]) {
        let words = try self.words(data, tag: .speakerEQ)
        let body = Array(words.dropFirst())
        guard !body.isEmpty, body.count % tweeterWords == 0 else {
            throw PuffinCalibrationError.unexpectedSize(tag: "SpEQ", bytes: data.count,
                                                        expected: PuffinCalibrationTag.speakerEQ.expectedBytes)
        }
        let filters = PuffinSpeakerCalibrationTemplate.tweeterFilters
        let drivers = (0..<(body.count / tweeterWords)).map { index in
            driver(.tweeter(index), words: Array(body[(index * tweeterWords)..<((index + 1) * tweeterWords)]), filters: filters)
        }
        return (signed(words[0]), drivers)
    }

    /// WFEQ → (version, woofer).
    public static func decodeWooferEQ(_ data: Data) throws -> (version: Int, woofer: PuffinDriverCalibration) {
        let words = try self.words(data, tag: .wooferEQ)
        let body = Array(words.dropFirst())
        guard body.count == wooferWords else {
            throw PuffinCalibrationError.unexpectedSize(tag: "WFEQ", bytes: data.count,
                                                        expected: PuffinCalibrationTag.wooferEQ.expectedBytes)
        }
        return (signed(words[0]), driver(.woofer, words: body, filters: PuffinSpeakerCalibrationTemplate.wooferFilters))
    }

    /// MiGa → (version, one stored gain per far-field mic).
    public static func decodeMicGain(_ data: Data) throws -> (version: Int, gains: [Int]) {
        let words = try self.words(data, tag: .micGain)
        guard words.count >= 2 else {
            throw PuffinCalibrationError.unexpectedSize(tag: "MiGa", bytes: data.count,
                                                        expected: PuffinCalibrationTag.micGain.expectedBytes)
        }
        return (signed(words[0]), words.dropFirst().map(signed))
    }

    /// SpGa → (version, gain). A 16-byte inline entry: version, gain, padding.
    public static func decodeSpeakerGain(_ data: Data) throws -> (version: Int, gain: Int) {
        let words = try self.words(data, tag: .speakerGain)
        guard words.count >= 2 else {
            throw PuffinCalibrationError.unexpectedSize(tag: "SpGa", bytes: data.count,
                                                        expected: PuffinCalibrationTag.speakerGain.expectedBytes)
        }
        return (signed(words[0]), signed(words[1]))
    }

    private static func driver(_ role: PuffinDriverRole, words: [UInt32], filters: [PuffinFilterType]) -> PuffinDriverCalibration {
        let bandCount = (words.count - 1) / 3
        let bands = (0..<bandCount).map { index in
            PuffinEQBandValue(index: index,
                              frequencyHz: signed(words[1 + index * 3]),
                              gainRaw: signed(words[2 + index * 3]),
                              bandwidthRaw: signed(words[3 + index * 3]),
                              filter: index < filters.count ? filters[index] : nil)
        }
        return PuffinDriverCalibration(role: role, overallGainRaw: signed(words[0]), bands: bands)
    }

    /// Little-endian 32-bit words; rejects blank and ragged payloads.
    static func words(_ data: Data, tag: PuffinCalibrationTag) throws -> [UInt32] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes.count % 4 == 0 else {
            throw PuffinCalibrationError.truncated(tag: tag.rawValue, bytes: bytes.count)
        }
        if bytes.allSatisfy({ $0 == 0x00 }) || bytes.allSatisfy({ $0 == 0xFF }) {
            throw PuffinCalibrationError.blank(tag: tag.rawValue)
        }
        return stride(from: 0, to: bytes.count, by: 4).map { i in
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
    }

    /// A stored word as a signed number: 16-bit two's complement when it fits
    /// in the low half (the usual case), 32-bit two's complement otherwise.
    static func signed(_ word: UInt32) -> Int {
        word <= 0xFFFF ? Int(Int16(truncatingIfNeeded: word)) : Int(Int32(bitPattern: word))
    }

    // MARK: Formatting

    /// "+0.37", "−0.96", "0.00" — two decimals, explicit sign.
    static func signedText(_ value: Double) -> String {
        let text = fixed(abs(value))
        if value > 0, text != "0.00" { return "+" + text }
        if value < 0, text != "0.00" { return "−" + text }
        return text
    }

    /// Two decimals, locale-independent.
    static func fixed(_ value: Double) -> String {
        let hundredths = Int((value * 100).rounded())
        let sign = hundredths < 0 ? "-" : ""
        let magnitude = abs(hundredths)
        let fraction = magnitude % 100
        return "\(sign)\(magnitude / 100).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    // MARK: Hex

    /// Bytes from a plain hex string ("0100ff…"); `nil` when it isn't one.
    public static func data(hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var out = Data(capacity: digits.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var i = 0
        while i < digits.count {
            guard let hi = nibble(digits[i]), let lo = nibble(digits[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }
}
