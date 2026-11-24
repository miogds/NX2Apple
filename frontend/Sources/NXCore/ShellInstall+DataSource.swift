import Darwin
import Foundation

/// Where the shared app on a device downloads game data from (`DataServer`): this Mac's addresses and the token. The Mac writes
/// it into the app's `Documents/data-source.json` with the install, and the app offers Download for a game whose data it lacks.
package struct DataSourceOffer: Codable, Equatable {
    package static let fileName = "data-source.json"

    package var version = 1
    package var name: String
    /// `http://host:port`, the first that answers is used: the Mac's Bonjour name first, then its addresses.
    package var urls: [String]
    package var token: String

    package init(name: String, urls: [String], token: String) { self.name = name; self.urls = urls; self.token = token }

    /// The Mac's `.local` name and its IPv4 addresses on the local network, each with the server's port.
    package static func urls(port: UInt16, hostName: String = ProcessInfo.processInfo.hostName, addresses: [String] = localAddresses()) -> [String] {
        var hosts: [String] = []
        let host = hostName.trimmingCharacters(in: .whitespaces)
        if host.lowercased().hasSuffix(".local") { hosts.append(host) }
        hosts += addresses
        return hosts.map { "http://\($0):\(port)" }
    }

    /// The IPv4 addresses of the interfaces that are up, without loopback and link-local ones.
    package static func localAddresses() -> [String] {
        var found: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var next = list
        while let entry = next {
            defer { next = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: name)
            if !text.hasPrefix("169.254."), !found.contains(text) { found.append(text) }
        }
        return found
    }

    /// A token of 32 hex digits.
    package static func newToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}

extension ShellInstall {
    /// A game's data as the device stores it: the archive's files, the primary image under the name `romfs.img` (as the copy
    /// through devicectl names it, `prepareDeviceDiff`), so a download and a copy leave the same folder.
    package static func servedFiles(archive: String, titleID: String, shellRoot: String? = nil, fm: FileManager = .default) -> [String: ServedFile] {
        let transfer = transferSources(archive: archive, shellRoot: shellRoot, titleID: titleID, fm: fm)
        var sizes = transfer.sizes, origins = transfer.origins
        if let primary = RomFSArchive.primaryImageName(inFiles: sizes.keys, folderName: (archive as NSString).lastPathComponent),
           let size = sizes[primary] {
            let source = origins[primary] ?? (archive + "/" + primary)
            for key in sizes.keys where !key.contains("/") && !key.contains("\\") {
                let lower = key.lowercased()
                if lower.hasSuffix(".img") && !lower.contains(".nxpart") { sizes.removeValue(forKey: key); origins.removeValue(forKey: key) }
            }
            sizes["romfs.img"] = size; origins["romfs.img"] = source
        }
        return Dictionary(uniqueKeysWithValues: sizes.map { ($0.key, ServedFile(size: $0.value, path: origins[$0.key] ?? (archive + "/" + $0.key))) })
    }

    /// The files of a signed framework by their path inside it, as the device counts them (`ShellHotInstall.frameworkFootprint`).
    package static func servedCode(framework: String, fm: FileManager = .default) -> [String: ServedFile] {
        var found: [String: ServedFile] = [:]
        guard let enumerator = fm.enumerator(atPath: framework) else { return found }
        for case let path as String in enumerator {
            let name = (path as NSString).lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") { continue }
            guard let attributes = try? fm.attributesOfItem(atPath: framework + "/" + path), attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else { continue }
            found[path] = ServedFile(size: size.int64Value, path: framework + "/" + path)
        }
        return found
    }

    /// Where the signed copy of a game's framework is kept for the server.
    package static func shelf(root: String, titleID: String) -> String { root + "/shelf/" + titleID.uppercased() }

    package static func dataSourceCommand(xcrun: String, device: String, bundleID: String, source: String) -> [String] {
        [xcrun, "devicectl", "device", "copy", "to", "--device", device, "--source", source,
         "--destination", "Documents/" + DataSourceOffer.fileName, "--domain-type", "appDataContainer", "--domain-identifier", bundleID]
    }
}

extension ShellInstaller {
    /// Instead of the copy: tells the app on the device where this Mac serves the game data, so the player downloads it there
    /// (pause, resume, progress on the device). nil when the note could not be written: the copy through devicectl then runs.
    func offerDownload(_ offer: DataSourceOffer, signed: (outcome: Outcome, notes: [String])) -> Outcome? {
        let file = NSTemporaryDirectory() + "nspb-data-source-\(UUID().uuidString.prefix(8)).json"
        defer { try? FileManager.default.removeItem(atPath: file) }
        guard let json = try? JSONEncoder().encode(offer), (try? json.write(to: URL(fileURLWithPath: file))) != nil else { return nil }
        let label = fmt("shell.checkStage", deviceName)
        let sent = run(ShellInstall.dataSourceCommand(xcrun: xcrun, device: device, bundleID: signed.outcome.bundleID, source: file),
                       env: nil, label: label, step: { _ in nil })
        guard sent.status == 0 else {
            log("download offer: could not be written to the device, the game data is copied from here instead\n")
            return nil
        }
        var outcome = signed.outcome
        outcome.message = ([fmt("shell.downloadOffered", deviceName)] + signed.notes).joined(separator: "\n")
        return outcome
    }
}

extension ShellInstaller {
    /// A copy of the game's framework signed for the shared app of this team (as a hot install signs it), kept in the shell
    /// folder for the server: the app on a device downloads it and loads it without an install. nil when it cannot be signed
    /// (no shell yet, no certificate of the team on this Mac, a framework without its own host): the game then reaches a device
    /// with the app's install only.
    package func shelve(framework: String, titleID: String) -> String? {
        let fm = FileManager.default
        guard !team.isEmpty, ShellHotInstall.supportsHotPush(framework: framework, titleID: titleID, fm: fm),
              fm.fileExists(atPath: ShellLibrary.stateFile(root: root)) else { return nil }
        let bundleID = ShellLibrary.load(root: root).bundleID
        guard !bundleID.isEmpty, let identity = signingIdentity(team, runner), !identity.isEmpty else {
            log("shelf: no development certificate of team \(team) on this Mac, the game's code is not offered for download\n")
            return nil
        }
        let folder = ShellInstall.shelf(root: root, titleID: titleID)
        let copy = folder + "/" + (framework as NSString).lastPathComponent
        try? fm.removeItem(atPath: folder)
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try fm.copyItem(atPath: framework, toPath: copy)
        } catch {
            log("shelf: \(error.localizedDescription)\n")
            return nil
        }
        _ = ShellInstall.placeBanner(titleID: titleID, framework: copy, banners: banners, picked: pickedArtwork)
        _ = run(ShellHotInstall.cleanFrameworkAttributesCommand(framework: copy), env: nil, label: "shelf", step: { _ in nil })
        let signed = run(ShellHotInstall.codesignFrameworkCommand(codesign: codesignPath, identity: identity, bundleIdentifier: bundleID, framework: copy),
                         env: nil, label: "shelf", step: { _ in nil })
        guard signed.status == 0 else {
            try? fm.removeItem(atPath: folder)
            log("shelf: signing the framework failed, the game's code is not offered for download\n")
            return nil
        }
        return copy
    }
}

extension ShellInstaller {
    /// The shared app alone onto the device, with the games the library already holds (none at first) and no game data: the
    /// app then gets every other game from this Mac's server. Needed once, and again when the app itself changes or its
    /// signature runs out, never for a new game.
    package func installLauncher() -> Outcome {
        let signed = signAndInstallApp(framework: "", titleID: "", name: "")
        guard signed.outcome.ok else { return signed.outcome }
        if let dataSource, let offered = offerDownload(dataSource, signed: signed) {
            var outcome = offered
            outcome.message = ([fmt("shell.launcherInstalled", deviceName)] + signed.notes).joined(separator: "\n")
            return outcome
        }
        return signed.outcome
    }

    /// A built game onto this Mac's shelf, with no device: its code signed for the shared app. The app downloads it and the
    /// game's data when it is opened. Fails when the app was never installed from here (its identifier is not known yet).
    package func shelveGame(framework: String, titleID: String, name: String) -> (outcome: Outcome, code: String) {
        guard FileManager.default.fileExists(atPath: framework) else { return (missingFramework(framework, name: name), "") }
        guard let code = shelve(framework: framework, titleID: titleID) else {
            return (Outcome(ok: false, message: t("shell.shelfNeedsLauncher")), "")
        }
        return (Outcome(ok: true, message: fmt("shell.shelved", name)), code)
    }
}
