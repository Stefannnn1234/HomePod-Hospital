import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Serial port (UART) access
//
// A small blocking serial port built directly on POSIX termios — no
// third-party dependency. The app talks to the factory DIAGS shell through a
// USB-to-serial adapter (`/dev/cu.usbserial-*`, `/dev/cu.SLAB_USBtoUART`, …)
// at 115200 baud, 8 data bits, no parity, 1 stop bit, no flow control.
//
// Every call here BLOCKS (up to its timeout). Call it from a background queue,
// never from the main thread. All methods are safe to call from any thread;
// `close()` may be called while another thread is in the middle of a read and
// will make that read fail promptly with `.notOpen`.
//
// The descriptor is opened non-blocking and every wait goes through `poll()`
// in short slices, so a timeout is always honoured and an unplugged adapter is
// noticed (POLLHUP / ENXIO / EOF) instead of hanging the caller.

public enum SerialPortError: Error, Equatable, LocalizedError {
    /// The port isn't open (never opened, already closed, or closed mid-call).
    case notOpen
    case alreadyOpen
    /// `open()` failed. `code` is the errno.
    case openFailed(path: String, code: Int32)
    /// The path opened but isn't a serial device (termios calls were refused).
    case notASerialDevice(path: String, code: Int32)
    case unsupportedBaudRate(Int)
    case writeFailed(code: Int32)
    case readFailed(code: Int32)
    /// The adapter was unplugged (or the far end hung up).
    case disconnected
    /// Nothing (more) arrived in time. `partial` is whatever did arrive.
    case timeout(partial: String)
    /// `cancelRead()` was called while waiting. `partial` is what had arrived.
    case cancelled(partial: String)

    public var errorDescription: String? {
        switch self {
        case .notOpen:
            return "The serial port isn't open."
        case .alreadyOpen:
            return "The serial port is already open."
        case .openFailed(let path, let code):
            switch code {
            case EBUSY:
                return "\(path) is in use by another app. Quit any serial terminal (screen, minicom, SerialTools…) that has it open and try again."
            case ENOENT:
                return "\(path) doesn't exist any more. Is the USB-to-serial adapter still plugged in?"
            case EACCES, EPERM:
                return "No permission to open \(path)."
            default:
                return "Couldn't open \(path): \(SerialPort.describe(errno: code))."
            }
        case .notASerialDevice(let path, let code):
            return "\(path) didn't accept serial settings (\(SerialPort.describe(errno: code))). Is it really a serial port?"
        case .unsupportedBaudRate(let rate):
            return "Unsupported baud rate \(rate)."
        case .writeFailed(let code):
            return "Couldn't write to the serial port: \(SerialPort.describe(errno: code))."
        case .readFailed(let code):
            return "Couldn't read from the serial port: \(SerialPort.describe(errno: code))."
        case .disconnected:
            return "The serial adapter was disconnected."
        case .timeout:
            return "Timed out waiting for the device to answer."
        case .cancelled:
            return "Stopped waiting for the device."
        }
    }
}

public final class SerialPort: @unchecked Sendable {
    public let path: String
    public let baudRate: Int

    /// What `send(_:)` appends to a command. The DIAGS shell takes a newline.
    public var lineTerminator = "\n"
    /// Pause between bytes when sending. 0 (the default) sends a command in one
    /// write. Raise it (e.g. 0.002) if the far end drops characters on long
    /// lines — small UART FIFOs with no flow control sometimes do.
    public var interByteDelay: TimeInterval = 0

    /// Guards `fd` and `closing`. Never held while blocking.
    private let stateLock = NSLock()
    /// Held for the whole of one I/O operation, so a send-then-collect pair
    /// can't interleave with another thread's. `close()` takes it to wait for
    /// an operation in flight before releasing the descriptor.
    private let ioLock = NSRecursiveLock()
    private var fd: Int32 = -1
    private var closing = false
    /// Set by `cancelRead()`; makes the `readUntil` in flight give up.
    private var cancelRequested = false
    /// Bytes received but not yet handed to a caller. Guarded by `ioLock`.
    private var rxBuffer: [UInt8] = []

    /// How long one `poll()` waits before re-checking for `close()`.
    private static let pollSliceMs: Int32 = 50
    /// Don't let a runaway device grow the buffer without bound.
    private static let maxBufferedBytes = 8 * 1024 * 1024

    public init(path: String, baudRate: Int = 115200) {
        self.path = path
        self.baudRate = baudRate
    }

    deinit { close() }

    public var isOpen: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return fd >= 0 && !closing
    }

    // MARK: Discovery

    /// Call-out serial devices (`/dev/cu.*`), with likely USB-to-serial
    /// adapters first. `directory` is a parameter only so tests can point it at
    /// a scratch folder.
    public static func availablePorts(in directory: String = "/dev") -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        return names.filter { $0.hasPrefix("cu.") }
            .sorted { a, b in
                let (ua, ub) = (isLikelyUSBSerial(a), isLikelyUSBSerial(b))
                if ua != ub { return ua }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            .map { base + $0 }
    }

    /// True for names the common USB-to-serial drivers use (FTDI, CP210x,
    /// CH34x, PL2303, CDC-ACM) — as opposed to Bluetooth or debug ports.
    public static func isLikelyUSBSerial(_ pathOrName: String) -> Bool {
        let name = (pathOrName as NSString).lastPathComponent.lowercased()
        return ["usbserial", "slab_usbtouart", "usbmodem", "wchusbserial", "pl2303", "ftdi", "uart"]
            .contains { name.contains($0) }
    }

    // MARK: Open / close

    /// Opens the device and configures it raw, `baudRate` 8N1, no flow control.
    public func open() throws {
        ioLock.lock(); defer { ioLock.unlock() }
        stateLock.lock()
        let already = fd >= 0
        stateLock.unlock()
        if already { throw SerialPortError.alreadyOpen }

        guard let speed = Self.speedConstant(for: baudRate) else {
            throw SerialPortError.unsupportedBaudRate(baudRate)
        }

        // O_NONBLOCK so opening never waits for carrier-detect; O_NOCTTY so the
        // port can't become our controlling terminal.
        let newFD = sysOpen(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard newFD >= 0 else { throw SerialPortError.openFailed(path: path, code: errno) }

        var tio = termios()
        guard tcgetattr(newFD, &tio) == 0 else {
            let code = errno
            _ = sysClose(newFD)
            throw SerialPortError.notASerialDevice(path: path, code: code)
        }

        // Exclusive use: a second program reading the same port would steal
        // half of every reply. Best effort — not every driver supports it.
        _ = sysIoctl(newFD, Self.TIOCEXCL_REQUEST)

        cfmakeraw(&tio)
        // 8 data bits, no parity, one stop bit; ignore modem lines; receiver on.
        tio.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB)
        tio.c_cflag |= tcflag_t(CS8 | CREAD | CLOCAL)
        // No hardware flow control.
        #if canImport(Darwin)
        tio.c_cflag &= ~tcflag_t(CRTS_IFLOW | CCTS_OFLOW)
        #else
        tio.c_cflag &= ~tcflag_t(CRTSCTS)
        #endif
        // No software flow control, no input translation.
        tio.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY | INLCR | ICRNL | IGNCR | ISTRIP)
        tio.c_oflag &= ~tcflag_t(OPOST)
        tio.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ECHONL | ISIG | IEXTEN)
        // VMIN=1/VTIME=0: with O_NONBLOCK a read with nothing waiting fails
        // with EAGAIN, so a 0-byte read can only mean the device went away.
        withUnsafeMutableBytes(of: &tio.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        cfsetispeed(&tio, speed)
        cfsetospeed(&tio, speed)

        guard tcsetattr(newFD, TCSANOW, &tio) == 0 else {
            let code = errno
            _ = sysClose(newFD)
            throw SerialPortError.notASerialDevice(path: path, code: code)
        }
        tcflush(newFD, TCIOFLUSH)

        rxBuffer.removeAll()
        stateLock.lock()
        fd = newFD
        closing = false
        stateLock.unlock()
    }

    /// Closes the port. Safe to call twice, and safe to call while another
    /// thread is blocked in a read — that read fails with `.notOpen`.
    public func close() {
        stateLock.lock()
        if fd < 0 { stateLock.unlock(); return }
        closing = true
        stateLock.unlock()

        // Wait (at most one poll slice) for an operation in flight to notice.
        ioLock.lock()
        stateLock.lock()
        let old = fd
        fd = -1
        closing = false
        stateLock.unlock()
        if old >= 0 {
            // Drop unsent output first: close() on a serial device otherwise
            // waits for it to drain, which never happens once the adapter has
            // been unplugged.
            tcflush(old, TCIOFLUSH)
            _ = sysClose(old)
        }
        rxBuffer.removeAll()
        ioLock.unlock()
    }

    /// Makes a `readUntil` / `sendAndCollect` that is waiting right now give
    /// up with `.cancelled(partial:)`. The port stays open. Does nothing when
    /// no such call is in flight. Nothing is sent to the device — whatever it
    /// was doing, it keeps doing.
    public func cancelRead() {
        stateLock.lock()
        cancelRequested = true
        stateLock.unlock()
    }

    private func takeCancelRequest() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        let was = cancelRequested
        cancelRequested = false
        return was
    }

    // MARK: Writing

    /// Writes `command` followed by the line terminator.
    public func send(_ command: String) throws {
        try write(Array((command + lineTerminator).utf8))
    }

    /// Writes raw bytes, retrying partial writes until all are out.
    public func write(_ bytes: [UInt8], timeout: TimeInterval = 5) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        guard !bytes.isEmpty else { _ = try liveFD(); return }
        if interByteDelay > 0 {
            for byte in bytes {
                try writeAll([byte], timeout: timeout)
                Thread.sleep(forTimeInterval: interByteDelay)
            }
        } else {
            try writeAll(bytes, timeout: timeout)
        }
    }

    private func writeAll(_ bytes: [UInt8], timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        while offset < bytes.count {
            let fd = try liveFD()
            let n = bytes[offset...].withUnsafeBytes { sysWrite(fd, $0.baseAddress, $0.count) }
            if n > 0 { offset += n; continue }
            let code = errno
            if n < 0 && (code == EAGAIN || code == EWOULDBLOCK || code == EINTR) {
                guard Date() < deadline else { throw SerialPortError.writeFailed(code: ETIMEDOUT) }
                _ = try pollOnce(fd, for: Int16(POLLOUT), ms: Self.pollSliceMs)
                continue
            }
            if n < 0 && Self.meansGone(code) { throw SerialPortError.disconnected }
            throw SerialPortError.writeFailed(code: n == 0 ? EIO : code)
        }
    }

    // MARK: Reading

    /// The next complete line, without its line ending, or `nil` if no complete
    /// line arrived within `timeout`. Text that hasn't been terminated yet (a
    /// prompt, for instance) stays buffered for the next call — see
    /// `readUntil` / `readAvailable` to get at it.
    public func readLine(timeout: TimeInterval = 5) throws -> String? {
        ioLock.lock(); defer { ioLock.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = rxBuffer.firstIndex(of: 0x0A) {
                var line = Array(rxBuffer[..<newline])
                rxBuffer.removeSubrange(...newline)
                while line.last == 0x0D { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            _ = try fill(waitingUpTo: remaining)
        }
    }

    /// Everything received so far, without waiting (beyond `wait`). Use it to
    /// show unsolicited output — boot logs, a prompt — while idle.
    public func readAvailable(wait: TimeInterval = 0) throws -> String {
        ioLock.lock(); defer { ioLock.unlock() }
        // Keep reading while bytes keep coming, so one call returns a burst.
        var waitFor = wait
        while try fill(waitingUpTo: waitFor) { waitFor = 0 }
        // Don't split a multi-byte UTF-8 character across two calls.
        let cut = Self.utf8SafePrefixLength(rxBuffer)
        let text = String(decoding: rxBuffer[..<cut], as: UTF8.self)
        rxBuffer.removeSubrange(..<cut)
        return text
    }

    /// Throws away everything received so far (stale output, an old prompt).
    public func discardInput() throws {
        ioLock.lock(); defer { ioLock.unlock() }
        while try fill(waitingUpTo: 0) {}
        rxBuffer.removeAll()
    }

    /// Reads until `marker` shows up on the LAST line received — i.e. the far
    /// end has printed its prompt and stopped — and returns everything up to
    /// and including that line.
    ///
    /// `timeout` is an IDLE timeout: the call fails only when nothing at all
    /// arrives for that long, so a long dump (`syscfg list` with calibration
    /// blobs) isn't cut off as long as it keeps flowing. `maxDuration` is the
    /// hard ceiling for a device that never stops talking.
    ///
    /// Throws `.timeout(partial:)` carrying what was received, so the caller
    /// can still show it.
    public func readUntil(_ marker: String, timeout: TimeInterval = 10, maxDuration: TimeInterval = 180) throws -> String {
        ioLock.lock(); defer { ioLock.unlock() }
        let markerBytes = Array(marker.utf8)
        let hardDeadline = Date().addingTimeInterval(maxDuration)
        var idleDeadline = Date().addingTimeInterval(timeout)
        var collected: [UInt8] = []
        // A cancel only applies to the wait that is in flight when it's asked
        // for — forget one left over from before.
        _ = takeCancelRequest()

        while true {
            collected.append(contentsOf: rxBuffer)
            rxBuffer.removeAll(keepingCapacity: true)
            if takeCancelRequest() {
                throw SerialPortError.cancelled(partial: String(decoding: collected, as: UTF8.self))
            }
            if !markerBytes.isEmpty, Self.lastLine(of: collected, contains: markerBytes) {
                // Give a trailing space after the prompt a moment to arrive so
                // it doesn't get left behind for the next command.
                if try fill(waitingUpTo: 0.02) { continue }
                return String(decoding: collected, as: UTF8.self)
            }
            let now = Date()
            let deadline = min(idleDeadline, hardDeadline)
            if now >= deadline {
                throw SerialPortError.timeout(partial: String(decoding: collected, as: UTF8.self))
            }
            // Wait in short steps so a cancel is noticed promptly.
            if try fill(waitingUpTo: min(0.1, deadline.timeIntervalSince(now))) {
                idleDeadline = Date().addingTimeInterval(timeout)
            }
        }
    }

    /// Sends `command` and collects the reply until the prompt (`until`) comes
    /// back. Anything that was already waiting in the receive buffer is
    /// discarded first, so an old prompt can't be mistaken for the answer.
    /// The returned text is raw: it includes the echoed command, any colour
    /// codes, and the closing prompt line.
    ///
    /// `timeout` is an idle timeout — see `readUntil`.
    public func sendAndCollect(_ command: String, until: String = ":-)", timeout: TimeInterval = 10) throws -> String {
        try sendAndCollect(command, until: until, timeout: timeout, maxDuration: 180)
    }

    public func sendAndCollect(_ command: String, until: String, timeout: TimeInterval, maxDuration: TimeInterval) throws -> String {
        ioLock.lock(); defer { ioLock.unlock() }
        try discardInput()
        try send(command)
        return try readUntil(until, timeout: timeout, maxDuration: maxDuration)
    }

    // MARK: Internals

    private func liveFD() throws -> Int32 {
        stateLock.lock(); defer { stateLock.unlock() }
        guard fd >= 0, !closing else { throw SerialPortError.notOpen }
        return fd
    }

    /// Waits up to `seconds` for input and moves whatever is there into
    /// `rxBuffer`. Returns whether any bytes arrived. `seconds == 0` polls.
    @discardableResult
    private func fill(waitingUpTo seconds: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(max(0, seconds))
        while true {
            let fd = try liveFD()
            let remainingMs = max(0, deadline.timeIntervalSinceNow * 1000)
            let slice = Int32(min(Double(Self.pollSliceMs), remainingMs.rounded(.up)))
            let revents = try pollOnce(fd, for: Int16(POLLIN), ms: slice)
            if revents & Int16(POLLIN) != 0 {
                return try drain(fd)
            }
            if revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                throw SerialPortError.disconnected
            }
            if deadline.timeIntervalSinceNow <= 0 { return false }
        }
    }

    /// Reads everything currently available on `fd` into `rxBuffer`.
    private func drain(_ fd: Int32) throws -> Bool {
        var got = false
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { sysRead(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                got = true
                rxBuffer.append(contentsOf: chunk[..<n])
                if rxBuffer.count > Self.maxBufferedBytes {
                    rxBuffer.removeFirst(rxBuffer.count - Self.maxBufferedBytes)
                }
                if n < chunk.count { return true }
                continue
            }
            if n == 0 {
                // EOF on a tty: the adapter is gone. Hand back what we got
                // first; the next call reports the disconnect.
                if got { return true }
                throw SerialPortError.disconnected
            }
            let code = errno
            if code == EAGAIN || code == EWOULDBLOCK { return got }
            if code == EINTR { continue }
            if got { return true }
            if Self.meansGone(code) { throw SerialPortError.disconnected }
            throw SerialPortError.readFailed(code: code)
        }
    }

    /// One `poll()` on the descriptor. Returns `revents` (0 on timeout).
    private func pollOnce(_ fd: Int32, for events: Int16, ms: Int32) throws -> Int16 {
        var pfd = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let rc = poll(&pfd, 1, ms)
            if rc >= 0 { return rc == 0 ? 0 : pfd.revents }
            if errno == EINTR { continue }
            throw SerialPortError.readFailed(code: errno)
        }
    }

    /// errno values a vanished USB adapter produces.
    private static func meansGone(_ code: Int32) -> Bool {
        code == ENXIO || code == EIO || code == ENODEV || code == EBADF || code == EPIPE
    }

    /// Whether the text after the last newline contains `marker`.
    static func lastLine(of bytes: [UInt8], contains marker: [UInt8]) -> Bool {
        let start = (bytes.lastIndex(of: 0x0A).map { $0 + 1 }) ?? 0
        let tail = bytes[start...]
        guard tail.count >= marker.count else { return false }
        var i = tail.startIndex
        let last = tail.endIndex - marker.count
        while i <= last {
            if tail[i] == marker[0], tail[i..<(i + marker.count)].elementsEqual(marker) { return true }
            i += 1
        }
        return false
    }

    /// Length of the longest prefix that doesn't end inside a UTF-8 sequence.
    static func utf8SafePrefixLength(_ bytes: [UInt8]) -> Int {
        var end = bytes.count
        // Walk back over up to three continuation bytes to the lead byte.
        var back = 0
        while back < 3, end - back - 1 >= 0, bytes[end - back - 1] & 0xC0 == 0x80 { back += 1 }
        let leadIndex = end - back - 1
        guard leadIndex >= 0 else { return end }
        let lead = bytes[leadIndex]
        let needed: Int
        if lead & 0x80 == 0 { needed = 1 }
        else if lead & 0xE0 == 0xC0 { needed = 2 }
        else if lead & 0xF0 == 0xE0 { needed = 3 }
        else if lead & 0xF8 == 0xF0 { needed = 4 }
        else { return end }  // stray continuation bytes — not valid anyway
        if back + 1 < needed { end = leadIndex }
        return end
    }

    static func describe(errno code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func speedConstant(for baud: Int) -> speed_t? {
        switch baud {
        case 1200: return speed_t(B1200)
        case 2400: return speed_t(B2400)
        case 4800: return speed_t(B4800)
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        default:
            #if canImport(Darwin)
            // On macOS a speed_t IS the rate, so any positive value is valid
            // (the driver decides whether it can do it).
            return baud > 0 ? speed_t(baud) : nil
            #else
            return nil
            #endif
        }
    }

    // `TIOCEXCL` is a function-like macro on macOS (`_IO('t', 13)`), which
    // Swift can't import, so the request numbers are spelled out.
    #if canImport(Darwin)
    private static let TIOCEXCL_REQUEST: UInt = 0x2000_740D
    #else
    private static let TIOCEXCL_REQUEST: UInt = 0x540C
    #endif
}

// The class has methods called `open`, `close` and `write`, which would shadow
// the C functions inside it — so the system calls are reached through these.
private func sysOpen(_ path: String, _ flags: Int32) -> Int32 { open(path, flags) }
private func sysClose(_ fd: Int32) -> Int32 { close(fd) }
private func sysRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { read(fd, buffer, count) }
private func sysWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { write(fd, buffer, count) }
private func sysIoctl(_ fd: Int32, _ request: UInt) -> Int32 { ioctl(fd, request) }
