import XCTest
@testable import LocalPhotosSyncUSB

final class ArchiveReceiptTests: XCTestCase {
    private func fixture(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("sample.bin")
        try data.write(to: url)
        return url
    }

    func testReceiptContainsKnownSHA256AndSavedSize() throws {
        let url = try fixture(Data("abc".utf8))

        let receipt = try FileReceipt.verify(url: url, sourceName: "IMG_0001.HEIC", sourceBytes: 3)

        XCTAssertEqual(receipt.savedBytes, 3)
        XCTAssertEqual(receipt.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testTruncatedFileIsRejectedAndPreserved() throws {
        let url = try fixture(Data("abc".utf8))

        XCTAssertThrowsError(try FileReceipt.verify(url: url, sourceName: "clip.mov", sourceBytes: 10))

        XCTAssertEqual(try Data(contentsOf: url), Data("abc".utf8))
    }

    func testEmptyDownloadIsRejected() throws {
        let url = try fixture(Data())

        XCTAssertThrowsError(try FileReceipt.verify(url: url, sourceName: "photo.heic", sourceBytes: 0))
    }

    func testReportRecordsFailuresWithoutCountingThemAsSavedFiles() throws {
        let url = try fixture(Data("abc".utf8))
        let receipt = try FileReceipt.verify(url: url, sourceName: "photo.heic", sourceBytes: 3)
        let report = ImportReport(startedAt: Date(), files: [receipt], errors: ["clip.mov: interrupted"])

        try report.write(to: url.deletingLastPathComponent())
        let data = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("import-report.json"))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(decoded.files.count, 1)
        XCTAssertEqual(decoded.errors, ["clip.mov: interrupted"])
    }

    func testExistingReportVerifiesAfterArchiveIsMoved() throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archive = original.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let item = archive.appendingPathComponent("00001", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let media = item.appendingPathComponent("photo.heic")
        try Data("photo".utf8).write(to: media)
        try Data("live companion".utf8).write(to: item.appendingPathComponent("photo.mov"))
        let receipt = try FileReceipt.verify(url: media, sourceName: "photo.heic", sourceBytes: 5)
        try ImportReport(startedAt: Date(), files: [receipt], errors: [], expectedFileCount: 1, completed: true).write(to: archive)

        let moved = original.appendingPathComponent("moved-archive", isDirectory: true)
        try FileManager.default.moveItem(at: archive, to: moved)

        let result = try ArchiveVerification.verify(reportAt: moved.appendingPathComponent("import-report.json"))
        XCTAssertTrue(result.isValid, result.failures.joined(separator: ", "))
        XCTAssertEqual(result.verifiedFiles, 1)
    }

    func testExistingReportFindsCorruptionAndMissingCompanion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let item = root.appendingPathComponent("00001", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let media = item.appendingPathComponent("photo.heic")
        try Data("photo".utf8).write(to: media)
        try Data("live companion".utf8).write(to: item.appendingPathComponent("photo.mov"))
        let receipt = try FileReceipt.verify(url: media, sourceName: "photo.heic", sourceBytes: 5)
        try ImportReport(startedAt: Date(), files: [receipt], errors: [], expectedFileCount: 1, completed: true).write(to: root)
        try Data("damaged".utf8).write(to: media)
        try FileManager.default.moveItem(at: item.appendingPathComponent("photo.mov"), to: root.appendingPathComponent("temporarily-moved-photo.mov"))

        let result = try ArchiveVerification.verify(reportAt: root.appendingPathComponent("import-report.json"))
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failures.count, 2)
    }

    func testIncompleteReportCannotVerify() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("photo.heic")
        try Data("photo".utf8).write(to: file)
        let receipt = try FileReceipt.verify(url: file, sourceName: "photo.heic", sourceBytes: 5)
        try ImportReport(startedAt: Date(), files: [receipt], errors: [], expectedFileCount: 1, completed: false).write(to: root)
        let result = try ArchiveVerification.verify(reportAt: root.appendingPathComponent("import-report.json"))
        XCTAssertFalse(result.isValid)
    }

    func testEmptyReportCannotVerify() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try ImportReport(startedAt: Date(), files: [], errors: [], expectedFileCount: 0, completed: true).write(to: root)
        let result = try ArchiveVerification.verify(reportAt: root.appendingPathComponent("import-report.json"))
        XCTAssertFalse(result.isValid)
    }

    func testExpectedFileCountMismatchCannotVerify() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("photo.heic")
        try Data("photo".utf8).write(to: file)
        let receipt = try FileReceipt.verify(url: file, sourceName: "photo.heic", sourceBytes: 5)
        try ImportReport(startedAt: Date(), files: [receipt], errors: [], expectedFileCount: 2, completed: true).write(to: root)
        let result = try ArchiveVerification.verify(reportAt: root.appendingPathComponent("import-report.json"))
        XCTAssertFalse(result.isValid)
    }

    func testRecordedImportErrorsCannotVerify() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("photo.heic")
        try Data("photo".utf8).write(to: file)
        let receipt = try FileReceipt.verify(url: file, sourceName: "photo.heic", sourceBytes: 5)
        try ImportReport(startedAt: Date(), files: [receipt], errors: ["transfer interrupted"], expectedFileCount: 1, completed: true).write(to: root)
        let result = try ArchiveVerification.verify(reportAt: root.appendingPathComponent("import-report.json"))
        XCTAssertFalse(result.isValid)
    }

    func testCompanionInventoryIsCachedPerItemAndLooseFilesAreExcluded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let item = root.appendingPathComponent("00001", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let media = item.appendingPathComponent("photo.heic")
        try Data("photo".utf8).write(to: media)
        try Data("live".utf8).write(to: item.appendingPathComponent("photo.mov"))
        try Data("unassociated".utf8).write(to: root.appendingPathComponent("loose.txt"))
        let receipt = try FileReceipt.verify(url: media, sourceName: "photo.heic", sourceBytes: 5)
        try ImportReport(startedAt: Date(), files: [receipt], errors: [], expectedFileCount: 1, completed: true).write(to: root)

        let data = try Data(contentsOf: root.appendingPathComponent("import-report.json"))
        let json = try JSONDecoder().decode(InventoryJSON.self, from: data)
        XCTAssertEqual(json.companionFiles.map(\.path), ["00001/photo.mov"])
        let verified = try ArchiveVerification.verify(reportAt: root.appendingPathComponent("import-report.json"))
        XCTAssertTrue(verified.isValid, verified.failures.joined(separator: ", "))

        try Data("changed after receipt".utf8).write(to: item.appendingPathComponent("photo.mov"))
        try ImportReport(startedAt: Date(), files: [receipt], errors: [], expectedFileCount: 1, completed: true).write(to: root)
        let staleInventory = try ArchiveVerification.verify(reportAt: root.appendingPathComponent("import-report.json"))
        XCTAssertFalse(staleInventory.isValid, "Writing a report must preserve the cached companion checksum")
    }

    func testUnsafeRelativePathIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let json = """
        {"files":[{"sourceName":"x","savedPath":"/tmp/x","relativePath":"../outside","savedBytes":1,"sha256":"x"}],"errors":[],"expectedFileCount":1,"completed":true,"companionFiles":[]}
        """
        let reportURL = root.appendingPathComponent("import-report.json")
        try Data(json.utf8).write(to: reportURL)
        let result = try ArchiveVerification.verify(reportAt: reportURL)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testSymlinkEscapeIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let target = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("outside".utf8).write(to: target)
        let item = root.appendingPathComponent("00001", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let primary = item.appendingPathComponent("photo.heic")
        try Data("photo".utf8).write(to: primary)
        try FileManager.default.createSymbolicLink(at: item.appendingPathComponent("link"), withDestinationURL: target)
        let receipt = try FileReceipt.verify(url: primary, sourceName: "photo.heic", sourceBytes: 5)
        try ImportReport(startedAt: Date(), files: [receipt], errors: [], expectedFileCount: 1, completed: true).write(to: root)
        let data = try Data(contentsOf: root.appendingPathComponent("import-report.json"))
        var report = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        report["companionFiles"] = [["path": "00001/link", "bytes": 7, "sha256": "x"]]
        let reportURL = root.appendingPathComponent("import-report.json")
        try JSONSerialization.data(withJSONObject: report).write(to: reportURL)
        let result = try ArchiveVerification.verify(reportAt: reportURL)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testLegacyReportWithoutCompletionMetadataFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let reportURL = root.appendingPathComponent("import-report.json")
        let legacy = """
        {"files":[],"errors":[],"startedAt":"2026-09-30T00:00:00Z"}
        """
        try Data(legacy.utf8).write(to: reportURL)
        let result = try ArchiveVerification.verify(reportAt: reportURL)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.failures.contains { $0.contains("завершён") || $0.contains("ожидаемого") })
    }

    private struct InventoryJSON: Decodable {
        let companionFiles: [Companion]
        struct Companion: Decodable { let path: String }
    }

    private struct JSONValue: Decodable {
        let files: [SavedFile]
        let errors: [String]
        struct SavedFile: Decodable { let sha256: String }
    }
}
