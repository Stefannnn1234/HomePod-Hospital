import Foundation

/// Every external link the app shows lives here so it's easy to update.
/// Most of these can also be overridden remotely through `manifest.json`
/// (see `PrebuiltManifest`) without shipping a new build.
public enum Links {
    public static let discord = URL(string: "https://discord.gg/nicsfix")!
    /// TODO(Nic): replace with your real PayPal donation link (paypal.me/… or a
    /// paypal.com/donate/?hosted_button_id=… link). Can also be set remotely
    /// via the "donateURL" key in manifest.json.
    public static let donate = URL(string: "https://www.paypal.com/donate/?business=nicsfix")!
    public static let website = URL(string: "https://nicsfix.com")!
    public static let shop = URL(string: "https://nicsfix.com/shop")!
    public static let guide = URL(string: "https://github.com/UnbendableStraw/homepod-restore")!
    public static let knownErrorsSheet = URL(string: "https://docs.google.com/spreadsheets/d/1Fvoa8zhKQzLCrZxgvBHMtxuQuXDyvi9EKi9KwdjbxGo/edit?usp=sharing")!

    /// Remote catalog of prebuilt firmware + link overrides. Upload
    /// `Distribution/manifest.json` from this repo to this location.
    public static let manifest = URL(string: "https://nicsfix.com/ipsw/manifest.json")!

    /// Fallback prebuilt firmware used when the manifest can't be reached.
    public static let fallbackPrebuiltIPSW = URL(string: "https://nicsfix.com/ipsw/18.3.ipsw")!

    // Build-your-own inputs
    public static let makeipswScript = URL(string: "https://raw.githubusercontent.com/tihmstar/homepodstuff/main/makeipsw.sh")!
    public static let firmwareKeysZip = URL(string: "https://raw.githubusercontent.com/UnbendableStraw/homepod-restore/main/firmware_keys.zip")!
    public static func ipswMeDevice(_ identifier: String, type: String) -> URL {
        URL(string: "https://api.ipsw.me/v4/device/\(identifier)?type=\(type)")!
    }

    public static let homebrew = URL(string: "https://brew.sh")!
}

/// People whose work makes this possible. Shown on the Credits screen.
public struct Credit: Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let role: String
    public let links: [(title: String, url: URL)]

    public static func == (a: Credit, b: Credit) -> Bool { a.name == b.name }
    public func hash(into h: inout Hasher) { h.combine(name) }

    public static let all: [Credit] = [
        Credit(name: "tihmstar",
               role: "makeipsw.sh, ra1nsn0w, img4tool, tsschecker and the HomePod restore research",
               links: [("GitHub", URL(string: "https://github.com/tihmstar")!),
                       ("Patreon", URL(string: "https://www.patreon.com/tihmstar")!)]),
        Credit(name: "David Ryskalczyk",
               role: "ios-restore-tools Homebrew tap and libimobiledevice fixes for HomePod restores",
               links: [("GitHub", URL(string: "https://github.com/d235j")!)]),
        Credit(name: "0x7ff",
               role: "gaster (checkm8 exploit tool)",
               links: [("GitHub", URL(string: "https://github.com/0x7ff/gaster")!)]),
        Credit(name: "libimobiledevice",
               role: "idevicerestore, libirecovery, libimobiledevice",
               links: [("GitHub", URL(string: "https://github.com/libimobiledevice")!)]),
        Credit(name: "Nic's Fix",
               role: "Restore guide, prebuilt firmware and this app",
               links: [("Website", Links.website),
                       ("Guide", Links.guide),
                       ("Discord", Links.discord)]),
    ]
}
