// Diagnostic: shows what HomePod Restore's USB monitor sees.
//   swift scripts/usb-scan.swift
import Foundation
import IOKit
import IOKit.usb

func prop(_ s: io_service_t, _ k: String) -> Any? {
    IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

for className in ["IOUSBHostDevice", "IOUSBDevice"] {
    print("=== \(className) — all devices")
    guard let all = IOServiceMatching(className) else { print("  IOServiceMatching returned nil"); continue }
    var it: io_iterator_t = 0
    let kr = IOServiceGetMatchingServices(kIOMainPortDefault, all, &it)
    print("  IOServiceGetMatchingServices kr=\(kr)")
    var n = 0
    while case let s = IOIteratorNext(it), s != 0 {
        n += 1
        let vid = (prop(s, "idVendor") as? NSNumber)?.intValue ?? -1
        let pid = (prop(s, "idProduct") as? NSNumber)?.intValue ?? -1
        let loc = (prop(s, "locationID") as? NSNumber)?.uint32Value ?? 0
        let name = prop(s, "USB Product Name") as? String ?? prop(s, "kUSBProductString") as? String ?? "?"
        let serial = prop(s, "USB Serial Number") as? String ?? prop(s, "kUSBSerialNumberString") as? String ?? "(none)"
        let speed = (prop(s, "Device Speed") as? NSNumber)?.intValue
        let hspeed = (prop(s, "USBSpeed") as? NSNumber)?.intValue
        print(String(format: "  vid=0x%04X pid=0x%04X loc=0x%08X", vid, pid, loc), "name=\(name)", "speed=\(speed.map(String.init) ?? "nil")/\(hspeed.map(String.init) ?? "nil")")
        if vid == 0x05AC { print("    serial=\(serial)") }
        IOObjectRelease(s)
    }
    IOObjectRelease(it)
    print("  total: \(n)")

    print("=== \(className) — app's filtered query (idVendor=0x05AC)")
    if let m = IOServiceMatching(className) as NSMutableDictionary? {
        m[kUSBVendorID] = 0x05AC
        var it2: io_iterator_t = 0
        let kr2 = IOServiceGetMatchingServices(kIOMainPortDefault, m, &it2)
        var c = 0
        while case let s = IOIteratorNext(it2), s != 0 { c += 1; IOObjectRelease(s) }
        IOObjectRelease(it2)
        print("  kr=\(kr2) matches=\(c)")
    }
}
