import Foundation

/// Which A8 (t7000) board a device in DFU is, from the board id (BDID) in its
/// USB serial string.
///
/// The CPID alone (0x7000) can't tell a HomePod from the other A8 products: an
/// Apple TV HD, iPhone 6 / 6 Plus, iPad mini 4 or iPod touch (6th gen) in DFU
/// looks the same until you read the board id. Every T7000 product has two:
/// the production-fused "ap" board and the development-fused "dev" board, which
/// is always ap + 1. The ids come from Apple's embedded device map.
///
/// The retail HomePod IPSW carries a build for b238aap (0x38) only, so that is
/// the only board a restore (or boot test) can work on.
public struct A8Board: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// B238a, AudioAccessory1,1 — the 1st-gen HomePod that shipped.
        case homePod
        /// B238, AudioAccessory1,2 — an earlier HomePod board that never
        /// shipped. Apple published no firmware for it.
        case homePodPrototype
        /// Another A8 product: same chip, not a HomePod.
        case otherProduct
    }

    public let boardID: UInt32
    public let kind: Kind
    /// Apple's board name, e.g. "B238a", "J42d".
    public let codename: String
    /// What a person would call it, e.g. "HomePod", "Apple TV HD".
    public let productName: String
    /// e.g. "AudioAccessory1,1".
    public let productType: String
    /// Development-fused board (the odd id of the pair).
    public let isDevFused: Bool

    /// Board id as printed in the DFU string, e.g. "0x38".
    public var boardIDString: String { String(format: "0x%02X", boardID) }

    /// "B238a, board 0x38" / "B238a DEV, board 0x39".
    public var label: String { "\(codename)\(isDevFused ? " DEV" : ""), board \(boardIDString)" }

    /// The b238aap board — the one the retail firmware is built for.
    public var isRetailHomePod: Bool { kind == .homePod && !isDevFused }

    /// Production (ap) board ids of every T7000 product.
    static let products: [(ap: UInt32, codename: String, name: String, type: String, kind: Kind)] = [
        (0x04, "N56", "iPhone 6 Plus", "iPhone7,1", .otherProduct),
        (0x06, "N61", "iPhone 6", "iPhone7,2", .otherProduct),
        (0x08, "J96", "iPad mini 4 (Wi-Fi)", "iPad5,1", .otherProduct),
        (0x0A, "J97", "iPad mini 4 (Cellular)", "iPad5,2", .otherProduct),
        (0x10, "N102", "iPod touch (6th generation)", "iPod7,1", .otherProduct),
        (0x1A, "B238", "HomePod (pre-production board)", "AudioAccessory1,2", .homePodPrototype),
        (0x34, "J42d", "Apple TV HD", "AppleTV5,3", .otherProduct),
        (0x38, "B238a", "HomePod", "AudioAccessory1,1", .homePod),
    ]

    /// The board for an A8 board id, or nil when the id isn't a known T7000 board.
    public static func identify(_ boardID: UInt32?) -> A8Board? {
        guard let boardID else { return nil }
        let ap = boardID & ~1
        guard let p = products.first(where: { $0.ap == ap }) else { return nil }
        return A8Board(boardID: boardID, kind: p.kind, codename: p.codename, productName: p.name,
                       productType: p.type, isDevFused: boardID != ap)
    }
}

/// Why a job can't run on the board in DFU (nil = fine). Kept apart from the
/// app model so the rules are testable.
public enum A8BoardGate {
    public static let notA8 = "This isn't a 1st-gen HomePod (A8 chip)."

    /// For a restore or boot test: both need a build for this board in the
    /// firmware, and the retail firmware only has b238aap (0x38).
    public static func restoreBlocker(_ ib: IBootSerial) -> String? {
        if let reason = notAHomePod(ib) { return reason }
        guard let board = ib.a8Board else { return nil }   // board id not readable: don't guess
        switch board.kind {
        case .homePodPrototype:
            return "This is a pre-production HomePod board (\(board.label), \(board.productType)). Apple never released firmware for it, so it can't be restored. Nicotine and the diagnostic boots can still be tried."
        case .homePod where board.isDevFused:
            return "This HomePod board is development-fused (\(board.label)). The retail firmware only has a build for production boards (0x38), so a restore would fail. Nicotine and the diagnostic boots can still be tried."
        default:
            return nil
        }
    }

    /// For everything that only unlocks the chip and boots our own payload
    /// (quick check, SSH ramdisk, DIAGS, Nicotine): any HomePod board will do.
    public static func bootBlocker(_ ib: IBootSerial) -> String? {
        notAHomePod(ib)
    }

    /// A note for a HomePod board that's unusual but allowed (nil = nothing to say).
    public static func boardNote(_ ib: IBootSerial) -> String? {
        guard let board = ib.a8Board, board.kind != .otherProduct, !board.isRetailHomePod else { return nil }
        return restoreBlocker(ib)
    }

    static func notAHomePod(_ ib: IBootSerial) -> String? {
        guard ib.isA8 else { return notA8 }
        guard let bdid = ib.bdid else { return nil }
        guard let board = A8Board.identify(bdid) else {
            return String(format: "Unknown A8 board (board id 0x%02X). It isn't a HomePod board this app knows, so it won't work on it.", bdid)
        }
        if board.kind == .otherProduct {
            return "This is an \(board.productName) (\(board.label)), not a HomePod. It has the same A8 chip, but HomePod software won't run on it."
        }
        return nil
    }
}
