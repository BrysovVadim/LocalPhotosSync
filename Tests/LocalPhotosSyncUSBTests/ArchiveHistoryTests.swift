import AppKit
import SwiftUI
import XCTest
@testable import LocalPhotosSyncUSB

final class ArchiveHistoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAddingKeepsNewestFirstAndSkipsDuplicates() {
        let first = root.appendingPathComponent("a", isDirectory: true)
        let second = root.appendingPathComponent("b", isDirectory: true)
        var records = ArchiveHistoryFile.adding(first, source: .catalog, at: Date(timeIntervalSince1970: 1), to: [])
        records = ArchiveHistoryFile.adding(second, source: .usbImport, at: Date(timeIntervalSince1970: 2), to: records)
        records = ArchiveHistoryFile.adding(root.appendingPathComponent("a/../a", isDirectory: true), source: .added,
                                            at: Date(timeIntervalSince1970: 3), to: records)
        XCTAssertEqual(records.map(\.name), ["b", "a"])
        XCTAssertEqual(records.map(\.source), [.usbImport, .catalog])
    }

    func testSaveAndLoadRoundTrip() throws {
        let file = root.appendingPathComponent("nested/archive-history.json")
        XCTAssertEqual(try ArchiveHistoryFile.load(from: file), [])
        let records = ArchiveHistoryFile.adding(root, source: .added, at: Date(timeIntervalSince1970: 1_790_000_000), to: [])
        try ArchiveHistoryFile.save(records, to: file)
        XCTAssertEqual(try ArchiveHistoryFile.load(from: file), records)
        try Data("not json".utf8).write(to: file)
        XCTAssertThrowsError(try ArchiveHistoryFile.load(from: file))
    }

    func testCheckReportsPassedFailedAndMissing() throws {
        let good = try makeArchive(named: "good", completed: true)
        guard case .passed(let files, _) = ArchiveHistoryFile.check(folder: good) else { return XCTFail("Expected passed") }
        XCTAssertEqual(files, 1)

        let incomplete = try makeArchive(named: "incomplete", completed: false)
        guard case .failed(let details, _) = ArchiveHistoryFile.check(folder: incomplete) else { return XCTFail("Expected failed") }
        XCTAssertFalse(details.isEmpty)

        try Data("changed".utf8).write(to: good.appendingPathComponent("photo.heic"))
        guard case .failed = ArchiveHistoryFile.check(folder: good) else { return XCTFail("Changed file must fail") }

        let noReport = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: noReport, withIntermediateDirectories: false)
        guard case .failed = ArchiveHistoryFile.check(folder: noReport) else { return XCTFail("Folder without report must fail") }

        guard case .missing = ArchiveHistoryFile.check(folder: root.appendingPathComponent("gone")) else {
            return XCTFail("Expected missing")
        }
    }

    func testSummaryCountsStates() {
        let records = (0..<5).map { ArchiveRecord(id: UUID(), path: "/a/\($0)", recordedAt: Date(), source: .catalog) }
        let now = Date()
        let summary = ArchiveHistorySummary(records: records, checks: [
            records[0].id: .passed(files: 3, at: now),
            records[1].id: .failed(details: "x", at: now),
            records[2].id: .missing(at: now),
            records[3].id: .checking,
        ])
        XCTAssertEqual(summary, ArchiveHistorySummary.init(records: records, checks: [
            records[0].id: .passed(files: 1, at: now), records[1].id: .missing(at: now),
            records[2].id: .failed(details: "y", at: now), records[3].id: .unchecked,
        ]))
        XCTAssertEqual(summary.total, 5)
        XCTAssertEqual(summary.passed, 1)
        XCTAssertEqual(summary.problems, 2)
        XCTAssertEqual(summary.unchecked, 2)
    }

    @MainActor
    func testInMemoryStoreRecordsRemovesAndVerifies() async throws {
        let store = ArchiveHistoryStore(fileURL: nil)
        let good = try makeArchive(named: "good", completed: true)
        store.record(good, source: .catalog)
        store.record(good, source: .usbImport)
        XCTAssertEqual(store.records.count, 1)
        let id = try XCTUnwrap(store.records.first?.id)
        store.verify([id])
        for _ in 0..<200 where store.isChecking { try await Task.sleep(nanoseconds: 10_000_000) }
        guard case .passed = store.checks[id] else { return XCTFail("Expected passed, got \(String(describing: store.checks[id]))") }
        store.remove(id)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.checks[id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.path), "Removing from the list keeps the folder")
    }

    private func makeArchive(named name: String, completed: Bool) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let media = folder.appendingPathComponent("photo.heic")
        try Data("photo".utf8).write(to: media)
        let receipt = try FileReceipt.verify(url: media, sourceName: "photo.heic", sourceBytes: 5)
        try ImportReport(startedAt: Date(), files: [receipt], errors: [], expectedFileCount: 1, completed: completed).write(to: folder)
        return folder
    }
}

/// Renders the archive tab for visual review (needs `LPS_RENDER_DIR`).
@MainActor
final class ArchiveHistoryRenderTests: XCTestCase {
    func testRendersArchiveScreens() throws {
        let output = try ScreenRenderer.outputDirectory()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let sources: [ArchiveSource] = [.catalog, .usbImport, .catalog, .added, .usbImport]
        let records = sources.enumerated().map { index, source in
            ArchiveRecord(id: UUID(), path: "/Users/me/Архив фото/LocalPhotosSync-2026-09-\(21 - index)",
                          recordedAt: now.addingTimeInterval(TimeInterval(-index * 86_400)), source: source)
        }
        let checks: [UUID: ArchiveCheckState] = [
            records[0].id: .passed(files: 12, at: now),
            records[1].id: .failed(details: "00003/IMG_0102.HEIC: Контрольная сумма не совпадает.\n00007/IMG_0106.HEIC: Файл не найден.\nИмпорт не завершён.\nОжидалось файлов: 12, записано: 10.", at: now),
            records[2].id: .checking,
            records[3].id: .missing(at: now),
        ]
        let cases: [(String, [ArchiveRecord], CGSize)] = [
            ("archives-list", records, CGSize(width: 1060, height: 760)),
            ("archives-empty", [], CGSize(width: 820, height: 580)),
        ]
        for (name, list, size) in cases {
            let view = ArchiveHistoryScreen(records: list, checks: checks, isChecking: false, message: nil,
                                            actions: ArchiveHistoryActions())
            let png = try ScreenRenderer.render(view, size: size)
            XCTAssertGreaterThan(png.count, 10_000, name)
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
    }
}

final class ArchiveHistoryPersistenceTests: XCTestCase {
    @MainActor
    func testUnreadableHistoryIsMovedAsideNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("archive-history.json")
        try Data("{ broken".utf8).write(to: file)

        let store = ArchiveHistoryStore(fileURL: file)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNotNil(store.message)
        let preserved = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("archive-history.unreadable-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(preserved[0])), Data("{ broken".utf8))

        store.record(root, source: .added)
        XCTAssertEqual(try ArchiveHistoryFile.load(from: file).count, 1, "A fresh list is saved next to the preserved file")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDedupeResolvesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let records = ArchiveHistoryFile.adding(real, source: .catalog, at: Date(), to: [])
        XCTAssertEqual(ArchiveHistoryFile.adding(link, source: .added, at: Date(), to: records), records)
    }
}
