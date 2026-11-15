import XCTest
@testable import HomePodRestoreCore

/// Thread-safe collector for @Sendable progress callbacks.
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ v: T) { lock.lock(); items.append(v); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

final class SysCfgControllerTests: XCTestCase {

    func testControllerReadViaFakeBooter() async {
        let blob = SysCfgTests.makeBlob(serial: "CTRL0001", wifi: [1,2,3,4,5,6], bt: [6,5,4,3,2,1])
        let booter = FakeRamdiskBooter(transport: FakeSysCfgTransport(seed: blob))
        let controller = SysCfgController(booter: booter)
        let phases = Recorder<SysCfgPhase>()
        let outcome = await controller.read(ecid: 0xABC, onPhase: { phases.add($0) })
        guard case .read(let data) = outcome else { return XCTFail("expected .read, got \(outcome)") }
        XCTAssertEqual(data.serialNumber, "CTRL0001")
        XCTAssertEqual(data.wifiMAC, "01:02:03:04:05:06")
        XCTAssertTrue(phases.all.contains(.unlocking))
        XCTAssertTrue(phases.all.contains(.done))
    }

    func testControllerRestoreWritesVerbatim() async {
        let good = SysCfgTests.makeBlob(serial: "CTRL0002", wifi: [9,9,9,9,9,9], bt: [8,8,8,8,8,8])
        let transport = FakeSysCfgTransport(seed: Data())   // new blank chip
        let controller = SysCfgController(booter: FakeRamdiskBooter(transport: transport))
        let outcome = await controller.restore(ecid: 0xABC, blob: good)
        XCTAssertEqual(outcome, .restored)
        let written = await transport.lastWritten
        XCTAssertEqual(written, good)
    }

    func testControllerSurfacesBootFailure() async {
        struct FailingBooter: RamdiskBooter {
            func boot(ecid: UInt64, onLog: @escaping @Sendable (String) -> Void) async throws -> BootedPod {
                throw SysCfgError.transportUnavailable("gaster pwn failed")
            }
        }
        let controller = SysCfgController(booter: FailingBooter())
        let outcome = await controller.read(ecid: 0xABC)
        guard case .failed(let msg) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(msg.contains("gaster pwn failed"))
    }
}
