import Foundation
import ShellUI

/// The two sides of the library of an app that has a Mac to download from.
public enum LibrarySource: Sendable { case device, mac }

/// The Mac that installed the app: none known (no download side), not asked yet, answering, or silent.
public enum MacStatus: Equatable, Sendable {
    case none, asking(String), reachable(String), unreachable(String)
}

/// Game data the app downloads itself from the Mac that installed it (DataDownloads.swift): what the library shows for a game
/// whose data is missing, and what its button does.
extension ShellHostModel {
    /// A game is on the Mac's side while its data is not on this device: waiting, offered, or downloading.
    static func isOnMac(_ state: GameState) -> Bool {
        switch state {
        case .needsGameData, .downloadAvailable, .downloadingGameData: true
        default: false
        }
    }

    /// The library is in two sides once the app knows a Mac. Without one it is one list, as before.
    public var hasMacSide: Bool { macStatus != .none }
    public var deviceGames: [GameDetail] { details.filter { !Self.isOnMac($0.game.state) } }
    public var macGames: [GameDetail] { details.filter { Self.isOnMac($0.game.state) } }
    /// What the library shows: everything, or the chosen side.
    public var shownGames: [GameDetail] {
        guard hasMacSide else { return details }
        return librarySource == .mac ? macGames : deviceGames
    }

    /// One line under the switch: why the Mac's side shows no button, or that a side is empty. Empty: nothing to say.
    public var librarySideNote: String {
        guard hasMacSide else { return "" }
        if librarySource == .device {
            return deviceGames.isEmpty && !macGames.isEmpty ? hostText("No game is on this device yet. Look under On the Mac.") : ""
        }
        switch macStatus {
        case .unreachable(let name):
            return hostText("\(name) does not answer. Open NX2Apple on the Mac, on the same network, and allow Local Network for this app in Settings.")
        case .reachable(let name):
            return macGames.isEmpty ? hostText("Every game \(name) has for this app is already on this device.") : ""
        case .asking, .none:
            return ""
        }
    }

    func setUpDownloads() {
        guard let downloads = config.downloads else { return }
        let made = DataDownloader(appDataRoot: config.appDataRoot, stateFolder: downloads.stateFolder, sessionID: downloads.sessionID)
        made.onChange = { [weak self] id in self?.refresh(id) }
        made.onFinished = { [weak self] id in
            self?.dataOffers.removeValue(forKey: id)
            self?.reload()
        }
        downloader = made
        refreshDataOffers()
    }

    /// Asks the Mac what it serves, at start and each time the app comes to the front. Without an answer the offers go: a
    /// Download button that cannot work is not shown. A running or paused download stays shown either way.
    func refreshDataOffers(then: (@MainActor () -> Void)? = nil) {
        guard config.downloads != nil else { return }
        let documents = config.appDataRoot.deletingLastPathComponent()
        let appDataRoot = config.appDataRoot
        let ids = Set(entries.map(\.id))
        offersTask?.cancel()
        offersTask = Task { [weak self] in
            var found: [String: DataOffer] = [:]
            var newGames: [DataSourceList.Game] = [], source: (base: URL, token: String)?
            var status = MacStatus.none
            if let offer = await Task.detached(priority: .utility, operation: { DataSourceOffer.read(documents: documents) }).value {
                if self?.macStatus == MacStatus.none { self?.macStatus = .asking(offer.name) }
                if let answer = await DataSourceClient.list(of: offer) {
                    found = DataDownloadPlan.offers(list: answer.list, base: answer.base, token: offer.token, ids: ids, appDataRoot: appDataRoot)
                    newGames = answer.list.games.filter { !ids.contains($0.titleID) }
                    source = (answer.base, offer.token)
                    status = .reachable(answer.list.name.isEmpty ? offer.name : answer.list.name)
                } else {
                    status = .unreachable(offer.name)
                }
            }
            guard let self, !Task.isCancelled else { return }
            if self.macStatus != status { self.macStatus = status }
            if let source, !newGames.isEmpty { self.adopt(newGames, base: source.base, token: source.token) }
            let changed = Set(found.keys).union(self.dataOffers.keys)
            self.dataOffers = found
            for id in changed { self.refresh(id) }
            then?()
            // A game still waits for its data and the Mac offered nothing (it was off, its launcher closed, the network not
            // allowed yet): asked again in a while, so the button appears without the app being reopened
            let waiting = self.details.contains { $0.game.state == .needsGameData }
            if waiting, !self.launchingGame {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                self.offersTask = nil
                self.refreshDataOffers()
            }
        }
    }

    /// The state of a game whose data is missing: its download when there is one, the offer to download when the Mac serves it.
    func downloadState(for id: String) -> GameState? {
        if let progress = downloader?.progress(id), progress.totalBytes > 0 {
            let percent = min(99, max(0, Int((Double(progress.doneBytes) / Double(progress.totalBytes) * 100).rounded(.down))))
            return .downloadingGameData(percent: percent, doneSize: Self.formatByteSize(progress.doneBytes),
                                        totalSize: Self.formatByteSize(progress.totalBytes), paused: progress.paused, error: progress.error)
        }
        if let offer = dataOffers[id] {
            return .downloadAvailable(size: Self.formatByteSize(offer.missingBytes), source: offer.source)
        }
        return nil
    }

    /// The button: starts the download, pauses a running one, resumes a paused one (asking the Mac again first, its address
    /// may have changed).
    public func downloadGameData(_ id: String) {
        guard let downloader else { return }
        if let progress = downloader.progress(id) {
            if !progress.paused { return downloader.pause(id) }
            refreshDataOffers { [weak self] in
                guard let self else { return }
                if let offer = self.dataOffers[id] {
                    downloader.resume(id, offer: offer)
                } else {
                    self.notice = hostText("The Mac did not answer. Open NX2Apple on the Mac, on the same network, and try again.")
                }
            }
        } else if let offer = dataOffers[id] {
            downloader.start(id, offer: offer)
        }
    }

    /// Games the Mac serves that are not in the library: one the player deleted here comes back (its code is still in the
    /// app), and one this app never had gets its code from the Mac. Either way it then shows with Download for its data.
    func adopt(_ games: [DataSourceList.Game], base: URL, token: String) {
        var brought = false
        for game in games where DataDownloadPlan.isTitleID(game.titleID) {
            let defaults = config.defaults(game.titleID)
            if defaults.string(forKey: GameDeletion.deletedKey) != nil {
                defaults.removeObject(forKey: GameDeletion.deletedKey)
                brought = true
                continue
            }
            guard let hotRoot = config.hotFrameworksRoot, CodeFetcher.isFetchable(game), !codeFetches.contains(game.titleID) else { continue }
            codeFetches.insert(game.titleID)
            Task { [weak self] in
                let fetched = await CodeFetcher.fetch(game, base: base, token: token, hotRoot: hotRoot)
                guard let self else { return }
                // A fetched game stays noted for this run: one the catalogue then refuses is not fetched over and over
                if !fetched { self.codeFetches.remove(game.titleID) }
                // The catalogue adopts the staged framework at the reload, and the offers are asked again for its data
                if fetched, !self.launchingGame { self.reload(); self.refreshDataOffers() }
            }
        }
        if brought, !launchingGame { reload(); refreshDataOffers() }
    }
}
