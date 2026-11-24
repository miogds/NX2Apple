import Foundation

/// Game data this app downloads itself, instead of the Mac copying it in through devicectl: the player starts, pauses and
/// resumes it here, and a download that stopped (the connection dropped, the device slept, the app was closed) goes on where
/// it was. Only game data is downloaded, never a game's code: that is in the app the Mac signs.
///
/// The Mac launcher writes `Documents/data-source.json` with the install (`DataSourceOffer`, the same shape as in the launcher's
/// NXCore): the Mac's addresses and a token. `GET <url>/v1/games` lists the games it serves with their files and sizes
/// (`DataSourceList`), `GET <url>/v1/games/<title ID>/files/<path>` is one file, with `Range`.
public struct DataSourceOffer: Codable, Equatable, Sendable {
    public static let fileName = "data-source.json"

    public var version = 1
    public var name: String
    public var urls: [String]
    public var token: String

    public init(name: String, urls: [String], token: String) { self.name = name; self.urls = urls; self.token = token }

    /// The offer in `documents`, nil without a readable one.
    public static func read(documents: URL) -> DataSourceOffer? {
        guard let data = try? Data(contentsOf: documents.appendingPathComponent(fileName)),
              let offer = try? JSONDecoder().decode(DataSourceOffer.self, from: data),
              !offer.token.isEmpty, !offer.urls.isEmpty else { return nil }
        return offer
    }
}

public struct DataSourceList: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var size: Int64
        public init(path: String, size: Int64) { self.path = path; self.size = size }
    }
    public struct Game: Codable, Equatable, Sendable {
        public var titleID: String
        public var name: String
        public var files: [File]
        /// The game's code, signed by the Mac for this app: the framework's folder name and its files. Nil: not offered.
        public var framework: String?
        public var code: [File]?
    }
    public var version = 1
    public var name: String
    public var games: [Game]
}

/// What one game can download: from where, and the files this device does not have yet.
public struct DataOffer: Equatable, Sendable {
    public var source: String
    public var base: URL
    public var token: String
    /// Every file of the game, and those of them this device lacks or has with another size.
    public var files: [DataSourceList.File]
    public var missing: [DataSourceList.File]
    public var missingBytes: Int64 { missing.reduce(0) { $0 + $1.size } }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum DataDownloadPlan {
    /// A path the server may name: relative, inside the game's folder, no hidden or parent components.
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0.hasPrefix(".") }
    }

    /// A title ID as a folder name: hex digits only.
    public static func isTitleID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.allSatisfy(\.isHexDigit)
    }

    /// The files of `files` that are not in `folder` with their size. Unsafe paths are left out: they are never fetched.
    public static func missing(_ files: [DataSourceList.File], in folder: URL, fileManager fm: FileManager = .default) -> [DataSourceList.File] {
        files.filter { file in
            guard isSafe(file.path), file.size >= 0 else { return false }
            let size = ((try? fm.attributesOfItem(atPath: folder.appendingPathComponent(file.path).path))?[.size] as? NSNumber)?.int64Value
            return size != file.size
        }
    }

    public static func fileURL(base: URL, titleID: String, path: String) -> URL {
        var url = base.appendingPathComponent("v1/games").appendingPathComponent(titleID).appendingPathComponent("files")
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }

    /// The offers of a list for the games in `ids`, each with what `appDataRoot/<title ID>` lacks. A game with nothing missing
    /// has no offer.
    public static func offers(list: DataSourceList, base: URL, token: String, ids: Set<String>, appDataRoot: URL,
                              fileManager fm: FileManager = .default) -> [String: DataOffer] {
        var found: [String: DataOffer] = [:]
        for game in list.games where ids.contains(game.titleID) && isTitleID(game.titleID) {
            let lacking = missing(game.files, in: appDataRoot.appendingPathComponent(game.titleID, isDirectory: true), fileManager: fm)
            guard !lacking.isEmpty else { continue }
            found[game.titleID] = DataOffer(source: list.name, base: base, token: token, files: game.files.filter { isSafe($0.path) }, missing: lacking)
        }
        return found
    }
}

/// Asks the source in `Documents/data-source.json` what it serves.
public enum DataSourceClient {
    /// The first of the offer's addresses that answers, with its list. nil when none does (the Mac is off, another network).
    public static func list(of offer: DataSourceOffer, timeout: TimeInterval = 4) async -> (base: URL, list: DataSourceList)? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        for text in offer.urls {
            guard let base = URL(string: text), base.scheme == "http" || base.scheme == "https" else { continue }
            var request = URLRequest(url: base.appendingPathComponent("v1/games"))
            request.setValue("Bearer " + offer.token, forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = try? JSONDecoder().decode(DataSourceList.self, from: data) else { continue }
            return (base, list)
        }
        return nil
    }
}

/// The downloads in flight, in a background session of the system: they go on while the app is not in front and the system
/// retries them when the network comes back. What is asked for is kept in `stateFolder`, so a paused download and one the app
/// was closed under are still known at the next start.
@MainActor public final class DataDownloader: NSObject {
    public struct Progress: Equatable, Sendable {
        public var doneBytes: Int64
        public var totalBytes: Int64
        public var paused: Bool
        /// Why it stopped by itself, empty when the player paused it or it runs.
        public var error: String
    }

    struct Job: Codable, Equatable {
        var titleID: String
        var source: String
        var base: URL
        var token: String
        var files: [DataSourceList.File]
        var paused = false
        var error = ""
    }

    /// What a task is for, in its `taskDescription`.
    struct TaskNote: Codable { var titleID: String; var path: String; var size: Int64 }

    private let appDataRoot: URL
    private let stateFolder: URL
    private let sessionID: String
    private var jobs: [String: Job] = [:]
    /// The bytes each running task has written, by title ID and path.
    private var written: [String: [String: Int64]] = [:]
    private var lastTold: [String: Date] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionID)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: configuration, delegate: Relay(owner: self, appDataRoot: appDataRoot), delegateQueue: nil)
    }()

    /// A game's progress changed (throttled), and a game's files are all here.
    public var onChange: (String) -> Void = { _ in }
    public var onFinished: (String) -> Void = { _ in }

    public init(appDataRoot: URL, stateFolder: URL, sessionID: String) {
        self.appDataRoot = appDataRoot; self.stateFolder = stateFolder; self.sessionID = sessionID
        super.init()
        try? FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: stateFile), let stored = try? JSONDecoder().decode([String: Job].self, from: data) { jobs = stored }
        guard !jobs.isEmpty else { return }
        // The tasks the system kept running while the app was closed: a job without one is paused
        let known = jobs
        session.getAllTasks { [weak self] tasks in
            let running = Set(tasks.compactMap { Self.note(of: $0)?.titleID })
            Task { @MainActor in
                guard let self else { return }
                for id in known.keys where !running.contains(id) && self.jobs[id]?.paused == false {
                    self.jobs[id]?.paused = true
                }
                self.save()
                for id in known.keys { self.settle(id) }
            }
        }
    }

    private var stateFile: URL { stateFolder.appendingPathComponent("downloads.json") }

    private func save() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: stateFile, options: .atomic)
    }

    nonisolated static func note(of task: URLSessionTask) -> TaskNote? {
        task.taskDescription.flatMap { try? JSONDecoder().decode(TaskNote.self, from: Data($0.utf8)) }
    }

    private func folder(_ id: String) -> URL { appDataRoot.appendingPathComponent(id, isDirectory: true) }

    private func resumeFile(_ id: String, _ path: String) -> URL {
        let name = Data((id + "/" + path).utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return stateFolder.appendingPathComponent(name + ".resume")
    }

    // MARK: What the library shows

    public func progress(_ id: String) -> Progress? {
        guard let job = jobs[id] else { return nil }
        let lacking = Set(DataDownloadPlan.missing(job.files, in: folder(id)).map(\.path))
        let total = job.files.reduce(Int64(0)) { $0 + $1.size }
        var done = job.files.filter { !lacking.contains($0.path) }.reduce(Int64(0)) { $0 + $1.size }
        for (path, bytes) in written[id] ?? [:] where lacking.contains(path) { done += bytes }
        return Progress(doneBytes: min(done, total), totalBytes: total, paused: job.paused, error: job.error)
    }

    // MARK: The player's controls

    public func start(_ id: String, offer: DataOffer) {
        guard DataDownloadPlan.isTitleID(id) else { return }
        jobs[id] = Job(titleID: id, source: offer.source, base: offer.base, token: offer.token, files: offer.files)
        save()
        run(id)
    }

    public func pause(_ id: String) {
        guard jobs[id] != nil else { return }
        jobs[id]?.paused = true
        jobs[id]?.error = ""
        save()
        stopTasks(of: id, keepResumeData: true)
        onChange(id)
    }

    /// Goes on with a paused download. `offer` is the source as it answers now (the Mac's address may have changed).
    public func resume(_ id: String, offer: DataOffer? = nil) {
        guard jobs[id] != nil else { return }
        if let offer {
            // Resume data names the address it came from: a new address starts the open file again from the server
            if jobs[id]?.base != offer.base { removeResumeData(of: id) }
            jobs[id]?.base = offer.base; jobs[id]?.token = offer.token; jobs[id]?.files = offer.files
        }
        jobs[id]?.paused = false
        jobs[id]?.error = ""
        save()
        run(id)
    }

    public func cancel(_ id: String) {
        guard jobs[id] != nil else { return }
        jobs.removeValue(forKey: id)
        written.removeValue(forKey: id)
        save()
        stopTasks(of: id, keepResumeData: false)
        removeResumeData(of: id)
        onChange(id)
    }

    private func removeResumeData(of id: String) {
        for file in jobs[id]?.files ?? [] { try? FileManager.default.removeItem(at: resumeFile(id, file.path)) }
    }

    private func stopTasks(of id: String, keepResumeData: Bool) {
        session.getAllTasks { [weak self] tasks in
            for task in tasks {
                guard let note = Self.note(of: task), note.titleID == id else { continue }
                guard keepResumeData, let download = task as? URLSessionDownloadTask else { task.cancel(); continue }
                download.cancel { data in
                    guard let data else { return }
                    Task { @MainActor in
                        guard let self, self.jobs[id] != nil else { return }
                        try? data.write(to: self.resumeFile(id, note.path), options: .atomic)
                    }
                }
            }
        }
    }

    /// Starts a task for every file of the job that is not here and has no task yet.
    private func run(_ id: String) {
        guard let job = jobs[id], !job.paused else { return }
        let lacking = DataDownloadPlan.missing(job.files, in: folder(id))
        guard !lacking.isEmpty else { return finish(id) }
        let needed = lacking.reduce(Int64(0)) { $0 + $1.size }
        if let free = try? folder(id).deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free > 0, needed + 2_000_000_000 > free {
            return stop(id, error: hostText("Not enough free space on this device for the game data."))
        }
        session.getAllTasks { [weak self] tasks in
            let busy = Set(tasks.compactMap { task -> String? in
                guard let note = Self.note(of: task), note.titleID == id, task.state == .running || task.state == .suspended else { return nil }
                return note.path
            })
            Task { @MainActor in
                guard let self, let job = self.jobs[id], !job.paused else { return }
                for file in lacking where !busy.contains(file.path) {
                    let task: URLSessionDownloadTask
                    let kept = self.resumeFile(id, file.path)
                    if let data = try? Data(contentsOf: kept) {
                        task = self.session.downloadTask(withResumeData: data)
                        try? FileManager.default.removeItem(at: kept)
                    } else {
                        var request = URLRequest(url: DataDownloadPlan.fileURL(base: job.base, titleID: id, path: file.path))
                        request.setValue("Bearer " + job.token, forHTTPHeaderField: "Authorization")
                        task = self.session.downloadTask(with: request)
                    }
                    let note = TaskNote(titleID: id, path: file.path, size: file.size)
                    task.taskDescription = (try? JSONEncoder().encode(note)).flatMap { String(data: $0, encoding: .utf8) }
                    task.resume()
                }
                self.onChange(id)
            }
        }
    }

    private func stop(_ id: String, error: String) {
        guard jobs[id] != nil else { return }
        jobs[id]?.paused = true
        jobs[id]?.error = error
        save()
        onChange(id)
    }

    private func finish(_ id: String) {
        removeResumeData(of: id)
        jobs.removeValue(forKey: id)
        written.removeValue(forKey: id)
        save()
        onFinished(id)
    }

    /// After a task ended: the job is done when nothing is missing any more.
    private func settle(_ id: String) {
        guard let job = jobs[id] else { return }
        if DataDownloadPlan.missing(job.files, in: folder(id)).isEmpty { finish(id) } else { onChange(id) }
    }

    // MARK: From the session

    fileprivate func wrote(_ note: TaskNote, bytes: Int64) {
        guard jobs[note.titleID] != nil else { return }
        written[note.titleID, default: [:]][note.path] = bytes
        let now = Date()
        if now.timeIntervalSince(lastTold[note.titleID] ?? .distantPast) >= 0.5 {
            lastTold[note.titleID] = now
            onChange(note.titleID)
        }
    }

    fileprivate func ended(_ note: TaskNote, failure: String?, resumeData: Data?, cancelled: Bool) {
        guard jobs[note.titleID] != nil else { return }
        if let resumeData { try? resumeData.write(to: resumeFile(note.titleID, note.path), options: .atomic) }
        if cancelled { return }   // pause and cancel say what follows themselves
        if let failure {
            stop(note.titleID, error: failure)
        } else {
            written[note.titleID]?.removeValue(forKey: note.path)
            settle(note.titleID)
        }
    }

    /// The session's delegate, off the main actor: a finished file must be moved before the callback returns.
    private final class Relay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        weak var owner: DataDownloader?
        let appDataRoot: URL
        /// Why a finished file was refused, by task, for `didCompleteWithError` (which then has no error of its own).
        private let lock = NSLock()
        private var refusals: [Int: String] = [:]

        init(owner: DataDownloader, appDataRoot: URL) { self.owner = owner; self.appDataRoot = appDataRoot }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard let note = DataDownloader.note(of: downloadTask) else { return }
            Task { @MainActor [weak owner] in owner?.wrote(note, bytes: totalBytesWritten) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let note = DataDownloader.note(of: downloadTask) else { return }
            let fm = FileManager.default
            let refusal: String?
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            let size = ((try? fm.attributesOfItem(atPath: location.path))?[.size] as? NSNumber)?.int64Value ?? -1
            if !(200...299).contains(status) {
                refusal = hostText("The Mac refused the download (\(status)). Install the game from the Mac again.")
            } else if size != note.size || !DataDownloadPlan.isSafe(note.path) || !DataDownloadPlan.isTitleID(note.titleID) {
                refusal = hostText("The downloaded file is not complete. Start the download again.")
            } else {
                let target = appDataRoot.appendingPathComponent(note.titleID, isDirectory: true).appendingPathComponent(note.path)
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: target)
                    try fm.moveItem(at: location, to: target)
                    refusal = nil
                } catch {
                    refusal = error.localizedDescription
                }
            }
            if let refusal { lock.lock(); refusals[downloadTask.taskIdentifier] = refusal; lock.unlock() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let note = DataDownloader.note(of: task) else { return }
            lock.lock(); let refusal = refusals.removeValue(forKey: task.taskIdentifier); lock.unlock()
            let ns = error as NSError?
            let cancelled = ns?.domain == NSURLErrorDomain && ns?.code == NSURLErrorCancelled
            let resumeData = ns?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let failure = refusal ?? error?.localizedDescription
            Task { @MainActor [weak owner] in owner?.ended(note, failure: failure, resumeData: resumeData, cancelled: cancelled) }
        }
    }
}

/// A game's code from the Mac: the framework the Mac signed for this app, fetched into `Documents/Frameworks` the way the Mac
/// launcher pushes one (a `.staging-<title ID>-<token>` folder with the framework, then `.ready`), so the catalogue adopts it
/// like a pushed one (`GameCatalogue.promoteStagedFrameworks`). The system loads it only when its signature is this app's team's.
public enum CodeFetcher {
    /// The framework's folder name for a title ID, the only name accepted.
    public static func frameworkName(_ titleID: String) -> String { "DmGame" + titleID.uppercased() + ".framework" }

    /// Whether the list's game can be fetched: a title ID, its own framework name, safe paths, something to fetch.
    public static func isFetchable(_ game: DataSourceList.Game) -> Bool {
        guard DataDownloadPlan.isTitleID(game.titleID), let name = game.framework, name == frameworkName(game.titleID),
              let code = game.code, !code.isEmpty else { return false }
        return code.allSatisfy { DataDownloadPlan.isSafe($0.path) && $0.size >= 0 }
    }

    public static func codeURL(base: URL, titleID: String, path: String) -> URL {
        var url = base.appendingPathComponent("v1/games").appendingPathComponent(titleID).appendingPathComponent("code")
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }

    /// Fetches the game's framework into a staging folder of `hotRoot` and marks it ready. False when a file could not be
    /// fetched whole: the staging folder is removed, nothing is adopted.
    public static func fetch(_ game: DataSourceList.Game, base: URL, token: String, hotRoot: URL, fileManager fm: FileManager = .default) async -> Bool {
        guard isFetchable(game), let name = game.framework, let code = game.code else { return false }
        let id = game.titleID.uppercased()
        let staging = hotRoot.appendingPathComponent(HotFrameworkReady.stagingPrefix + id + "-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        let framework = staging.appendingPathComponent(name, isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var bytes: Int64 = 0
        do {
            try fm.createDirectory(at: framework, withIntermediateDirectories: true)
            for file in code {
                var request = URLRequest(url: codeURL(base: base, titleID: game.titleID, path: file.path))
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                let (location, response) = try await session.download(for: request)
                let size = ((try? fm.attributesOfItem(atPath: location.path))?[.size] as? NSNumber)?.int64Value
                guard (response as? HTTPURLResponse)?.statusCode == 200, size == file.size else { throw URLError(.badServerResponse) }
                let target = framework.appendingPathComponent(file.path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: location, to: target)
                bytes += file.size
            }
            let ready = HotFrameworkReady(titleID: id, files: code.count, bytes: bytes)
            try JSONEncoder().encode(ready).write(to: staging.appendingPathComponent(HotFrameworkReady.fileName), options: .atomic)
            return true
        } catch {
            try? fm.removeItem(at: staging)
            return false
        }
    }
}
