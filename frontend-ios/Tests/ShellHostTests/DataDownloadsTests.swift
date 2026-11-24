import Foundation
import Testing
@testable import ShellHost
import ShellUI

/// Game data the app downloads itself: what it asks of the Mac, what it refuses, and what the library shows.
@MainActor @Suite struct DataDownloadsTests {
    private func list(_ files: [DataSourceList.File], id: String = Fixtures.orbit) throws -> DataSourceList {
        let json = try JSONSerialization.data(withJSONObject: ["version": 1, "name": "Studio", "games": [
            ["titleID": id, "name": "Orbit", "files": files.map { ["path": $0.path, "size": $0.size] }]]])
        return try JSONDecoder().decode(DataSourceList.self, from: json)
    }

    @Test func theOfferFileIsReadFromDocuments() throws {
        let box = try Sandbox()
        let documents = box.appData.deletingLastPathComponent()
        #expect(DataSourceOffer.read(documents: documents) == nil)
        let offer = DataSourceOffer(name: "Studio", urls: ["http://Studio.local:47810"], token: "abc")
        try JSONEncoder().encode(offer).write(to: documents.appendingPathComponent(DataSourceOffer.fileName))
        #expect(DataSourceOffer.read(documents: documents) == offer)
        try Data(#"{"version":1,"name":"x","urls":[],"token":""}"#.utf8).write(to: documents.appendingPathComponent(DataSourceOffer.fileName))
        #expect(DataSourceOffer.read(documents: documents) == nil)
    }

    @Test func onlyFilesTheDeviceLacksAreAsked() throws {
        let box = try Sandbox()
        let folder = box.appData.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("aoc"), withIntermediateDirectories: true)
        try Data("1234".utf8).write(to: folder.appendingPathComponent("aoc/a.img"))
        try Data("12".utf8).write(to: folder.appendingPathComponent("romfs.img"))   // cut off: another size
        let files = [DataSourceList.File(path: "aoc/a.img", size: 4), .init(path: "romfs.img", size: 8), .init(path: "aoc/b.img", size: 3)]
        #expect(DataDownloadPlan.missing(files, in: folder).map(\.path) == ["romfs.img", "aoc/b.img"])
        let offers = DataDownloadPlan.offers(list: try list(files), base: URL(string: "http://mac:1")!, token: "t",
                                             ids: [Fixtures.orbit], appDataRoot: box.appData)
        #expect(offers[Fixtures.orbit]?.missingBytes == 11)
        #expect(offers[Fixtures.orbit]?.totalBytes == 15)
        // A game that is not in this app, and one with everything here, have no offer
        #expect(DataDownloadPlan.offers(list: try list(files), base: URL(string: "http://mac:1")!, token: "t", ids: [], appDataRoot: box.appData).isEmpty)
        #expect(DataDownloadPlan.offers(list: try list([files[0]]), base: URL(string: "http://mac:1")!, token: "t",
                                        ids: [Fixtures.orbit], appDataRoot: box.appData).isEmpty)
    }

    @Test func pathsOutsideTheGameFolderAreNeverFetched() throws {
        for path in ["../x", "/etc/passwd", "a/../../b", ".hidden", "a//b", "a\\b", ""] {
            #expect(!DataDownloadPlan.isSafe(path), "\(path)")
        }
        #expect(DataDownloadPlan.isSafe("aoc/a b.img"))
        #expect(!DataDownloadPlan.isTitleID("../0100"))
        #expect(DataDownloadPlan.isTitleID("0400486024DEC000"))
        let box = try Sandbox()
        let files = [DataSourceList.File(path: "../escape.img", size: 1), .init(path: "romfs.img", size: 2)]
        #expect(DataDownloadPlan.missing(files, in: box.appData).map(\.path) == ["romfs.img"])
        #expect(DataDownloadPlan.offers(list: try list(files, id: "../../x"), base: URL(string: "http://mac:1")!, token: "t",
                                        ids: ["../../x"], appDataRoot: box.appData).isEmpty)
    }

    @Test func aFileURLEscapesItsPath() {
        let url = DataDownloadPlan.fileURL(base: URL(string: "http://mac:47810")!, titleID: "0100", path: "aoc/a b.img")
        #expect(url.absoluteString == "http://mac:47810/v1/games/0100/files/aoc/a%20b.img")
    }

    @Test func theLibraryOffersNoDownloadWithoutTheAppsDownloadFolder() throws {
        let box = try Sandbox()
        let model = ShellHostModel(config: box.config())
        #expect(model.downloadState(for: Fixtures.orbit) == nil)
        model.downloadGameData(Fixtures.orbit)   // nothing to do, and nothing breaks
    }

    @Test func onlyTheGamesOwnFrameworkWithSafePathsIsFetched() throws {
        func game(_ id: String, _ framework: String?, _ paths: [String]) throws -> DataSourceList.Game {
            var entry: [String: Any] = ["titleID": id, "name": "Orbit", "files": []]
            if let framework { entry["framework"] = framework; entry["code"] = paths.map { ["path": $0, "size": 1] } }
            let json = try JSONSerialization.data(withJSONObject: ["version": 1, "name": "Studio", "games": [entry]])
            return try JSONDecoder().decode(DataSourceList.self, from: json).games[0]
        }
        #expect(CodeFetcher.isFetchable(try game("0100abcd", "DmGame0100ABCD.framework", ["DmGame0100ABCD", "_CodeSignature/CodeResources"])))
        #expect(!CodeFetcher.isFetchable(try game("0100", nil, [])))
        #expect(!CodeFetcher.isFetchable(try game("0100", "DmGame0100.framework", [])))
        #expect(!CodeFetcher.isFetchable(try game("0100", "DmGame0200.framework", ["x"])))
        #expect(!CodeFetcher.isFetchable(try game("0100", "DmGame0100.framework", ["../x"])))
        #expect(!CodeFetcher.isFetchable(try game("../0100", "DmGame../0100.framework", ["x"])))
        #expect(CodeFetcher.codeURL(base: URL(string: "http://mac:1")!, titleID: "0100", path: "a/b c").absoluteString == "http://mac:1/v1/games/0100/code/a/b%20c")
    }
}
