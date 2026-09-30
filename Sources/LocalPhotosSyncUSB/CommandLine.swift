import Foundation
import SwiftUI
import Darwin

enum LocalPhotosSyncCLI {
    enum Command: Equatable {
        case launchGUI
        case help
        case verifyArchive(URL)
        case diagnose(seconds: Int)
    }
    enum ParseError: Error, Equatable { case message(String) }

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
        if first == "--diagnose" {
            if arguments.count == 1 { return .success(.diagnose(seconds: 5)) }
            guard arguments.count == 3, arguments[1] == "--seconds",
                  let seconds = Int(arguments[2]), (0...30).contains(seconds) else {
                return .failure(.message("Usage: LocalPhotosSyncUSB --diagnose [--seconds 0...30]"))
            }
            return .success(.diagnose(seconds: seconds))
        }
        return .failure(.message("Unknown option: \(first). Use --help for usage."))
    }

    static func usage() -> String {
        """
        Usage:
          LocalPhotosSyncUSB                 Launch the graphical app
          LocalPhotosSyncUSB --verify-archive <folder>
          LocalPhotosSyncUSB --diagnose [--seconds 0...30]
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

    static func diagnosticResult(_ diagnostics: String) -> Outcome {
        do { return Outcome(exitCode: 0, stdout: try encodeJSON(DiagnosticResult(diagnostics: diagnostics)), stderr: "") }
        catch { return Outcome(exitCode: 2, stdout: "", stderr: error.localizedDescription) }
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private struct VerificationResult: Encodable { let valid: Bool; let verifiedFiles: Int; let failures: [String] }
    private struct RuntimeError: Encodable { let error: String }
    private struct DiagnosticResult: Encodable { let diagnostics: String }
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
        }
    }

    private static func emit(_ outcome: LocalPhotosSyncCLI.Outcome) {
        if !outcome.stdout.isEmpty { print(outcome.stdout) }
        if !outcome.stderr.isEmpty { FileHandle.standardError.write(Data((outcome.stderr + "\n").utf8)) }
        Foundation.exit(outcome.exitCode)
    }
}
