import Foundation

// MARK: - Diagnostic commands
//
// The pod-side command strings, in one place (like
// `SSHRamdiskTransport.writeProbeCommand`). The tool LOGIC lives in the
// `hpdiag-*` scripts shipped in the ramdisk overlay (/usr/local/bin), not in
// Swift string literals — so the brittle ioreg patterns can be fixed by
// rebuilding the overlay, without recompiling the app.
//
// A ramdisk built before a script existed (or before it was last changed)
// doesn't have to be rebuilt either: the app pushes the scripts it carries into
// `pushDirectory` on the pod's tmpfs before a run (see
// `FullDiagnosticsController.pushDiagnosticScripts`), and `path` STARTS with
// that directory, so the app's current copies win over whatever an older
// ramdisk has baked in. That ordering is a safety property, not a convenience:
// early script revisions dumped the whole registry (`ioreg -l`), which
// kernel-panics the pod, and a ramdisk built back then still carries them.
//
// The diagnostic commands are read-only. The only writes are the script push,
// and that touches nothing but the ramdisk's RAM-backed /private/var/tmp.

/// One pod-side script the app can push to the ramdisk: its bare file name
/// (`hpdiag-nand`) and its bytes. Core never reads the app bundle — the app
/// layer loads these and hands them in.
public struct DiagScript: Sendable, Equatable {
    public let name: String
    public let content: Data

    public init(name: String, content: Data) {
        self.name = name
        self.content = content
    }

    public init(name: String, text: String) {
        self.init(name: name, content: Data(text.utf8))
    }

    /// Only plain `hpdiag-…` names are ever spliced into a pod-side command.
    public var hasSafeName: Bool {
        guard name.hasPrefix("hpdiag-"), name.count > "hpdiag-".count, name.count <= 64 else { return false }
        return name.unicodeScalars.allSatisfy { c in
            (c.value >= 97 && c.value <= 122) || (c.value >= 48 && c.value <= 57) || c == "-" || c == "_"
        }
    }
}

public enum DiagCommands {
    public static let nand = "hpdiag-nand"
    public static let partmap = "hpdiag-partmap"
    public static let factory = "hpdiag-factory"
    public static let thermal = "hpdiag-thermal"
    public static let power = "hpdiag-power"
    public static let radio = "hpdiag-radio"
    public static let audio = "hpdiag-audio"
    public static let mic = "hpdiag-mic"
    public static let accel = "hpdiag-accel"
    /// One-shot: runs every tool on the pod and prints a single
    /// `{"serial":…,"timestamp":…,"tools":[…],"overall":…}` document.
    public static let full = "hpdiag-full"

    /// Sentinels framing each tool's JSON so it can be carved out of SSH
    /// banners and stderr noise (same idea as the SysCfg base64 markers).
    public static let beginMarker = "===HPDIAG_JSON_BEGIN==="
    public static let endMarker = "===HPDIAG_JSON_END==="
    /// Followed by the script's exit status and a closing `===`.
    public static let exitMarkerPrefix = "===HPDIAG_EXIT="

    /// Where the app pushes its scripts, first choice. RAM-backed, gone on reboot.
    /// The SSH ramdisk's root has NO /tmp (the 17.5 restore ramdisk carries
    /// /private/var/tmp and /private/var/root only), so nothing here uses /tmp.
    public static let pushDirectory = "/private/var/tmp/hpdiag"

    /// Every place the scripts may be pushed, in order of preference; the
    /// first one the pod lets us write to is used (`scriptCheck` reports it).
    public static let pushDirectories = [pushDirectory, "/private/var/root/hpdiag"]

    /// What the ramdisk itself provides. Neither `ioreg` nor /usr/local/bin
    /// (where baked-in scripts live) is on dropbear's default PATH.
    public static let basePath = "/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin:/usr/local/sbin"

    /// PATH for the non-interactive SSH session: the scripts the app pushed
    /// FIRST (always the current revision), then the ramdisk's own directories
    /// (used when nothing was pushed).
    public static let path = pushDirectories.joined(separator: ":") + ":" + basePath

    // MARK: Script push

    /// Line prefixes in the output of `scriptCheck` / `scriptPushCommands`.
    public static let haveMarkerPrefix = "HPDIAG_HAVE "
    public static let stampMarkerPrefix = "HPDIAG_STAMP "
    public static let pushedMarkerPrefix = "HPDIAG_PUSHED "

    /// Records which set of scripts was last pushed into `directory`, so a
    /// second run on the same boot doesn't push them again.
    public static func stampFile(in directory: String) -> String { directory + "/.stamp" }

    /// Printed by `scriptCheck`: `HPDIAG_DIR <directory>` — the push directory
    /// to use (empty when none of `pushDirectories` is writable).
    public static let dirMarkerPrefix = "HPDIAG_DIR "
    /// Printed by `scriptCheck` when it had to remount the ramdisk's root
    /// read-write to get a writable directory.
    public static let remountMarker = "HPDIAG_REMOUNT"

    /// Prepares and inspects the pod. Prints, in this order:
    /// `HPDIAG_DIR <dir>` — the first of `pushDirectories` that could be
    /// created and written to. If none can, the ramdisk's root (RAM only, not
    /// NAND) is remounted read-write and they are tried once more;
    /// `HPDIAG_HAVE <name>` for each script the ramdisk already carries
    /// (found on `basePath`, i.e. NOT counting earlier pushes);
    /// `HPDIAG_LACK <tool>` for each tool the scripts need that is absent;
    /// `HPDIAG_STAMP <fingerprint>` of the last push there (empty if none).
    /// Nothing but the push directory (and an empty `.w` probe file in it) is
    /// created. `names` must already be validated (`DiagScript.hasSafeName`).
    public static func scriptCheck(names: [String]) -> String {
        let list = names.joined(separator: " ")
        return "PATH=\(basePath); export PATH; d=; "
            + "pick() { for c in \(pushDirectories.joined(separator: " ")); do "
            + "if mkdir -p \"$c\" 2>/dev/null && { : >> \"$c/.w\"; } 2>/dev/null; then d=$c; return 0; fi; done; return 1; }; "
            + "if pick; then :; else mount -uw / >/dev/null 2>&1; if pick; then echo \"\(remountMarker)\"; fi; fi; "
            + "echo \"\(dirMarkerPrefix)$d\"; "
            + "for s in \(list); do "
            + "if command -v \"$s\" >/dev/null 2>&1; then echo \"\(haveMarkerPrefix)$s\"; fi; done; "
            + "for t in \(scriptRequiredTools.joined(separator: " ")); do "
            + "if command -v \"$t\" >/dev/null 2>&1; then :; else echo \"\(lackMarkerPrefix)$t\"; fi; done; "
            + "echo \"\(stampMarkerPrefix)$(cat \"$d/.stamp\" 2>/dev/null)\""
    }

    /// Printed by `scriptCheck` (`HPDIAG_LACK <tool>`) for each tool the
    /// `hpdiag-*` scripts rely on that this ramdisk doesn't have.
    public static let lackMarkerPrefix = "HPDIAG_LACK "

    /// External tools the `hpdiag-*` scripts call unconditionally (see the
    /// overlay README, "Assumptions about the ramdisk"). The ramdisk has no
    /// `awk`, `tr`, `sort`, `od`, `strings` or `base64`, so the scripts use
    /// none of them; every tool listed here is in the 17.5 SSH ramdisk (restore
    /// ramdisk + SSHRD overlay). The check still reports any that is missing,
    /// e.g. on a ramdisk built some other way.
    public static let scriptRequiredTools = ["ioreg", "dd", "grep", "sed", "head", "cut", "wc", "hexdump", "expr"]

    // MARK: File transfer without a decoder
    //
    // The ramdisk has NO `base64` (nor uudecode / openssl / perl): it is the
    // Apple restore ramdisk plus the dropbear overlay, and neither ships one.
    // So bytes are moved as a `printf` FORMAT string: plain characters as
    // themselves, everything else as a three-digit octal escape (`\012`).
    // That is POSIX printf — the shell's builtin does the decoding, and the
    // overlay's /usr/bin/printf would too — and it is exact for any byte.
    // Shell scripts grow by only ~15 %; binary data by up to 4x.

    /// Longest `printf` format sent in one command, in characters.
    public static let transferBudget = 30_000

    /// Bytes sent as themselves. Deliberately conservative: nothing that is
    /// special to printf (`\`, `%`) or awkward inside single quotes (`'`, `!`,
    /// backtick), and no control characters (so a command is always one line).
    static let transferLiterals: Set<UInt8> =
        Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _./:=,+(){}[]$\"#|;&<>*?~^@-".utf8)

    static func octalEscape(_ byte: UInt8) -> String {
        let digits = String(byte, radix: 8)
        return "\\" + String(repeating: "0", count: 3 - digits.count) + digits
    }

    /// `data` as one or more `printf` format strings of at most `budget`
    /// characters each; printing them in order reproduces `data` exactly.
    /// Each is safe inside single quotes. Empty data gives no chunks.
    public static func printfChunks(for data: Data, budget: Int = transferBudget) -> [String] {
        let limit = max(budget, 8)
        var chunks: [String] = []
        var current = ""
        var length = 0
        for byte in data {
            let escaped = octalEscape(byte)
            if length + 4 > limit {
                chunks.append(current)
                current = ""
                length = 0
            }
            // A format that starts with "-" would be read as an option.
            if transferLiterals.contains(byte) && !(byte == 0x2d && length == 0) {
                current.unicodeScalars.append(UnicodeScalar(byte))
                length += 1
            } else {
                current += escaped
                length += 4
            }
        }
        if length > 0 { chunks.append(current) }
        return chunks
    }

    /// Pod-side commands that write `data` to `quotedPath` (already quoted for
    /// the shell), to be run in order: the first truncates, the rest append.
    /// Needs nothing on the pod but the shell.
    public static func fileWriteCommands(quotedPath: String, data: Data, budget: Int = transferBudget) -> [String] {
        let chunks = printfChunks(for: data, budget: budget)
        guard !chunks.isEmpty else { return [": > \(quotedPath)"] }
        return chunks.enumerated().map { index, chunk in
            "printf '\(chunk)' \(index == 0 ? ">" : ">>") \(quotedPath)"
        }
    }

    /// The commands, to be run in order, that write one script into
    /// `directory` (one of `pushDirectories`), mark it executable and (the last one) print
    /// `HPDIAG_PUSHED <byte count>` so the caller can verify the transfer.
    /// Usually a single command; a large script is split (`transferBudget`).
    ///
    /// The bytes travel as a `printf` format (see above) — NOT base64, which
    /// this ramdisk cannot decode. The only external tools used are `mkdir`,
    /// `chmod` and `wc`. The first command empties the stamp, so an
    /// interrupted push is never taken for a complete one, and truncates the
    /// file, so running the whole list again is a clean retry.
    /// `name` must already be validated.
    public static func scriptPushCommands(name: String, content: Data,
                                          directory: String = pushDirectory,
                                          budget: Int = transferBudget) -> [String] {
        let file = "\(directory)/\(name)"
        let setPath = "PATH=\(basePath); export PATH; "
        var commands = fileWriteCommands(quotedPath: file, data: content, budget: budget)
        commands[0] = "mkdir -p \(directory) && : > \(stampFile(in: directory)) && " + commands[0]
        commands[commands.count - 1] += " && chmod 755 \(file) && echo \"\(pushedMarkerPrefix)$(wc -c < \(file))\""
        return commands.map { setPath + $0 }
    }

    /// Records a completed push.
    public static func scriptStamp(_ fingerprint: String, directory: String = pushDirectory) -> String {
        "echo '\(fingerprint)' > \(stampFile(in: directory))"
    }

    /// Bare script name for a tool.
    public static func script(for tool: DiagTool) -> String {
        switch tool {
        case .nand: return nand
        case .partmap: return partmap
        case .factory: return factory
        case .thermal: return thermal
        case .power: return power
        case .radio: return radio
        case .audio: return audio
        case .mic: return mic
        case .accel: return accel
        }
    }

    /// The full pod-side line for a script: PATH set, output framed in the
    /// JSON sentinels, exit status reported after them.
    ///
    /// The wrapper always exits 0, so a missing or failing script comes back
    /// as readable output (exit 127 = neither in this ramdisk nor pushed) instead of an
    /// opaque SSH failure. Scripts that print the sentinels themselves are
    /// fine — the parser copes with nested markers.
    public static func invocation(_ script: String) -> String {
        "PATH=\(path); export PATH; echo '\(beginMarker)'; \(script); rc=$?; echo; echo '\(endMarker)'; echo \"\(exitMarkerPrefix)$rc===\""
    }

    /// The full pod-side line for one tool.
    public static func invocation(for tool: DiagTool) -> String {
        invocation(script(for: tool))
    }

    /// Lists which `hpdiag-*` scripts this pod has, baked in or pushed (read-only).
    public static let inventory = "PATH=\(path); export PATH; ls -1 /usr/local/bin \(pushDirectories.joined(separator: " ")) 2>/dev/null | grep '^hpdiag-'"
}
