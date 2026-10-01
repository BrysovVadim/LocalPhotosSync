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
                          recordedAt: now.addingTimeInterval(TimeInterval(-index * 86_400)), source: source,
                          lastCheck: index == 4 ? ArchiveLastCheck(at: Date().addingTimeInterval(-3 * 86_400),
                                                                    outcome: .passed, verifiedFiles: 8) : nil)
        }
        let summaries = Dictionary(uniqueKeysWithValues: records.prefix(3).enumerated().map { index, record in
            (record.id, ArchiveReportSummary(files: 12 - index, bytes: Int64(31_000_000 - index * 2_000_000), completed: index != 1))
        })
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
                                            summaries: summaries, actions: ArchiveHistoryActions())
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

final class ArchiveLastCheckTests: XCTestCase {
    func testLastCheckIsDerivedWithoutFailureDetails() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(ArchiveLastCheck(.passed(files: 4, at: now)), ArchiveLastCheck(at: now, outcome: .passed, verifiedFiles: 4))
        XCTAssertEqual(ArchiveLastCheck(.failed(details: "a.heic: x\nb.heic: y", at: now)),
                       ArchiveLastCheck(at: now, outcome: .failed, problems: 2))
        XCTAssertEqual(ArchiveLastCheck(.missing(at: now)), ArchiveLastCheck(at: now, outcome: .missing))
        XCTAssertNil(ArchiveLastCheck(.checking))
        XCTAssertNil(ArchiveLastCheck(.unchecked))
    }

    func testOlderHistoryWithoutLastCheckStillLoads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("archive-history.json")
        let legacy = """
        {"version":1,"archives":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","path":"/tmp/a","recordedAt":"2026-09-21T12:00:00Z","source":"catalog"}]}
        """
        try Data(legacy.utf8).write(to: file)
        let records = try ArchiveHistoryFile.load(from: file)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].lastCheck)
    }

    func testSummaryFallsBackToLastCheck() {
        let now = Date()
        let records = [
            ArchiveRecord(id: UUID(), path: "/a", recordedAt: now, source: .catalog, lastCheck: ArchiveLastCheck(at: now, outcome: .passed)),
            ArchiveRecord(id: UUID(), path: "/b", recordedAt: now, source: .catalog, lastCheck: ArchiveLastCheck(at: now, outcome: .missing)),
            ArchiveRecord(id: UUID(), path: "/c", recordedAt: now, source: .catalog),
        ]
        let summary = ArchiveHistorySummary(records: records, checks: [records[0].id: .failed(details: "x", at: now)])
        XCTAssertEqual(summary.passed, 0, "A result from this session overrides the stored one")
        XCTAssertEqual(summary.problems, 2)
        XCTAssertEqual(summary.unchecked, 1)
    }

    func testReportSummaryCountsFilesAndBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("photo.heic")
        try Data("photo".utf8).write(to: media)
        let receipt = try FileReceipt.verify(url: media, sourceName: "photo.heic", sourceBytes: 5)
        try ImportReport(startedAt: Date(), files: [receipt], errors: [], expectedFileCount: 1, completed: true).write(to: root)
        XCTAssertEqual(ArchiveReportSummary.read(folder: root), ArchiveReportSummary(files: 1, bytes: 5, completed: true))
        XCTAssertNil(ArchiveReportSummary.read(folder: root.appendingPathComponent("missing")))
    }

    @MainActor
    func testVerifyStoresLastCheckInHistoryFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let store = ArchiveHistoryStore(fileURL: file)
        store.record(root.appendingPathComponent("gone"), source: .added)
        store.verifyAll()
        for _ in 0..<200 where store.isChecking { try await Task.sleep(nanoseconds: 10_000_000) }
        let saved = try ArchiveHistoryFile.load(from: file)
        XCTAssertEqual(saved.first?.lastCheck?.outcome, .missing)
    }
}

final class VerifyArchivesCommandTests: XCTestCase {
    func testParsesOptionalHistoryPath() {
        XCTAssertEqual(try LocalPhotosSyncCLI.parse(["--verify-archives"]).get(), .verifyArchives(history: nil))
        XCTAssertEqual(try LocalPhotosSyncCLI.parse(["--verify-archives", "--history", "/tmp/h.json"]).get(),
                       .verifyArchives(history: URL(fileURLWithPath: "/tmp/h.json")))
        guard case .failure = LocalPhotosSyncCLI.parse(["--verify-archives", "--history"]) else { return XCTFail("Missing path") }
    }

    func testReportsEachArchiveAndExitCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let good = root.appendingPathComponent("good", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = good.appendingPathComponent("photo.heic")
        try Data("photo".utf8).write(to: media)
        let receipt = try FileReceipt.verify(url: media, sourceName: "photo.heic", sourceBytes: 5)
        try ImportReport(startedAt: Date(), files: [receipt], errors: [], expectedFileCount: 1, completed: true).write(to: good)
        let history = root.appendingPathComponent("history.json")

        var records = ArchiveHistoryFile.adding(good, source: .catalog, at: Date(), to: [])
        try ArchiveHistoryFile.save(records, to: history)
        let allGood = LocalPhotosSyncCLI.verifyArchives(historyAt: history)
        XCTAssertEqual(allGood.exitCode, 0)
        XCTAssertTrue(allGood.stdout.contains("\"passed\""), allGood.stdout)

        records = ArchiveHistoryFile.adding(root.appendingPathComponent("gone"), source: .added, at: Date(), to: records)
        try ArchiveHistoryFile.save(records, to: history)
        let before = try Data(contentsOf: history)
        let withMissing = LocalPhotosSyncCLI.verifyArchives(historyAt: history)
        XCTAssertEqual(withMissing.exitCode, 1)
        XCTAssertTrue(withMissing.stdout.contains("\"missing\""), withMissing.stdout)
        XCTAssertEqual(try Data(contentsOf: history), before, "The command does not modify the history")

        try Data("broken".utf8).write(to: history)
        XCTAssertEqual(LocalPhotosSyncCLI.verifyArchives(historyAt: history).exitCode, 2)
        XCTAssertEqual(LocalPhotosSyncCLI.verifyArchives(historyAt: root.appendingPathComponent("typo.json")).exitCode, 2,
                       "An explicit history path that does not exist is an error, not an empty success")
    }
}

final class ArchiveProblemFilterTests: XCTestCase {
    func testProblemUsesSessionResultBeforeStoredOne() {
        let now = Date()
        XCTAssertTrue(ArchiveHistorySummary.isProblem(.missing(at: now), last: nil))
        XCTAssertTrue(ArchiveHistorySummary.isProblem(.failed(details: "x", at: now), last: ArchiveLastCheck(at: now, outcome: .passed)))
        XCTAssertFalse(ArchiveHistorySummary.isProblem(.passed(files: 1, at: now), last: ArchiveLastCheck(at: now, outcome: .missing)))
        XCTAssertTrue(ArchiveHistorySummary.isProblem(.checking, last: ArchiveLastCheck(at: now, outcome: .failed)),
                      "Rows stay in the problems filter while being re-checked")
        XCTAssertFalse(ArchiveHistorySummary.isProblem(.checking, last: nil))
        XCTAssertTrue(ArchiveHistorySummary.isProblem(nil, last: ArchiveLastCheck(at: now, outcome: .failed)))
        XCTAssertFalse(ArchiveHistorySummary.isProblem(nil, last: nil))
    }
}

final class ArchiveDestinationTests: XCTestCase {
    func testICloudDriveIsDetectedUnderMobileDocuments() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Фото", isDirectory: true)
        let local = home.appendingPathComponent("Pictures/Архив", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertTrue(ArchiveDestination.isInICloudDrive(drive, home: home))
        XCTAssertTrue(ArchiveDestination.isInICloudDrive(home.appendingPathComponent("Library/Mobile Documents"), home: home))
        XCTAssertFalse(ArchiveDestination.isInICloudDrive(local, home: home))
        XCTAssertFalse(ArchiveDestination.isInICloudDrive(home.appendingPathComponent("Library/Mobile DocumentsX"), home: home),
                       "Only the folder itself and its contents count, not a sibling with the same prefix")
    }
}

final class ArchiveStaleTests: XCTestCase {
    func testStaleArchivesAreNeverCheckedOrOlderThanLimit() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let fresh = ArchiveRecord(id: UUID(), path: "/a", recordedAt: now, source: .catalog,
                                  lastCheck: ArchiveLastCheck(at: now.addingTimeInterval(-2 * 86_400), outcome: .passed))
        let old = ArchiveRecord(id: UUID(), path: "/b", recordedAt: now, source: .catalog,
                                lastCheck: ArchiveLastCheck(at: now.addingTimeInterval(-10 * 86_400), outcome: .failed))
        let never = ArchiveRecord(id: UUID(), path: "/c", recordedAt: now, source: .usbImport)
        XCTAssertEqual(ArchiveHistoryStore.staleIDs(in: [fresh, old, never], olderThanDays: 7, now: now), [old.id, never.id])
        XCTAssertEqual(ArchiveHistoryStore.staleIDs(in: [fresh, old, never], olderThanDays: 1, now: now), [fresh.id, old.id, never.id])
    }
}

/// Renders the Settings window for visual review (needs `LPS_RENDER_DIR`).
@MainActor
final class SettingsRenderTests: XCTestCase {
    func testRendersSettings() throws {
        let output = try ScreenRenderer.outputDirectory()
        try ScreenRenderer.render(SettingsView(), size: CGSize(width: 480, height: 560))
            .write(to: output.appendingPathComponent("settings.png"))
    }
}
