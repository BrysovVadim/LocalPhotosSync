import Foundation
import XCTest
@testable import LocalPhotosSyncUSB

final class CommandLineTests: XCTestCase {
    func testNoArgumentsSelectsGUI() throws {
        XCTAssertEqual(try LocalPhotosSyncCLI.parse([]).get(), .launchGUI)
    }

    func testHelpOptionParses() throws {
        XCTAssertEqual(try LocalPhotosSyncCLI.parse(["--help"]).get(), .help)
    }

    func testVerifyArchiveParsesFolderWithSpaces() throws {
        let folder = URL(fileURLWithPath: "/tmp/archive folder", isDirectory: true).standardizedFileURL
        XCTAssertEqual(try LocalPhotosSyncCLI.parse(["--verify-archive", folder.path]).get(), .verifyArchive(folder))
    }

    func testVerifyArchiveRejectsMissingFolderArgument() {
        XCTAssertThrowsError(try LocalPhotosSyncCLI.parse(["--verify-archive"]).get())
    }

    func testUnknownOptionIsUsageError() {
        XCTAssertThrowsError(try LocalPhotosSyncCLI.parse(["--unknown"]).get())
    }

    func testDiagnoseDefaultsToFiveSeconds() throws {
        XCTAssertEqual(try LocalPhotosSyncCLI.parse(["--diagnose"]).get(), .diagnose(seconds: 5))
    }

    func testDiagnoseAcceptsBoundedDuration() throws {
        XCTAssertEqual(try LocalPhotosSyncCLI.parse(["--diagnose", "--seconds", "30"]).get(), .diagnose(seconds: 30))
    }

    func testDiagnoseRejectsDurationOverThirtySeconds() {
        XCTAssertThrowsError(try LocalPhotosSyncCLI.parse(["--diagnose", "--seconds", "31"]).get())
    }

    func testValidArchiveReturnsJSONAndSuccessCode() throws {
        let root = try makeArchive(completed: true, expectedCount: 1, errors: [])

        let outcome = LocalPhotosSyncCLI.verifyArchive(at: root)

        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertTrue(outcome.stderr.isEmpty)
        let json = try JSONDecoder().decode(VerificationJSON.self, from: Data(outcome.stdout.utf8))
        XCTAssertTrue(json.valid)
        XCTAssertEqual(json.verifiedFiles, 1)
    }

    func testIncompleteArchiveReturnsFailureCode() throws {
        let root = try makeArchive(completed: false, expectedCount: 1, errors: [])

        let outcome = LocalPhotosSyncCLI.verifyArchive(at: root)

        XCTAssertEqual(outcome.exitCode, 1)
        let json = try JSONDecoder().decode(VerificationJSON.self, from: Data(outcome.stdout.utf8))
        XCTAssertFalse(json.valid)
    }

    func testMissingArchiveReportReturnsRuntimeErrorCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        let outcome = LocalPhotosSyncCLI.verifyArchive(at: root)

        XCTAssertEqual(outcome.exitCode, 2)
        let json = try JSONDecoder().decode(ErrorJSON.self, from: Data(outcome.stdout.utf8))
        XCTAssertFalse(json.error.isEmpty)
    }

    func testDiagnosticsAreJSONEncoded() throws {
        let outcome = LocalPhotosSyncCLI.diagnosticResult("Devices: 0\nSession: closed")

        XCTAssertEqual(outcome.exitCode, 0)
        let json = try JSONDecoder().decode(DiagnosticJSON.self, from: Data(outcome.stdout.utf8))
        XCTAssertEqual(json.diagnostics, "Devices: 0\nSession: closed")
    }

    private func makeArchive(completed: Bool, expectedCount: Int, errors: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let media = root.appendingPathComponent("photo.heic")
        try Data("photo".utf8).write(to: media)
        let receipt = try FileReceipt.verify(url: media, sourceName: "photo.heic", sourceBytes: 5)
        try ImportReport(startedAt: Date(), files: [receipt], errors: errors, expectedFileCount: expectedCount, completed: completed).write(to: root)
        return root
    }

    private struct VerificationJSON: Decodable { let valid: Bool; let verifiedFiles: Int }
    private struct ErrorJSON: Decodable { let error: String }
    private struct DiagnosticJSON: Decodable { let diagnostics: String }
}
