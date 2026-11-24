import XCTest
@testable import NXCore

/// The server a device downloads game data from: the list, a file whole and from the middle (a download that goes on), and
/// nothing without the token.
final class DataServerTests: XCTestCase {
    private var folder = ""
    private var server: DataServer!
    private var base = ""
    private let token = "0123456789abcdef0123456789abcdef"
    private let image = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "nx-data-server-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder + "/Orbit/aoc", withIntermediateDirectories: true)
        try image.write(to: URL(fileURLWithPath: folder + "/Orbit/Orbit.img"))
        try Data("dlc".utf8).write(to: URL(fileURLWithPath: folder + "/Orbit/aoc/a b.img"))
        try Data("0100".utf8).write(to: URL(fileURLWithPath: folder + "/Orbit/.titleid"))
        let archive = folder + "/Orbit"
        let framework = folder + "/shelf/0100/DmGame0100.framework"
        try FileManager.default.createDirectory(atPath: framework + "/_CodeSignature", withIntermediateDirectories: true)
        try Data("code".utf8).write(to: URL(fileURLWithPath: framework + "/DmGame0100"))
        try Data("seal".utf8).write(to: URL(fileURLWithPath: framework + "/_CodeSignature/CodeResources"))
        try Data("finder".utf8).write(to: URL(fileURLWithPath: framework + "/.DS_Store"))
        server = DataServer(name: "Mac", token: token) {
            [ServedGame(titleID: "0100", name: "Orbit", files: ShellInstall.servedFiles(archive: archive, titleID: "0100"),
                        framework: "DmGame0100.framework", code: ShellInstall.servedCode(framework: framework))]
        }
        base = "http://127.0.0.1:\(try server.start(preferred: 0))"
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func get(_ path: String, headers: [String: String] = [:], token: String? = nil) throws -> (status: Int, headers: [AnyHashable: Any], body: Data) {
        var request = URLRequest(url: URL(string: base + path)!)
        request.setValue("Bearer " + (token ?? self.token), forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let done = expectation(description: path)
        var result: (Int, [AnyHashable: Any], Data)?
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { result = (http.statusCode, http.allHeaderFields, data ?? Data()) }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result)
    }

    func testTheListNamesTheImageAsTheDeviceStoresIt() throws {
        let answer = try get("/v1/games")
        XCTAssertEqual(answer.status, 200)
        let list = try JSONDecoder().decode(DataServerList.self, from: answer.body)
        XCTAssertEqual(list.games.map(\.titleID), ["0100"])
        XCTAssertEqual(list.games[0].files, [.init(path: "aoc/a b.img", size: 3), .init(path: "romfs.img", size: Int64(image.count))])
    }

    func testAFileComesWholeAndFromTheMiddle() throws {
        let whole = try get("/v1/games/0100/files/romfs.img")
        XCTAssertEqual(whole.status, 200)
        XCTAssertEqual(whole.body, image)
        let etag = try XCTUnwrap(whole.headers["Etag"] as? String)
        let rest = try get("/v1/games/0100/files/romfs.img", headers: ["Range": "bytes=150000-", "If-Range": etag])
        XCTAssertEqual(rest.status, 206)
        XCTAssertEqual(rest.body, image.suffix(from: 150_000))
        XCTAssertEqual(rest.headers["Content-Range"] as? String, "bytes 150000-199999/200000")
        // Another version of the file: the whole file, never a part of the new one after a part of the old one
        let changed = try get("/v1/games/0100/files/romfs.img", headers: ["Range": "bytes=150000-", "If-Range": "\"1-1\""])
        XCTAssertEqual(changed.status, 200)
        XCTAssertEqual(changed.body.count, image.count)
        XCTAssertEqual(try get("/v1/games/0100/files/aoc/a%20b.img").body, Data("dlc".utf8))
    }

    func testNothingIsServedWithoutTheTokenOrOutsideTheList() throws {
        XCTAssertEqual(try get("/v1/games", token: "wrong").status, 401)
        XCTAssertEqual(try get("/v1/games/0100/files/.titleid").status, 404)
        XCTAssertEqual(try get("/v1/games/0100/files/..%2F..%2Fetc%2Fpasswd").status, 404)
        XCTAssertEqual(try get("/v1/games/0200/files/romfs.img").status, 404)
        XCTAssertEqual(try get("/v1/games/0100/files/romfs.img", headers: ["Range": "bytes=999999-"]).status, 416)
    }

    func testTheGamesSignedCodeIsListedAndServedFileByFile() throws {
        let list = try JSONDecoder().decode(DataServerList.self, from: try get("/v1/games").body)
        XCTAssertEqual(list.games[0].framework, "DmGame0100.framework")
        XCTAssertEqual(list.games[0].code, [.init(path: "DmGame0100", size: 4), .init(path: "_CodeSignature/CodeResources", size: 4)])
        XCTAssertEqual(try get("/v1/games/0100/code/_CodeSignature/CodeResources").body, Data("seal".utf8))
        XCTAssertEqual(try get("/v1/games/0100/code/.DS_Store").status, 404)
        XCTAssertEqual(try get("/v1/games/0100/code/DmGame0100", token: "wrong").status, 401)
    }

    func testRangesAndRoutes() {
        XCTAssertNil(DataServerHTTP.range(nil, size: 10))
        XCTAssertNil(DataServerHTTP.range("bytes=0-1,4-5", size: 10))
        XCTAssertEqual(try? DataServerHTTP.range("bytes=2-", size: 10)?.get().offset, 2)
        XCTAssertEqual(try? DataServerHTTP.range("bytes=2-", size: 10)?.get().length, 8)
        XCTAssertEqual(try? DataServerHTTP.range("bytes=2-5", size: 10)?.get().length, 4)
        XCTAssertEqual(try? DataServerHTTP.range("bytes=-3", size: 10)?.get().offset, 7)
        XCTAssertEqual(DataServerHTTP.route("/v1/games"), .list)
        XCTAssertEqual(DataServerHTTP.route("/v1/games/0100/files/aoc/a%20b.img"), .file(titleID: "0100", path: "aoc/a b.img"))
        XCTAssertNil(DataServerHTTP.route("/v1/other"))
    }

    func testTheOfferNamesTheMacByItsLocalNameThenItsAddresses() {
        XCTAssertEqual(DataSourceOffer.urls(port: 47810, hostName: "Studio.local", addresses: ["192.168.1.20"]),
                       ["http://Studio.local:47810", "http://192.168.1.20:47810"])
        XCTAssertEqual(DataSourceOffer.urls(port: 80, hostName: "studio", addresses: ["10.0.0.2"]), ["http://10.0.0.2:80"])
        XCTAssertEqual(DataSourceOffer.newToken().count, 32)
    }
}
