import Foundation
import NXCore
import NXModel

extension GameLibrary {
    /// Records a finished iOS build into the library: framework/app/archive/IPA and device provenance.
    func recordCompletedIOS(archive: String, app: String, device: String = "", commit: String = "", ipa: String = "", for id: UUID) {
        guard var game = games.first(where: { $0.id == id }) else { return }
        let appExists = !app.isEmpty && FileManager.default.fileExists(atPath: app + "/Info.plist")
        if !app.isEmpty && !appExists && archive.isEmpty && ipa.isEmpty { return }
        if !archive.isEmpty {
            if RomFSArchive.primaryImagePath(in: archive) != nil || FileManager.default.fileExists(atPath: archive) {
                game.archivePath = archive
            }
        }
        if appExists {
            if ipa.isEmpty { game.ipaPath = "" }
            game.iosAppPath = app
            if !device.isEmpty {
                game.installedDevice = device
            } else if !game.installedViaShellReceipt {
                game.installedDevice = ""
            }
            game.toolsCommit = commit
        } else if !commit.isEmpty {
            game.toolsCommit = commit
        }
        if !ipa.isEmpty {
            if (ipa as NSString).lastPathComponent.lowercased() != "nx2apple.ipa" {
                game.ipaPath = ipa
            } else {
                game.shellIPAExists = true
            }
        }
        game.lastTarget = BuildTarget.ios
        upsert(game)
        if appExists && !device.isEmpty {
            recordSharedAppInstalled(app: app, device: device)
        }
    }

    /// Every game in the shared app's shell.json is inside `app` on `device` once the shared app is signed and installed there.
    func recordSharedAppInstalled(app: String, device: String) {
        guard !device.isEmpty,
              FileManager.default.fileExists(atPath: app + "/Info.plist"),
              let shell = ShellInstall.paths(ofApp: app) else { return }
        applySharedAppInstalled(titles: ShellLibrary.recordInstalled(root: shell.root, device: device), app: app, device: device)
    }

    private func applySharedAppInstalled(titles: Set<String>, app: String, device: String) {
        guard !device.isEmpty, !titles.isEmpty else { return }
        var changed = false
        for i in games.indices where titles.contains(games[i].titleID.uppercased()) {
            if games[i].iosAppPath != app || games[i].installedDevice != device || !games[i].ipaPath.isEmpty || !games[i].installedViaShellReceipt {
                games[i].ipaPath = ""
                games[i].iosAppPath = app
                games[i].installedDevice = device
                games[i].installedViaShellReceipt = true
                changed = true
            }
        }
        if changed { save() }
    }

    /// Restores the shared app's games from shell.json, frameworks, export IPAs, and the last successful install receipt.
    /// Works cleanly even when `<root>/derived-data` is absent or empty.
    func syncSharedApp(root: String, fallbackDevice: String = "") {
        let fm = FileManager.default
        let shellLib = ShellLibrary.load(root: root)
        let receipt = ShellLibrary.installedReceipt(root: root)
        let receiptDevice = ShellLibrary.installedDevice(root: root)
        let app = ShellInstall.appPath(root: root)
        let hasSignedApp = fm.fileExists(atPath: app + "/" + AppSignature.profileName)
        let defaultIPA = ShellInstall.ipaPath(root: root)
        let hasDefaultIPA = fm.fileExists(atPath: defaultIPA)

        // Prefer the device UDID recorded with the install receipt, else any existing game in receipt, else the paired target device.
        let existingDevice = games.first(where: {
            receipt.contains($0.titleID.uppercased()) && !$0.installedDevice.isEmpty
        })?.installedDevice ?? ""
        let trimmedFallback = fallbackDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = !receiptDevice.isEmpty ? receiptDevice : (!existingDevice.isEmpty ? existingDevice : trimmedFallback)
        if receiptDevice.isEmpty && !device.isEmpty && !receipt.isEmpty {
            ShellLibrary.recordInstalledDevice(device, root: root)
        }

        var changed = false
        for i in games.indices {
            let tid = games[i].titleID.uppercased()
            let inShell = shellLib.games.contains(where: { $0.titleID.uppercased() == tid })
            let inReceipt = receipt.contains(tid)
            let mirror = ShellInstall.mirroredFramework(root: root, titleID: games[i].titleID)
            let hasFramework = fm.fileExists(atPath: mirror)

            let onShelf = !tid.isEmpty && fm.fileExists(atPath: ShellInstall.shelf(root: DevicePlatform.visionos.root(root), titleID: tid))
            if games[i].onVisionShelf != onShelf {
                games[i].onVisionShelf = onShelf
                changed = true
            }

            let newHasFramework = inShell || hasFramework
            if games[i].hasShellFramework != newHasFramework {
                games[i].hasShellFramework = newHasFramework
                changed = true
            }

            let newInReceipt = inReceipt
            if games[i].installedViaShellReceipt != newInReceipt {
                games[i].installedViaShellReceipt = newInReceipt
                changed = true
            }

            let hasExplicitSharedIPA = !games[i].ipaPath.isEmpty
                && (games[i].ipaPath as NSString).lastPathComponent.lowercased() == "nx2apple.ipa"
                && fm.fileExists(atPath: games[i].ipaPath)
            let newShellIPA = (inShell || hasFramework) && (hasDefaultIPA || hasExplicitSharedIPA)
            if games[i].shellIPAExists != newShellIPA {
                games[i].shellIPAExists = newShellIPA
                changed = true
            }

            if inShell || hasFramework || inReceipt {
                if hasSignedApp && inReceipt {
                    if games[i].iosAppPath != app {
                        games[i].iosAppPath = app
                        changed = true
                    }
                    if !device.isEmpty && games[i].installedDevice != device {
                        games[i].installedDevice = device
                        changed = true
                    }
                } else if inReceipt && !device.isEmpty && games[i].installedDevice.isEmpty {
                    games[i].installedDevice = device
                    changed = true
                }
                if games[i].appPath.isEmpty && games[i].lastTarget != BuildTarget.ios {
                    games[i].lastTarget = BuildTarget.ios
                    changed = true
                }
            }
        }
        if changed { save() }
    }
}

extension LibraryGame {
    /// True when this game has a built shell framework recorded for the shell.
    var hasIOSFramework: Bool {
        hasShellFramework
    }

    /// True when this game has an exported IPA on disk or shared shell IPA recorded.
    var hasIPA: Bool {
        if !ipaPath.isEmpty && FileManager.default.fileExists(atPath: ipaPath) { return true }
        return shellIPAExists
    }

    /// Standalone iOS .app bundle on disk.
    var hasIOSApp: Bool {
        !iosAppPath.isEmpty && FileManager.default.fileExists(atPath: iosAppPath + "/Info.plist")
    }

    /// Signed and installed on a paired device (installedDevice is its UDID): Play starts it there.
    var onDevice: Bool {
        guard !installedDevice.isEmpty else { return false }
        return hasIOSApp || installedViaShellReceipt
    }

    /// The installed shared app is the visionOS one: its path names its shell folder, and the headset's has one of its own.
    private var appIsVision: Bool {
        ShellInstall.paths(ofApp: iosAppPath).map { DevicePlatform(root: $0.root) == .visionos } ?? false
    }

    /// Built for an Apple Vision Pro: installed with the headset's app, or kept on this Mac for the headset to download.
    var hasVisionBuild: Bool { onVisionShelf || (hasIOSApp && appIsVision) }

    /// Built for an iPhone or iPad. `hasIOSBuild` counts the headset's app too (it is recorded the same way), so that is taken out.
    var hasIPhoneBuild: Bool { hasIPA || hasShellFramework || installedViaShellReceipt || (hasIOSApp && !appIsVision) }

    /// Built for a device of either kind.
    var hasDeviceBuild: Bool { hasIOSBuild || onVisionShelf }

    /// The device the installed app is on, else the only kind of device this game was built for.
    var devicePlatform: DevicePlatform {
        if hasIOSApp { return appIsVision ? .visionos : .ios }
        return hasVisionBuild && !hasIPhoneBuild ? .visionos : .ios
    }

    /// The library's status line for a game that is not being built. It names every platform the game was built for.
    var statusKey: String {
        switch (isReady, hasIPhoneBuild, hasVisionBuild) {
        case (true, true, true): return "library.readyAll"
        case (true, true, false): return "library.readyMacAndIOS"
        case (true, false, true): return "library.readyMacAndVision"
        case (true, false, false): return "library.ready"
        case (false, true, true): return "library.readyIOSAndVision"
        case (false, false, true): return onDevice ? "library.readyOnVision" : "library.readyVision"
        case (false, true, false): return onDevice ? "library.readyOnIOS" : (isOlderIOSBuild ? "library.olderIOS" : "library.readyIOS")
        case (false, false, false): return hasIOSBuild ? "library.readyIOS" : "library.notBuilt"
        }
    }

    /// The symbol of the device the game is on: the headset for a Vision Pro build.
    var deviceSymbol: String { devicePlatform == .visionos ? "visionpro" : "iphone" }

    /// An iPhone or iPad game runs only cheats that write data.
    var cheatsNeedIOSNote: Bool { hasIOSBuild || onDevice }

    /// Recognizes any valid iOS build: exported IPA, installed/built app, built shell framework, or on-device receipt.
    var hasIOSBuild: Bool {
        hasIPA || hasIOSApp || hasShellFramework || onDevice
    }

    /// Recognizes any valid iOS build, also probing `shellRoot/frameworks/DmGame<TID>.framework` when `shellRoot` is non-empty.
    func hasIOSBuild(shellRoot: String, fm: FileManager = .default) -> Bool {
        if hasIOSBuild { return true }
        let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !shellRoot.isEmpty, !tid.isEmpty else { return false }
        return ShellInstall.missingFile(
            inFramework: ShellInstall.mirroredFramework(root: shellRoot, titleID: tid),
            titleID: tid,
            fm: fm
        ) == nil
    }

    /// An iPhone build made before the shared app: a legacy single IPA or standalone app.
    var isOlderIOSBuild: Bool {
        guard hasIOSBuild else { return false }
        if hasShellFramework || installedViaShellReceipt || shellIPAExists { return false }
        if hasIOSApp && ShellInstall.paths(ofApp: iosAppPath) != nil { return false }
        if !ipaPath.isEmpty {
            let ipaURL = URL(fileURLWithPath: ipaPath)
            if ipaURL.lastPathComponent.lowercased() == "nx2apple.ipa" || ipaURL.pathExtension.lowercased() == "framework" {
                return false
            }
        }
        return true
    }
}
