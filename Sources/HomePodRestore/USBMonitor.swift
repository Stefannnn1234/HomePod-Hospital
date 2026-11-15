import Foundation
import IOKit
import IOKit.usb
import HomePodRestoreCore

/// Watches for Apple mobile devices (HomePods in DFU / recovery / restore
/// mode) on every USB port. Polling once a second is simple and reliable
/// across the frequent re-enumerations a restore causes.
final class USBMonitor {
    private let queue = DispatchQueue(label: "HomePodRestore.USBMonitor")
    private var timer: DispatchSourceTimer?
    private var last: [ConnectedDevice] = []
    private let onChange: ([ConnectedDevice]) -> Void

    init(onChange: @escaping ([ConnectedDevice]) -> Void) {
        self.onChange = onChange
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(1000))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func poll() {
        let now = Self.scan()
        if now != last {
            last = now
            let snapshot = now
            DispatchQueue.main.async { self.onChange(snapshot) }
        }
    }

    static func scan() -> [ConnectedDevice] {
        var found: [ConnectedDevice] = []
        for className in ["IOUSBHostDevice", "IOUSBDevice"] {
            // Note: adding idVendor to the matching dictionary returns nothing on
            // current macOS (IOUSBHostDevice), so match the class and filter here.
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                guard intProperty(service, kUSBVendorID) == 0x05AC,
                      let pid = intProperty(service, kUSBProductID),
                      (0x1200...0x12FF).contains(pid) else { continue }
                let location = UInt32(truncatingIfNeeded: intProperty(service, kUSBDevicePropertyLocationID) ?? 0)
                if found.contains(where: { $0.locationID == location }) { continue }
                let serial = stringProperty(service, kUSBSerialNumberString) ?? ""
                let name = stringProperty(service, kUSBProductString) ?? "Apple device"
                var speed = intProperty(service, "Device Speed")
                if speed == nil, let s = intProperty(service, "USBSpeed") {
                    // IOUSBHost: 1 full, 2 low, 3 high, 4+ super → legacy 0 low, 1 full, 2 high, 3 super
                    speed = [1: 1, 2: 0, 3: 2][s] ?? (s >= 4 ? 3 : nil)
                }
                found.append(ConnectedDevice(locationID: location, productID: pid, productName: name, serial: serial, speed: speed))
            }
            if !found.isEmpty { break }
        }
        return found.sorted { $0.locationID < $1.locationID }
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        (property(service, key) as? NSNumber)?.intValue
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        property(service, key) as? String
    }
}
