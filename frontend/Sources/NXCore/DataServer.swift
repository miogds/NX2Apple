import Darwin
import Foundation

/// The game data this Mac offers to the shared app on a device, which downloads it itself (the app's Download button): the Mac's
/// copy through devicectl takes hours over Wi-Fi, cannot be paused from the device and ends when the connection drops once.
///
/// A small HTTP/1.1 server on the local network, one request per connection:
/// - `GET /v1/games`: the list as JSON (`DataServerList`), each game with its files and their sizes.
/// - `GET /v1/games/<title ID>/files/<path>`: one file, with `Range` (and `If-Range` against the file's `ETag`), so a download
///   that stopped goes on where it was.
/// Every request needs `Authorization: Bearer <token>`: the token goes to the device with the install (`DataSourceOffer`), so
/// only a device this Mac installed the app on reads the files. Only game data is served, never a game's code: that is in the
/// app the Mac signs.
package struct ServedFile: Equatable {
    package var size: Int64
    /// Where the file is on this Mac.
    package var path: String
    package init(size: Int64, path: String) { self.size = size; self.path = path }
}

package struct ServedGame: Equatable {
    package var titleID: String
    package var name: String
    /// By the path the device stores the file under, relative to the game's folder (`romfs.img`, `aoc/…`).
    package var files: [String: ServedFile]
    /// The game's code, signed for the shared app of this Mac's team: the framework's folder name and its files by their path
    /// inside it. Empty: the device gets the code with the app's install only.
    package var framework = ""
    package var code: [String: ServedFile] = [:]
    package init(titleID: String, name: String, files: [String: ServedFile], framework: String = "", code: [String: ServedFile] = [:]) {
        self.titleID = titleID; self.name = name; self.files = files; self.framework = framework; self.code = code
    }
}

/// What `GET /v1/games` answers. The shared app reads the same shape (`DataSourceList` in frontend-ios).
package struct DataServerList: Codable, Equatable {
    package struct File: Codable, Equatable {
        package var path: String
        package var size: Int64
    }
    package struct Game: Codable, Equatable {
        package var titleID: String
        package var name: String
        package var files: [File]
        package var framework: String?
        package var code: [File]?
    }
    package var version = 1
    package var name: String
    package var games: [Game]

    package init(name: String, games: [ServedGame]) {
        self.name = name
        self.games = games.sorted { $0.titleID < $1.titleID }.map { game in
            Game(titleID: game.titleID, name: game.name,
                 files: game.files.sorted { $0.key < $1.key }.map { File(path: $0.key, size: $0.value.size) },
                 framework: game.code.isEmpty ? nil : game.framework,
                 code: game.code.isEmpty ? nil : game.code.sorted { $0.key < $1.key }.map { File(path: $0.key, size: $0.value.size) })
        }
    }
}

/// The parts of HTTP the server needs, as pure functions.
package enum DataServerHTTP {
    package struct Request: Equatable {
        package var method: String
        package var path: String
        package var headers: [String: String]   // lower-case names
    }

    /// The request from its head (up to the empty line). nil for anything that is not `METHOD /path HTTP/1.x`.
    package static func parse(_ head: String) -> Request? {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard first.count == 3, first[2].hasPrefix("HTTP/1."), first[1].hasPrefix("/") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(method: String(first[0]), path: String(first[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]), headers: headers)
    }

    package enum Route: Equatable {
        case list
        case file(titleID: String, path: String)
        case code(titleID: String, path: String)
    }

    package static func route(_ path: String) -> Route? {
        if path == "/v1/games" || path == "/v1/games/" { return .list }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard parts.count >= 5, parts[0] == "v1", parts[1] == "games", parts[3] == "files" || parts[3] == "code" else { return nil }
        let decoded = parts[4...].map { $0.removingPercentEncoding }
        guard !decoded.contains(where: { $0 == nil || $0!.isEmpty }) else { return nil }
        let path = decoded.map { $0! }.joined(separator: "/")
        return parts[3] == "code" ? .code(titleID: parts[2], path: path) : .file(titleID: parts[2], path: path)
    }

    /// The bytes a `Range: bytes=…` header asks of a file of `size`. nil without a header or with one this server does not
    /// serve as a range (several ranges, another unit): the whole file then. `.failure` when it lies outside the file (416).
    package static func range(_ header: String?, size: Int64) -> Result<(offset: Int64, length: Int64), RangeError>? {
        guard let header, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let spec = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard spec.count == 2 else { return nil }
        if spec[0].isEmpty {   // the last N bytes
            guard let n = Int64(spec[1]), n > 0 else { return .failure(.outside) }
            let length = min(n, size)
            return length > 0 ? .success((size - length, length)) : .failure(.outside)
        }
        guard let start = Int64(spec[0]), start >= 0 else { return nil }
        guard start < size else { return .failure(.outside) }
        let end = spec[1].isEmpty ? size - 1 : min(Int64(spec[1]) ?? -1, size - 1)
        guard end >= start else { return .failure(.outside) }
        return .success((start, end - start + 1))
    }

    package enum RangeError: Error { case outside }

    /// The same file again only while its size and date are the same: a download goes on (`If-Range`) only then.
    package static func etag(size: Int64, modified: Date) -> String {
        "\"\(size)-\(Int64(modified.timeIntervalSince1970))\""
    }

    package static func head(status: String, headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers + [("Connection", "close")] { text += "\(name): \(value)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    /// Whether the request carries the token. Compared in constant time.
    package static func authorized(_ request: Request, token: String) -> Bool {
        guard !token.isEmpty, let given = request.headers["authorization"], given.hasPrefix("Bearer ") else { return false }
        let a = Array(given.dropFirst(7).utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// The server. `games` is asked at every request, so a game built while the launcher is open is offered at once.
package final class DataServer: @unchecked Sendable {
    package enum Failure: Error { case socket(Int32) }

    private let token: String
    private let name: String
    private let games: @Sendable () -> [ServedGame]
    private let lock = NSLock()
    private var listener: Int32 = -1
    /// Told about each request that was answered: for the launcher's log.
    package var log: @Sendable (String) -> Void = { _ in }

    package init(name: String, token: String, games: @escaping @Sendable () -> [ServedGame]) {
        self.name = name; self.token = token; self.games = games
    }

    deinit { stop() }

    /// Listens on `preferred` (IPv4 and IPv6), or on a port the system picks when that one is taken. Returns the port.
    package func start(preferred: UInt16) throws -> UInt16 {
        stop()
        var lastError: Int32 = 0
        for port in [preferred, 0] {
            let fd = socket(AF_INET6, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.socket(errno) }
            var off: Int32 = 0, on: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
            guard bound == 0, listen(fd, 16) == 0 else { lastError = errno; close(fd); continue }
            var actual = sockaddr_in6()
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            _ = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            lock.lock(); listener = fd; lock.unlock()
            Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
            return UInt16(bigEndian: actual.sin6_port)
        }
        throw Failure.socket(lastError)
    }

    package func stop() {
        lock.lock(); let fd = listener; listener = -1; lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // the listener was closed
            }
            Thread.detachNewThread { [weak self] in
                self?.serve(client)
                close(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        timeout.tv_sec = 120
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let head = readHead(client), let request = DataServerHTTP.parse(head) else {
            return send(client, status: "400 Bad Request")
        }
        guard request.method == "GET" || request.method == "HEAD" else { return send(client, status: "405 Method Not Allowed") }
        guard DataServerHTTP.authorized(request, token: token) else { return send(client, status: "401 Unauthorized") }
        switch DataServerHTTP.route(request.path) {
        case .list:
            let body = (try? JSONEncoder().encode(DataServerList(name: name, games: games()))) ?? Data()
            send(client, status: "200 OK", headers: [("Content-Type", "application/json"), ("Content-Length", String(body.count))],
                 body: request.method == "HEAD" ? nil : body)
        case .file(let titleID, let path):
            guard let file = games().first(where: { $0.titleID == titleID })?.files[path] else { return send(client, status: "404 Not Found") }
            sendFile(client, file, request: request, label: titleID + "/" + path)
        case .code(let titleID, let path):
            guard let file = games().first(where: { $0.titleID == titleID })?.code[path] else { return send(client, status: "404 Not Found") }
            sendFile(client, file, request: request, label: titleID + " code/" + path)
        case nil:
            send(client, status: "404 Not Found")
        }
    }

    private func readHead(_ client: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 16384 {
            let n = recv(client, &buffer, buffer.count, 0)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return nil }
            data.append(buffer, count: n)
            if let end = data.range(of: Data("\r\n\r\n".utf8)) { return String(data: data[..<end.lowerBound], encoding: .utf8) }
        }
        return nil
    }

    private func send(_ client: Int32, status: String, headers: [(String, String)] = [("Content-Length", "0")], body: Data? = nil) {
        var out = DataServerHTTP.head(status: status, headers: headers)
        if let body { out.append(body) }
        _ = out.withUnsafeBytes { writeAll(client, $0.baseAddress!, $0.count) }
    }

    private func writeAll(_ client: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Bool {
        var sent = 0
        while sent < count {
            let n = Darwin.send(client, bytes + sent, count - sent, 0)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return false }
            sent += n
        }
        return true
    }

    private func sendFile(_ client: Int32, _ file: ServedFile, request: DataServerHTTP.Request, label: String) {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { return send(client, status: "404 Not Found") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return send(client, status: "404 Not Found") }
        let size = Int64(info.st_size)
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        let etag = DataServerHTTP.etag(size: size, modified: modified)
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX"); dates.timeZone = TimeZone(identifier: "GMT")
        dates.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        var headers = [("Content-Type", "application/octet-stream"), ("Accept-Ranges", "bytes"), ("ETag", etag),
                       ("Last-Modified", dates.string(from: modified))]
        var offset: Int64 = 0, length = size, status = "200 OK"
        // A range of another version of the file would join two files: the whole file then
        let sameFile = request.headers["if-range"].map { $0 == etag } ?? true
        if sameFile, let asked = DataServerHTTP.range(request.headers["range"], size: size) {
            switch asked {
            case .success(let r):
                offset = r.offset; length = r.length; status = "206 Partial Content"
                headers.append(("Content-Range", "bytes \(offset)-\(offset + length - 1)/\(size)"))
            case .failure:
                return send(client, status: "416 Range Not Satisfiable", headers: [("Content-Range", "bytes */\(size)"), ("Content-Length", "0")])
            }
        }
        headers.append(("Content-Length", String(length)))
        let head = DataServerHTTP.head(status: status, headers: headers)
        guard head.withUnsafeBytes({ writeAll(client, $0.baseAddress!, $0.count) }) else { return }
        log("\(request.method) \(label) \(status) from \(offset), \(length) bytes")
        guard request.method == "GET" else { return }
        var position = offset
        let end = offset + length
        while position < end {
            var chunk = off_t(min(end - position, 8 << 20))
            let result = sendfile(fd, client, off_t(position), &chunk, nil, 0)
            position += Int64(chunk)
            if result != 0 {
                if errno == EINTR || (errno == EAGAIN && chunk > 0) { continue }
                return   // the device went away: its next request asks for the rest
            }
        }
    }
}
