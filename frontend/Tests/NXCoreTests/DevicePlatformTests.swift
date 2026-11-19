import XCTest
@testable import NXCore

/// An Apple Vision Pro as a device of the shared app: the device listing keeps it, and the build, the shell folder and the products
/// follow its platform while an iPhone's stay as they were.
final class DevicePlatformTests: XCTestCase {
    private func listing(_ platform: String, reality: String = "physical") -> Data {
        let device: [String: Any] = [
            "hardwareProperties": ["reality": reality, "platform": platform, "udid": "UDID-" + platform, "marketingName": "Device"],
            "deviceProperties": ["name": platform, "osVersionNumber": "27.2"],
            "connectionProperties": ["pairingState": "paired", "transportType": "localNetwork"]]
        return try! JSONSerialization.data(withJSONObject: ["result": ["devices": [device]]])
    }

    func testTheListingKeepsAVisionProWithItsPlatform() {
        XCTAssertEqual(DeviceTools.parseDevices(listing("visionOS")).map(\.platform), [.visionos])
        XCTAssertEqual(DeviceTools.parseDevices(listing("xrOS")).map(\.platform), [.visionos])
        XCTAssertEqual(DeviceTools.parseDevices(listing("iOS")).map(\.platform), [.ios])
    }

    func testOtherDevicesAndSimulatorsStayOut() {
        XCTAssertEqual(DeviceTools.parseDevices(listing("watchOS")), [])
        XCTAssertEqual(DeviceTools.parseDevices(listing("tvOS")), [])
        XCTAssertEqual(DeviceTools.parseDevices(listing("visionOS", reality: "simulated")), [])
    }

    func testTheScriptBuildsAVisionFrameworkInAFolderOfItsOwn() {
        XCTAssertEqual(ShellInstall.buildArguments(workDir: "/w", team: "TEAM", platform: .visionos),
                       ["--platform", "visionos", "--shell-framework", "/w/shell-framework-xros", "--team-id", "TEAM"])
        XCTAssertEqual(ShellInstall.frameworkPath(workDir: "/w", titleID: "0100", platform: .visionos), "/w/shell-framework-xros/DmGame0100.framework")
    }

    func testAnIPhoneBuildIsUnchanged() {
        XCTAssertEqual(ShellInstall.buildArguments(workDir: "/w", team: ""), ["--shell-framework", "/w/shell-framework"])
        XCTAssertEqual(ShellInstall.frameworkPath(workDir: "/w", titleID: "0100"), "/w/shell-framework/DmGame0100.framework")
        XCTAssertEqual(ShellInstall.appPath(root: "/s/shell"), "/s/shell/derived-data/Build/Products/Release-iphoneos/DmShell.app")
        XCTAssertNil(ShellInstall.projectEnvironment(root: "/s/shell", frameworks: [], bundleID: "b", team: "t", python: "py", path: "", home: "", user: "")["DM_SDK"])
    }

    func testTheVisionShellFolderIsBesideTheIPhonesAndNamesItsPlatform() {
        let root = DevicePlatform.visionos.root("/s/shell")
        XCTAssertEqual(root, "/s/shell-visionos")
        XCTAssertEqual(DevicePlatform.ios.root("/s/shell"), "/s/shell")
        XCTAssertEqual(DevicePlatform(root: root), .visionos)
        XCTAssertEqual(DevicePlatform(root: "/s/shell"), .ios)
        XCTAssertEqual(ShellInstall.appPath(root: root), "/s/shell-visionos/derived-data/Build/Products/Release-xros/DmShell.app")
        XCTAssertEqual(ShellInstall.projectEnvironment(root: root, frameworks: [], bundleID: "b", team: "t", python: "py", path: "", home: "", user: "")["DM_SDK"], "xros")
        // A re-sign finds the folder again from the installed app's path
        XCTAssertEqual(ShellInstall.paths(ofApp: ShellInstall.appPath(root: root))?.root, root)
    }

    func testTheStepsAfterABuildTakeTheNewestFrameworkOfEitherPlatform() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("nx-platform-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: work) }
        let ios = work + "/shell-framework/DmGame0100.framework", vision = work + "/shell-framework-xros/DmGame0100.framework"
        try fm.createDirectory(atPath: ios, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: vision, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: ios)
        XCTAssertEqual(ShellInstall.builtFramework(workDir: work), vision)
        XCTAssertEqual(ShellInstall.builtFramework(workDir: work, platform: .ios), ios)
        XCTAssertEqual(ShellInstall.builtFramework(workDir: work, platform: .visionos), vision)
    }
}
