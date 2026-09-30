import Foundation
import SQLite3
import XCTest
@testable import LocalPhotosSyncUSB

final class PhoneCatalogReaderTests: XCTestCase {
    func testFiltersVisibleLibraryAndAllNontrashedCategories() throws {
        let database = try makeDatabase(rows: [
            (1, "library.heic", 0, 0, 0, 0, 0),
            (2, "movie.mov", 1, 0, 0, 0, 0),
            (3, "hidden.heic", 0, 0, 1, 0, 0),
            (4, "series.heic", 0, 0, 0, 0, 2),
            (5, "shared.heic", 0, 3, 0, 0, 0),
            (6, "unknown.heic", 0, nil, 0, 0, 0),
            (7, "trashed.heic", 0, 0, 0, 1, 0),
        ])
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }

        let snapshot = try PhoneCatalogDatabase.load(from: database.deletingLastPathComponent())
        XCTAssertEqual(snapshot.assets(category: .mediaLibrary).map(\.filename), ["movie.mov", "library.heic"])
        XCTAssertEqual(snapshot.counts(in: .mediaLibrary).photos, 1)
        XCTAssertEqual(snapshot.counts(in: .mediaLibrary).videos, 1)
        XCTAssertEqual(Set(snapshot.assets(category: .allRecords).map(\.filename)),
                       Set(["library.heic", "movie.mov", "hidden.heic", "series.heic", "shared.heic", "unknown.heic"]))
        XCTAssertEqual(snapshot.assets(category: .otherRecords).map(\.filename), ["shared.heic"])
        XCTAssertEqual(snapshot.assets(category: .unknownScope).map(\.filename), ["unknown.heic"])
        XCTAssertEqual(snapshot.assets(category: .allRecords, type: .videos).map(\.filename), ["movie.mov"])
        XCTAssertEqual(snapshot.assets(category: .allRecords, search: "SHARED").map(\.filename), ["shared.heic"])
    }

    func testUnknownSchemaFailsWithoutQueryingRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("Photos.sqlite")
        try execute("CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZFILENAME TEXT)", at: database)
        try writeReceipt(for: database)

        XCTAssertThrowsError(try PhoneCatalogDatabase.load(from: directory)) { error in
            XCTAssertEqual(error as? PhoneCatalogError, .unknownSchema)
        }
    }

    func testWellFormedDatabaseWithoutCompletionReceiptIsRejected() throws {
        let database = try makeDatabase(rows: [(1, "partial.heic", 0, 0, 0, 0, 0)])
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: database.deletingLastPathComponent().appendingPathComponent("catalog-receipt.json"))

        XCTAssertThrowsError(try PhoneCatalogDatabase.load(from: database.deletingLastPathComponent())) { error in
            XCTAssertEqual(error as? PhoneCatalogError, .snapshotUnavailable)
        }
    }

    func testNullCategoricalValueFailsAndNullDateStaysAbsent() throws {
        let database = try makeDatabase(rows: [(1, "date.heic", 0, 0, 0, 0, 0)])
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        try execute("UPDATE ZASSET SET ZDATECREATED=NULL", at: database)
        try writeReceipt(for: database)
        let snapshot = try PhoneCatalogDatabase.load(from: database.deletingLastPathComponent())
        XCTAssertNil(snapshot.assets.first?.createdAt)

        try execute("UPDATE ZASSET SET ZHIDDEN=NULL", at: database)
        try writeReceipt(for: database)
        XCTAssertThrowsError(try PhoneCatalogDatabase.load(from: database.deletingLastPathComponent())) { error in
            XCTAssertEqual(error as? PhoneCatalogError, .databaseReadFailed)
        }
    }

    private func makeDatabase(rows: [(Int64, String, Int64, Int64?, Int64, Int64, Int64)]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let database = directory.appendingPathComponent("Photos.sqlite")
        try execute("""
        CREATE TABLE ZASSET (
          Z_PK INTEGER PRIMARY KEY, ZFILENAME TEXT, ZDATECREATED REAL, ZKIND INTEGER,
          ZBUNDLESCOPE INTEGER, ZHIDDEN INTEGER, ZTRASHEDSTATE INTEGER, ZVISIBILITYSTATE INTEGER
        )
        """, at: database)
        for row in rows {
            let scope = row.3.map(String.init) ?? "NULL"
            let escapedName = row.1.replacingOccurrences(of: "'", with: "''")
            try execute("INSERT INTO ZASSET VALUES (\(row.0), '\(escapedName)', 1, \(row.2), \(scope), \(row.4), \(row.5), \(row.6))", at: database)
        }
        try writeReceipt(for: database)
        return database
    }

    private func writeReceipt(for database: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: database.path)[.size] as? NSNumber)?.int64Value ?? 0
        let receipt: [String: Any] = [
            "source": "iphone_afc", "status": "metadata_copy_complete",
            "capturedAt": "2026-09-30T12:00:00.000Z", "usbDevices": 1,
            "candidateBytes": size, "sqliteHeader": true,
            "databaseBytesCopied": size, "databaseStableObserved": true,
            "walPresent": false, "walBytesCopied": 0, "walStableObserved": false,
            "stabilityProven": false, "assetCounts": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        let receiptURL = database.deletingLastPathComponent().appendingPathComponent("catalog-receipt.json")
        try data.write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    }

    private func execute(_ sql: String, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw PhoneCatalogError.databaseReadFailed
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw PhoneCatalogError.databaseReadFailed
        }
    }
}
