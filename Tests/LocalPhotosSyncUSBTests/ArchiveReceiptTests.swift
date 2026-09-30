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

    private struct JSONValue: Decodable {
        let files: [SavedFile]
        let errors: [String]
        struct SavedFile: Decodable { let sha256: String }
    }
}
