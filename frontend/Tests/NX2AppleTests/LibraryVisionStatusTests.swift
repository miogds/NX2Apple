import XCTest
@testable import NX2Apple
import NXCore

/// The library names the device a game was built for: a Vision Pro build never says iPhone.
final class LibraryVisionStatusTests: XCTestCase {
    private func game() -> LibraryGame { LibraryGame(titleID: "0100000000001000", name: "Game") }

    /// A shared app on disk in `root`, so the game counts as installed with it.
    private func installed(_ g: inout LibraryGame, root: String) throws {
        let app = ShellInstall.appPath(root: root)
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: app + "/Info.plist"))
        g.iosAppPath = app; g.installedDevice = "UDID"
    }
    private var folder = ""
    override func setUp() { folder = FileManager.default.temporaryDirectory.appendingPathComponent("nx-vision-\(UUID().uuidString)").path }
    override func tearDown() { try? FileManager.default.removeItem(atPath: folder) }

    func testAGameInstalledWithTheVisionAppSaysVisionPro() throws {
        var g = game()
        try installed(&g, root: DevicePlatform.visionos.root(folder + "/shell"))
        XCTAssertEqual(g.devicePlatform, .visionos)
        XCTAssertEqual(g.statusKey, "library.readyOnVision")
        XCTAssertEqual(g.deviceSymbol, "visionpro")
        XCTAssertFalse(g.hasIPhoneBuild)
    }

    func testAGameOnTheShelfAloneIsReadyForTheHeadset() {
        var g = game()
        XCTAssertEqual(g.statusKey, "library.notBuilt")
        g.onVisionShelf = true
        XCTAssertEqual(g.statusKey, "library.readyVision")
        XCTAssertEqual(g.deviceSymbol, "visionpro")
    }

    func testAnIPhoneGameIsUnchangedAndABuildForBothNamesBoth() throws {
        var g = game()
        try installed(&g, root: folder + "/shell")
        XCTAssertEqual(g.statusKey, "library.readyOnIOS")
        XCTAssertEqual(g.deviceSymbol, "iphone")
        g.onVisionShelf = true
        XCTAssertEqual(g.statusKey, "library.readyIOSAndVision")
        XCTAssertEqual(g.deviceSymbol, "iphone", "the installed app is the iPhone's")
    }

    func testEveryLanguageHasTheVisionTexts() {
        for key in ["library.readyVision", "library.readyOnVision", "library.readyMacAndVision", "library.readyIOSAndVision", "library.readyAll"] {
            XCTAssertNotNil(L10n.table[key], key); XCTAssertNotNil(L10n.de[key], key); XCTAssertNotNil(L10n.sv[key], key)
        }
    }
}
