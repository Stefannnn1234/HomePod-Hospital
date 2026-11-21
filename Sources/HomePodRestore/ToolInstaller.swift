import Foundation
import HomePodRestoreCore

/// Writes the tool installer to a .command file Terminal can open.
enum ToolInstaller {
    enum Failure: Error, LocalizedError {
        case missingResource(String)
        var errorDescription: String? {
            if case .missingResource(let n) = self { return "The app is missing \(n). Please re-download HomePod Hospital." }
            return nil
        }
    }

    static func prepareScript(builder: Bool) throws -> URL {
        AppPaths.ensure()
        let fm = FileManager.default
        guard let script = Bundle.main.url(forResource: "setup-tools", withExtension: "sh") else {
            throw Failure.missingResource("setup-tools.sh")
        }
        let dir = AppPaths.support.appendingPathComponent("installer", isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent("patches"), withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("setup-tools.sh")
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: script, to: dest)
        if let patch = Bundle.main.url(forResource: "gaster-ecid", withExtension: "patch") {
            let p = dir.appendingPathComponent("patches/gaster-ecid.patch")
            if fm.fileExists(atPath: p.path) { try fm.removeItem(at: p) }
            try fm.copyItem(at: patch, to: p)
        }
        // A .command file opens in Terminal when double-clicked / opened.
        let command = dir.appendingPathComponent(builder ? "Install HomePod Hospital tools (with builder).command" : "Install HomePod Hospital tools.command")
        let body = """
        #!/bin/bash
        exec /bin/bash \(shellQuote(dest.path))\(builder ? " --builder" : "")
        """
        try body.write(to: command, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return command
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
