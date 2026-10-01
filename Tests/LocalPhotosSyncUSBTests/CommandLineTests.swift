import Foundation
import ImageCaptureCore
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

    func testProbeImportDefaultsToSixtySeconds() throws {
        let parent = URL(fileURLWithPath: "/tmp/photo archive", isDirectory: true).standardizedFileURL
        XCTAssertEqual(try LocalPhotosSyncCLI.parse(["--probe-import", parent.path]).get(), .probeImport(parent: parent, seconds: 60))
    }

    func testProbeImportParsesCustomBoundedTimeout() throws {
        let parent = URL(fileURLWithPath: "/tmp/archive", isDirectory: true).standardizedFileURL
        XCTAssertEqual(try LocalPhotosSyncCLI.parse(["--probe-import", parent.path, "--seconds", "120"]).get(), .probeImport(parent: parent, seconds: 120))
    }

    func testProbeImportRejectsTimeoutBelowTenSeconds() {
        XCTAssertThrowsError(try LocalPhotosSyncCLI.parse(["--probe-import", "/tmp", "--seconds", "9"]).get())
    }

    func testProbeImportRejectsTimeoutAboveOneHundredTwentySeconds() {
        XCTAssertThrowsError(try LocalPhotosSyncCLI.parse(["--probe-import", "/tmp", "--seconds", "121"]).get())
    }

    func testProbeImportRejectsNonNumericTimeout() {
        XCTAssertThrowsError(try LocalPhotosSyncCLI.parse(["--probe-import", "/tmp", "--seconds", "soon"]).get())
    }

    @MainActor
    func testProbeArchiveVerificationCompletesWithinDeadline() throws {
        let root = try makeArchive(completed: true, expectedCount: 1, errors: [])
        let deadline = ProcessInfo.processInfo.systemUptime + 5

        let result = awaitVerification(reportAt: root.appendingPathComponent("import-report.json"), deadline: deadline) { url in
            do { return .success(try ArchiveVerification.verify(reportAt: url)) }
            catch { return .failure(error.localizedDescription) }
        }

        guard case .complete(let verification) = result else { return XCTFail("Expected completed verification") }
        XCTAssertTrue(verification.isValid)
        XCTAssertEqual(verification.verifiedFiles, 1)
    }

    @MainActor
    func testProbeArchiveVerificationHonorsOverallDeadline() {
        let startedAt = ProcessInfo.processInfo.systemUptime
        // The worker outlives the deadline by a wide margin so scheduler jitter on shared CI machines
        // cannot be mistaken for waiting on the worker.
        let result = awaitVerification(reportAt: URL(fileURLWithPath: "/unused"), deadline: startedAt + 0.03) { _ in
            Thread.sleep(forTimeInterval: 1.0)
            return .success(ArchiveVerification(verifiedFiles: 1, failures: []))
        }

        guard case .timedOut = result else { return XCTFail("Expected deadline timeout") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 0.5)
    }

    func testProbeVerificationTimeoutLeavesReportIncomplete() throws {
        let root = try makeArchive(completed: true, expectedCount: 1, errors: [])

        LocalPhotosSyncCLI.markArchiveIncomplete(at: root, reason: "Probe timed out during archive verification.")

        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("import-report.json"))) as? [String: Any]
        XCTAssertEqual(report?["completed"] as? Bool, false)
        XCTAssertFalse(try ArchiveVerification.verify(reportAt: root.appendingPathComponent("import-report.json")).isValid)
    }

    @MainActor
    func testProbeDownloadDisablesSidecarTransfer() {
        let options = CameraStore.downloadOptions(to: URL(fileURLWithPath: "/tmp/probe"), includeSidecars: false)

        XCTAssertEqual(options[.sidecarFiles] as? Bool, false)
    }

    @MainActor
    func testRegularDownloadKeepsSidecarTransferEnabled() {
        let options = CameraStore.downloadOptions(to: URL(fileURLWithPath: "/tmp/ui"), includeSidecars: true)

        XCTAssertEqual(options[.sidecarFiles] as? Bool, true)
    }

    @MainActor
    private func awaitVerification(
        reportAt url: URL,
        deadline: TimeInterval,
        work: @escaping @Sendable (URL) -> LocalPhotosSyncCLI.VerificationWorkResult
    ) -> LocalPhotosSyncCLI.DeadlineVerification {
        LocalPhotosSyncCLI.waitForArchiveVerification(reportAt: url, deadline: deadline, work: work)
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
