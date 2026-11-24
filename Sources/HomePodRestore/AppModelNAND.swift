import Foundation
import HomePodRestoreCore

/// NAND health of a running pod: the flash controller's lifetime statistics,
/// read over USB with libimobiledevice's `ideviceinfo`
/// (lockdown domain `com.apple.disk_usage`, key `NANDInfo`).
struct NANDHealthState: Equatable {
    var running = true
    var report: NANDHealthReport?
    var error: String?
}

extension AppModel {
    func readNANDHealth(on device: ConnectedDevice) {
        let id = device.locationID
        if nandHealth[id]?.running == true { return }
        guard let tool = locateOnPath("ideviceinfo") else {
            nandHealth[id] = NANDHealthState(running: false, error: "ideviceinfo isn't installed. It comes with libimobiledevice (brew install libimobiledevice), and app builds made with the tools inside include it.")
            return
        }
        nandHealth[id] = NANDHealthState()
        var args = ["-q", "com.apple.disk_usage", "-k", "NANDInfo", "-x"]
        if let udid = Self.udid(fromUSBSerial: device.serial) { args = ["-u", udid] + args }
        let runner = ProcessRunner(executable: tool, arguments: args)
        Task {
            var state = NANDHealthState(running: false)
            do {
                let result = try await runner.run(onLine: { _ in })
                do {
                    state.report = NANDHealthReport(stats: try ASPStats.parse(ideviceinfoOutput: result.output))
                } catch {
                    state.error = Self.nandReadError(result.output)
                }
            } catch {
                state.error = "Couldn't run ideviceinfo: \(error.localizedDescription)"
            }
            nandHealth[id] = state
        }
    }

    /// In normal mode a device's USB serial number is its UDID (40 hex digits
    /// on an A8). Anything else: let ideviceinfo pick the only device.
    static func udid(fromUSBSerial serial: String) -> String? {
        let s = serial.trimmingCharacters(in: .whitespaces)
        let hex = s.replacingOccurrences(of: "-", with: "")
        guard (24...40).contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
        return s
    }

    static func nandReadError(_ output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.localizedCaseInsensitiveContains("No device found") {
            return "No HomePod answered over USB. It has to be fully started up in its normal software (not DFU or recovery) with the USB adapter attached."
        }
        if text.localizedCaseInsensitiveContains("lockdown") || text.localizedCaseInsensitiveContains("pair") {
            return "The HomePod didn't accept a connection from this Mac. Wait until it has finished starting up, unplug and replug USB, then try again."
        }
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
        return "Couldn't read the NAND statistics: \(first)"
    }
}
