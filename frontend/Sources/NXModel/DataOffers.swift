import Foundation
import NXCore

/// The game data this Mac serves to the shared app on a device (`DataServer`, NXCore): which games, the token, the port. A game
/// is added when it is installed for a device that downloads its data itself, and the list is kept, so the server offers the
/// same games again when the launcher is opened later.
package final class DataOffers: @unchecked Sendable {
    package static let tokenKey = "dataServerToken"
    package static let portKey = "dataServerPort"
    package static let gamesKey = "dataServerGames"
    /// The port asked for first. Another one is used (and remembered) when it is taken.
    package static let defaultPort = 47810

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var server: DataServer?
    private var port: UInt16 = 0
    private var games: [String: (name: String, archive: String, shellRoot: String, code: String)] = [:]
    package var log: @Sendable (String) -> Void = { _ in }

    package init(defaults: UserDefaults) {
        self.defaults = defaults
        for (titleID, value) in defaults.dictionary(forKey: Self.gamesKey) ?? [:] {
            guard let entry = value as? [String: String], let archive = entry["archive"] else { continue }
            games[titleID] = (entry["name"] ?? titleID, archive, entry["shellRoot"] ?? "", entry["code"] ?? "")
        }
    }

    /// The games whose data folder is still there, with their files as the device stores them.
    package var served: [ServedGame] {
        lock.lock(); let known = games; lock.unlock()
        return known.compactMap { titleID, game in
            let files = ShellInstall.servedFiles(archive: game.archive, titleID: titleID, shellRoot: game.shellRoot.isEmpty ? nil : game.shellRoot)
            guard !files.isEmpty else { return nil }
            return ServedGame(titleID: titleID, name: game.name, files: files, framework: (game.code as NSString).lastPathComponent,
                              code: game.code.isEmpty ? [:] : ShellInstall.servedCode(framework: game.code))
        }
    }

    /// `code` is the signed copy of the game's framework (`ShellInstaller.shelve`), empty when there is none.
    package func register(titleID: String, name: String, archive: String, shellRoot: String, code: String = "") {
        guard !titleID.isEmpty, !archive.isEmpty else { return }
        lock.lock()
        games[titleID] = (name, archive, shellRoot, code)
        let stored = games.mapValues { ["name": $0.name, "archive": $0.archive, "shellRoot": $0.shellRoot, "code": $0.code] }
        lock.unlock()
        defaults.set(stored, forKey: Self.gamesKey)
    }

    /// Starts the server when it does not run yet, also with nothing to serve yet (the app on a device is told its address at
    /// the install, before the first game is built). Returns its port, 0 when it could not start.
    @discardableResult package func start() -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        if server != nil { return port }
        let made = DataServer(name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName, token: token) { [weak self] in self?.served ?? [] }
        made.log = log
        let stored = defaults.integer(forKey: Self.portKey)
        guard let listening = try? made.start(preferred: UInt16(clamping: stored > 0 ? stored : Self.defaultPort)) else { return 0 }
        defaults.set(Int(listening), forKey: Self.portKey)
        server = made; port = listening
        return listening
    }

    package func stop() {
        lock.lock(); server?.stop(); server = nil; port = 0; lock.unlock()
    }

    private var token: String {
        if let stored = defaults.string(forKey: Self.tokenKey), !stored.isEmpty { return stored }
        let made = DataSourceOffer.newToken()
        defaults.set(made, forKey: Self.tokenKey)
        return made
    }

    /// What the device needs to download from here, nil when the server could not start.
    package func offer() -> DataSourceOffer? {
        let listening = start()
        guard listening > 0 else { return nil }
        return DataSourceOffer(name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                               urls: DataSourceOffer.urls(port: listening), token: token)
    }
}
