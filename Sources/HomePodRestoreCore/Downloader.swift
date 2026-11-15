import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct DownloadProgress: Sendable {
    public let received: Int64
    public let total: Int64?
    public let bytesPerSecond: Double?
    public var fraction: Double? { total.flatMap { $0 > 0 ? Double(received) / Double($0) : nil } }
}

public enum DownloadError: Error, LocalizedError {
    case http(Int)
    case checksumMismatch
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .http(let c): return "The download server returned an error (HTTP \(c))."
        case .checksumMismatch: return "The downloaded file is corrupted (checksum mismatch). Please download it again."
        case .cancelled: return "Download cancelled."
        }
    }
}

/// Resumable large-file downloader. If a download is interrupted (or the app
/// quits) it picks up where it left off next time, using `<dest>.part`.
public final class FileDownloader: NSObject, @unchecked Sendable, URLSessionDataDelegate {
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<URL, Error>?
    private var received: Int64 = 0
    private var total: Int64?
    private var onProgress: (@Sendable (DownloadProgress) -> Void)?
    private var partURL: URL!
    private var destination: URL!
    private var lastReport = Date.distantPast
    private var speedSampleBytes: Int64 = 0
    private var speedSampleStart = Date()
    private var speed: Double?
    private let lock = NSLock()

    public override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60 * 12
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// Downloads `url` to `destination`. Returns when finished.
    public func download(_ url: URL, to destination: URL, expectedSHA256: String? = nil,
                         onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.destination = destination
        partURL = destination.appendingPathExtension("part")
        self.onProgress = onProgress

        if !fm.fileExists(atPath: partURL.path) { _ = fm.createFile(atPath: partURL.path, contents: nil) }
        let existing = (try? fm.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        received = existing
        handle = try FileHandle(forWritingTo: partURL)
        handle?.seekToEndOfFile()

        var req = URLRequest(url: url)
        if existing > 0 { req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        let file: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock(); continuation = cont; lock.unlock()
                let t = session.dataTask(with: req)
                task = t
                t.resume()
            }
        } onCancel: {
            self.cancel()
        }

        if let expectedSHA256, !expectedSHA256.isEmpty {
            onProgress(DownloadProgress(received: received, total: total, bytesPerSecond: nil))
            if let actual = try FileDownloader.sha256(of: file), actual.lowercased() != expectedSHA256.lowercased() {
                try? fm.removeItem(at: file)
                throw DownloadError.checksumMismatch
            }
        }
        return file
    }

    public func cancel() {
        task?.cancel()
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
        switch http.statusCode {
        case 206:
            // Resuming — Content-Range: bytes start-end/total
            if let cr = http.value(forHTTPHeaderField: "Content-Range"), let slash = cr.lastIndex(of: "/") {
                total = Int64(cr[cr.index(after: slash)...])
            }
            completionHandler(.allow)
        case 200:
            // Server ignored Range (or fresh start): truncate.
            handle?.truncateFile(atOffset: 0)
            received = 0
            total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            completionHandler(.allow)
        case 416:
            // Range not satisfiable: we already have the whole file.
            completionHandler(.cancel)
            finish(error: nil)
        default:
            completionHandler(.cancel)
            finish(error: DownloadError.http(http.statusCode))
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handle?.write(data)
        received += Int64(data.count)
        speedSampleBytes += Int64(data.count)
        let now = Date()
        let dt = now.timeIntervalSince(speedSampleStart)
        if dt >= 2 {
            speed = Double(speedSampleBytes) / dt
            speedSampleBytes = 0
            speedSampleStart = now
        }
        if now.timeIntervalSince(lastReport) > 0.25 {
            lastReport = now
            onProgress?(DownloadProgress(received: received, total: total, bytesPerSecond: speed))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error as? URLError, e.code == .cancelled {
            finish(error: DownloadError.cancelled)
        } else {
            finish(error: error)
        }
    }

    private func finish(error: Error?) {
        lock.lock()
        guard let cont = continuation else { lock.unlock(); return }
        continuation = nil
        lock.unlock()
        try? handle?.close()
        handle = nil
        session.finishTasksAndInvalidate()
        if let error { cont.resume(throwing: error); return }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: partURL, to: destination)
            onProgress?(DownloadProgress(received: received, total: total ?? received, bytesPerSecond: nil))
            cont.resume(returning: destination)
        } catch {
            cont.resume(throwing: error)
        }
    }

    /// SHA-256 of a file, streamed. Returns nil where CryptoKit isn't available.
    public static func sha256(of url: URL) throws -> String? {
        #if canImport(CryptoKit)
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = h.readData(ofLength: 8 * 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    public static func progress(_ p: DownloadProgress) -> String {
        var s = string(p.received)
        if let t = p.total { s += " of " + string(t) }
        if let bps = p.bytesPerSecond, bps > 0 {
            s += " — " + string(Int64(bps)) + "/s"
            if let t = p.total {
                let remaining = Double(t - p.received) / bps
                s += ", " + duration(remaining) + " left"
            }
        }
        return s
    }

    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
