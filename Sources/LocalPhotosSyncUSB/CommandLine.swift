import Foundation
import SwiftUI
import Darwin

enum LocalPhotosSyncCLI {
    enum Command: Equatable {
        case launchGUI
        case help
        case verifyArchive(URL)
        case diagnose(seconds: Int)
        case probeImport(parent: URL, seconds: Int)
        case verifyArchives(history: URL?)
    }
    enum ParseError: Error, Equatable { case message(String) }
    enum DeadlineVerification {
        case complete(ArchiveVerification)
        case failed(String)
        case timedOut
    }
    enum VerificationWorkResult: Sendable {
        case success(ArchiveVerification)
        case failure(String)
    }
    @MainActor
    private final class VerificationBridge {
        var result: VerificationWorkResult?
    }

    struct Outcome {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    static func parse(_ arguments: [String]) -> Result<Command, ParseError> {
        guard let first = arguments.first else { return .success(.launchGUI) }
        if first == "--help" || first == "-h" {
            guard arguments.count == 1 else { return .failure(.message("--help takes no arguments")) }
            return .success(.help)
        }
        if first == "--verify-archive" {
            guard arguments.count == 2, !arguments[1].isEmpty else { return .failure(.message("Usage: LocalPhotosSyncUSB --verify-archive <folder>")) }
            return .success(.verifyArchive(URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL))
        }
        if first == "--verify-archives" {
            if arguments.count == 1 { return .success(.verifyArchives(history: nil)) }
            guard arguments.count == 3, arguments[1] == "--history", !arguments[2].isEmpty else {
                return .failure(.message("Usage: LocalPhotosSyncUSB --verify-archives [--history <archive-history.json>]"))
            }
            return .success(.verifyArchives(history: URL(fileURLWithPath: arguments[2]).standardizedFileURL))
        }
        if first == "--diagnose" {
            if arguments.count == 1 { return .success(.diagnose(seconds: 5)) }
            guard arguments.count == 3, arguments[1] == "--seconds",
                  let seconds = Int(arguments[2]), (0...30).contains(seconds) else {
                return .failure(.message("Usage: LocalPhotosSyncUSB --diagnose [--seconds 0...30]"))
            }
            return .success(.diagnose(seconds: seconds))
        }
        if first == "--probe-import" {
            guard arguments.count == 2 || arguments.count == 4, !arguments[1].isEmpty else {
                return .failure(.message("Usage: LocalPhotosSyncUSB --probe-import <existing-parent-folder> [--seconds 10...120]"))
            }
            let seconds: Int
            if arguments.count == 2 { seconds = 60 }
            else {
                guard arguments[2] == "--seconds", let parsed = Int(arguments[3]), (10...120).contains(parsed) else {
                    return .failure(.message("Usage: LocalPhotosSyncUSB --probe-import <existing-parent-folder> [--seconds 10...120]"))
                }
                seconds = parsed
            }
            return .success(.probeImport(parent: URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL, seconds: seconds))
        }
        return .failure(.message("Unknown option: \(first). Use --help for usage."))
    }

    static func usage() -> String {
        """
        Usage:
          LocalPhotosSyncUSB                 Launch the graphical app
          LocalPhotosSyncUSB --verify-archive <folder>
          LocalPhotosSyncUSB --verify-archives [--history <archive-history.json>]
          LocalPhotosSyncUSB --diagnose [--seconds 0...30]
          LocalPhotosSyncUSB --probe-import <existing-parent-folder> [--seconds 10...120]
          LocalPhotosSyncUSB --help
        """
    }

    static func verifyArchive(at folder: URL) -> Outcome {
        do {
            let verification = try ArchiveVerification.verify(reportAt: folder.appendingPathComponent("import-report.json"))
            let json = try encodeJSON(VerificationResult(valid: verification.isValid, verifiedFiles: verification.verifiedFiles, failures: verification.failures))
            return Outcome(exitCode: verification.isValid ? 0 : 1, stdout: json, stderr: "")
        } catch {
            let json = (try? encodeJSON(RuntimeError(error: error.localizedDescription))) ?? "{\"error\":\"Verification failed\"}"
            return Outcome(exitCode: 2, stdout: json, stderr: "")
        }
    }

    private struct ArchivesResult: Encodable {
        struct Entry: Encodable {
            let path: String
            let status: String
            let verifiedFiles: Int
            let failures: [String]
        }
        let archives: [Entry]
        let passed: Int
        let problems: Int
    }

    /// Checks every archive the app remembers. Read-only: the history file is not updated, so it cannot race the app.
    static func verifyArchives(historyAt url: URL?) -> Outcome {
        guard let url = url ?? ArchiveHistoryStore.defaultFileURL() else {
            return Outcome(exitCode: 2, stdout: "{\"error\":\"History location unavailable\"}", stderr: "")
        }
        let records: [ArchiveRecord]
        do { records = try ArchiveHistoryFile.load(from: url) }
        catch {
            let json = (try? encodeJSON(RuntimeError(error: "Archive history is unreadable: \(error.localizedDescription)"))) ?? "{\"error\":\"Archive history is unreadable\"}"
            return Outcome(exitCode: 2, stdout: json, stderr: "")
        }
        let entries = records.map { record -> ArchivesResult.Entry in
            switch ArchiveHistoryFile.check(folder: record.url) {
            case .passed(let files, _):
                return .init(path: record.path, status: "passed", verifiedFiles: files, failures: [])
            case .failed(let details, _):
                return .init(path: record.path, status: "failed", verifiedFiles: 0,
                             failures: details.split(separator: "\n").map(String.init))
            case .missing:
                return .init(path: record.path, status: "missing", verifiedFiles: 0, failures: [])
            case .unchecked, .checking:
                return .init(path: record.path, status: "unchecked", verifiedFiles: 0, failures: [])
            }
        }
        let passed = entries.filter { $0.status == "passed" }.count
        let result = ArchivesResult(archives: entries, passed: passed, problems: entries.count - passed)
        do { return Outcome(exitCode: passed == entries.count ? 0 : 1, stdout: try encodeJSON(result), stderr: "") }
        catch { return Outcome(exitCode: 2, stdout: "", stderr: error.localizedDescription) }
    }

    static func diagnosticResult(_ diagnostics: String) -> Outcome {
        do { return Outcome(exitCode: 0, stdout: try encodeJSON(DiagnosticResult(diagnostics: diagnostics)), stderr: "") }
        catch { return Outcome(exitCode: 2, stdout: "", stderr: error.localizedDescription) }
    }

    @MainActor
    static func probeImport(parent: URL, seconds: Int) -> Outcome {
        var archive: URL?
        var selectedCount = 0
        guard (10...120).contains(seconds) else { return probeResult(archive: nil, selected: 0, imported: 0, verified: 0, valid: false, errors: ["invalid_timeout"]) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return probeResult(archive: nil, selected: 0, imported: 0, verified: 0, valid: false, errors: ["parent_folder_unavailable"])
        }

        let deadline = ProcessInfo.processInfo.systemUptime + TimeInterval(seconds)
        let store = CameraStore()
        while ProcessInfo.processInfo.systemUptime < deadline && !store.deviceDiscoveryComplete {
            if store.devices.count > 1 {
                return probeResult(archive: nil, selected: 0, imported: 0, verified: 0, valid: false, errors: ["multiple_devices_detected"])
            }
            pumpRunLoop(until: deadline)
        }
        guard store.deviceDiscoveryComplete, store.devices.count == 1 else {
            return probeResult(archive: nil, selected: 0, imported: 0, verified: 0, valid: false, errors: [ProcessInfo.processInfo.systemUptime >= deadline ? "timeout_waiting_for_device" : "device_count_not_one"])
        }
        guard store.currentTransportLabel == "USB" else {
            return probeResult(archive: nil, selected: 0, imported: 0, verified: 0, valid: false, errors: ["usb_transport_required"])
        }
        while ProcessInfo.processInfo.systemUptime < deadline && !store.ready {
            if store.devices.count != 1 || store.currentTransportLabel != "USB" {
                return probeResult(archive: nil, selected: 0, imported: 0, verified: 0, valid: false, errors: ["device_or_transport_changed"])
            }
            pumpRunLoop(until: deadline)
        }
        guard store.ready else {
            return probeResult(archive: nil, selected: 0, imported: 0, verified: 0, valid: false, errors: ["timeout_waiting_for_catalog"])
        }
        guard store.devices.count == 1 else {
            return probeResult(archive: nil, selected: 0, imported: 0, verified: 0, valid: false, errors: ["multiple_devices_detected"])
        }
        guard let selection = store.selectProbeFiles(maxBytes: 32 * 1024 * 1024) else {
            return probeResult(archive: nil, selected: 0, imported: 0, verified: 0, valid: false, errors: ["eligible_photo_not_found"])
        }
        selectedCount = selection.fileCount
        archive = store.importSelected(to: parent, includeSidecars: false)
        guard let archive else {
            return probeResult(archive: nil, selected: selectedCount, imported: 0, verified: 0, valid: false, errors: ["import_could_not_start"])
        }
        while store.importing && ProcessInfo.processInfo.systemUptime < deadline { pumpRunLoop(until: deadline) }
        guard !store.importing else {
            store.cancelImport()
            return probeResult(archive: archive, selected: selectedCount, imported: store.importedCount, verified: 0, valid: false, errors: ["timeout_cancelled_import"], selectedPhotos: selection.photoCount, selectedVideos: selection.videoCount, selectedSourceBytes: selection.sourceBytes)
        }
        let verificationResult = waitForArchiveVerification(reportAt: archive.appendingPathComponent("import-report.json"), deadline: deadline) { url in
            do { return .success(try ArchiveVerification.verify(reportAt: url)) }
            catch { return .failure("archive_verification_error") }
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            markArchiveIncomplete(at: archive, reason: "Probe timed out during archive verification.")
            return probeResult(archive: archive, selected: selectedCount, imported: store.importedCount, verified: 0, valid: false, errors: ["timeout_verifying_archive"], selectedPhotos: selection.photoCount, selectedVideos: selection.videoCount, selectedSourceBytes: selection.sourceBytes)
        }
        switch verificationResult {
        case .complete(let verification):
            let valid = verification.isValid && verification.verifiedFiles == selectedCount && store.importedCount == selectedCount
            return probeResult(
                archive: archive,
                selected: selectedCount,
                imported: store.importedCount,
                verified: verification.verifiedFiles,
                valid: valid,
                errors: valid ? [] : ["archive_verification_failed"],
                selectedPhotos: selection.photoCount,
                selectedVideos: selection.videoCount,
                selectedSourceBytes: selection.sourceBytes
            )
        case .failed(let error):
            return probeResult(archive: archive, selected: selectedCount, imported: store.importedCount, verified: 0, valid: false, errors: [error], selectedPhotos: selection.photoCount, selectedVideos: selection.videoCount, selectedSourceBytes: selection.sourceBytes)
        case .timedOut:
            markArchiveIncomplete(at: archive, reason: "Probe timed out during archive verification.")
            return probeResult(archive: archive, selected: selectedCount, imported: store.importedCount, verified: 0, valid: false, errors: ["timeout_verifying_archive"], selectedPhotos: selection.photoCount, selectedVideos: selection.videoCount, selectedSourceBytes: selection.sourceBytes)
        }
    }

    static func markArchiveIncomplete(at archive: URL, reason: String) {
        let reportURL = archive.appendingPathComponent("import-report.json")
        do {
            var report = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any] ?? [:]
            report["completed"] = false
            var errors = report["errors"] as? [String] ?? []
            errors.append(reason)
            report["errors"] = errors
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
        } catch {
            // The caller still reports timeout as failure if an unreadable report cannot be amended.
        }
    }

    @MainActor
    static func waitForArchiveVerification(
        reportAt url: URL,
        deadline: TimeInterval,
        work: @escaping @Sendable (URL) -> VerificationWorkResult
    ) -> DeadlineVerification {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return .timedOut }
        let bridge = VerificationBridge()
        Task.detached(priority: .utility) {
            let result = work(url)
            await MainActor.run { bridge.result = result }
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            if case .some = bridge.result { break }
            pumpRunLoop(until: deadline)
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return .timedOut }
        guard let result = bridge.result else { return .timedOut }
        switch result {
        case .success(let verification): return .complete(verification)
        case .failure(let error): return .failed(error)
        }
    }

    private static func pumpRunLoop(until deadline: TimeInterval) {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: min(0.1, remaining))) }
    }

    private static func probeResult(archive: URL?, selected: Int, imported: Int, verified: Int, valid: Bool, errors: [String], selectedPhotos: Int = 0, selectedVideos: Int = 0, selectedSourceBytes: Int64 = 0) -> Outcome {
        let result = ProbeImportResult(archivePath: archive?.path, selectedFiles: selected, selectedPhotos: selectedPhotos, selectedVideos: selectedVideos, selectedSourceBytes: selectedSourceBytes, importedFiles: imported, verifiedFiles: verified, valid: valid, errors: errors)
        do { return Outcome(exitCode: valid ? 0 : 1, stdout: try encodeJSON(result), stderr: "") }
        catch { return Outcome(exitCode: 1, stdout: "{\"archivePath\":null,\"selectedFiles\":0,\"selectedPhotos\":0,\"selectedVideos\":0,\"selectedSourceBytes\":0,\"importedFiles\":0,\"verifiedFiles\":0,\"valid\":false,\"errors\":[\"result_encoding_failed\"]}", stderr: "") }
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private struct VerificationResult: Encodable { let valid: Bool; let verifiedFiles: Int; let failures: [String] }
    private struct RuntimeError: Encodable { let error: String }
    private struct DiagnosticResult: Encodable { let diagnostics: String }
    private struct ProbeImportResult: Encodable {
        let archivePath: String?
        let selectedFiles: Int
        let selectedPhotos: Int
        let selectedVideos: Int
        let selectedSourceBytes: Int64
        let importedFiles: Int
        let verifiedFiles: Int
        let valid: Bool
        let errors: [String]
    }
}

@main
@MainActor
private struct LocalPhotosSyncMain {
    static func main() {
        switch LocalPhotosSyncCLI.parse(Array(CommandLine.arguments.dropFirst())) {
        case .failure(.message(let message)):
            FileHandle.standardError.write(Data((message + "\n" + LocalPhotosSyncCLI.usage() + "\n").utf8))
            Foundation.exit(2)
        case .success(.help):
            print(LocalPhotosSyncCLI.usage())
            Foundation.exit(0)
        case .success(.launchGUI):
            LocalPhotosSyncApp.main()
        case .success(.verifyArchive(let folder)):
            emit(LocalPhotosSyncCLI.verifyArchive(at: folder))
        case .success(.diagnose(let seconds)):
            let store = CameraStore()
            if seconds > 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: TimeInterval(seconds))) }
            emit(LocalPhotosSyncCLI.diagnosticResult(store.diagnostics()))
        case .success(.probeImport(let parent, let seconds)):
            emit(LocalPhotosSyncCLI.probeImport(parent: parent, seconds: seconds))
        case .success(.verifyArchives(let history)):
            emit(LocalPhotosSyncCLI.verifyArchives(historyAt: history))
        }
    }

    private static func emit(_ outcome: LocalPhotosSyncCLI.Outcome) {
        if !outcome.stdout.isEmpty { print(outcome.stdout) }
        if !outcome.stderr.isEmpty { FileHandle.standardError.write(Data((outcome.stderr + "\n").utf8)) }
        Foundation.exit(outcome.exitCode)
    }
}
