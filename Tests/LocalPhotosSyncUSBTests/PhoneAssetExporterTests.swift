import CryptoKit
import Foundation
import XCTest
@testable import LocalPhotosSyncUSB

final class PhoneAssetExporterTests: XCTestCase {
    private enum FixtureBehavior: Sendable {
        case copy(Data, corruptHash: Bool)
        case fail(String)
    }

    @MainActor
    func testSuccessfulCopyProducesVerifiedArchiveAndRetainsFilenameExtension() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let asset = makeAsset(id: 41, filename: "IMG_0041.MOV", type: .video)
        let exporter = PhoneAssetExporter(probeRunner: Self.fakeRunner(
            cacheRoot: fixture.cacheRoot,
            behaviors: [41: .copy(Data("available-file-content".utf8), corruptHash: false)]
        ))

        exporter.export(assets: [asset], snapshot: fixture.snapshot, destination: fixture.destination)
        await waitForCompletion(exporter)

        XCTAssertFalse(exporter.isExporting)
        XCTAssertEqual(exporter.savedAssetIDs, [41])
        XCTAssertTrue(exporter.failedAssetIDs.isEmpty)
        XCTAssertEqual(exporter.exportedCount, 1)
        let runFolder = try XCTUnwrap(exporter.outputFolder)
        let savedURL = runFolder.appendingPathComponent("00001/IMG_0041.MOV")
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        let reportURL = runFolder.appendingPathComponent("import-report.json")
        let verification = try ArchiveVerification.verify(reportAt: reportURL)
        XCTAssertTrue(verification.isValid, "\(verification.failures)")
        XCTAssertEqual(verification.verifiedFiles, 1)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
        XCTAssertEqual(report["completed"] as? Bool, true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: reportURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testStreamHashMismatchLeavesArchiveIncomplete() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let asset = makeAsset(id: 52, filename: "photo.heic", type: .photo)
        let exporter = PhoneAssetExporter(probeRunner: Self.fakeRunner(
            cacheRoot: fixture.cacheRoot,
            behaviors: [52: .copy(Data("received bytes".utf8), corruptHash: true)]
        ))

        exporter.export(assets: [asset], snapshot: fixture.snapshot, destination: fixture.destination)
        await waitForCompletion(exporter)

        XCTAssertTrue(exporter.savedAssetIDs.isEmpty)
        XCTAssertEqual(exporter.failedAssetIDs, [52])
        let reportURL = try XCTUnwrap(exporter.outputFolder).appendingPathComponent("import-report.json")
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
        XCTAssertEqual(report["completed"] as? Bool, false)
        XCTAssertTrue((report["errors"] as? [String])?.contains(where: { $0.contains("52") }) == false)
    }

    @MainActor
    func testUnavailableSecondAssetKeepsFirstAssetAndIncompleteCheckpoint() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = makeAsset(id: 61, filename: "first.heic", type: .photo)
        let second = makeAsset(id: 62, filename: "second.mov", type: .video)
        let exporter = PhoneAssetExporter(probeRunner: Self.fakeRunner(
            cacheRoot: fixture.cacheRoot,
            behaviors: [61: .copy(Data("first available".utf8), corruptHash: false), 62: .fail("asset_unavailable")]
        ))

        exporter.export(assets: [first, second], snapshot: fixture.snapshot, destination: fixture.destination)
        await waitForCompletion(exporter)

        XCTAssertEqual(exporter.savedAssetIDs, [61])
        XCTAssertEqual(exporter.failedAssetIDs, [62])
        XCTAssertEqual(exporter.exportedCount, 1)
        XCTAssertEqual(exporter.failedCount, 1)
        let runFolder = try XCTUnwrap(exporter.outputFolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runFolder.appendingPathComponent("00001/first.heic").path))
        let reportURL = runFolder.appendingPathComponent("import-report.json")
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
        XCTAssertEqual(report["completed"] as? Bool, false)
        XCTAssertEqual(report["expectedFileCount"] as? Int, 2)
        let verification = try ArchiveVerification.verify(reportAt: reportURL)
        XCTAssertFalse(verification.isValid)
        XCTAssertEqual(verification.verifiedFiles, 1)
    }

    @MainActor
    func testHiddenAndNonLibraryAssetsAreRefusedBeforeExport() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let hidden = PhoneCatalogAsset(id: 71, filename: "hidden.heic", createdAt: nil, mediaType: .photo,
                                       scope: .mediaLibrary, isHidden: true, visibilityState: 0)
        let exporter = PhoneAssetExporter(probeRunner: { _, _, _, _ in XCTFail("Runner must not be called"); return .cancelled })

        exporter.export(assets: [hidden], snapshot: fixture.snapshot, destination: fixture.destination)

        XCTAssertFalse(exporter.isExporting)
        XCTAssertNil(exporter.outputFolder)
        XCTAssertEqual(exporter.failedAssetIDs, [71])
    }

    func testProbeDeadlineStopsSleepingChild() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let script = try makeProbeScript("import time\ntime.sleep(30)\n")
        defer { try? FileManager.default.removeItem(at: script) }
        let cancellation = PhoneAssetExportCancellation()
        let started = ProcessInfo.processInfo.systemUptime

        let result = await runRealProbe(snapshot: fixture.snapshot.sourceFolder, script: script,
                                        timeout: 0.25, cancellation: cancellation)

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2.0)
        if case .timedOut = result { } else { XCTFail("Expected bounded child timeout") }
    }

    func testProbeCancellationStopsChild() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let script = try makeProbeScript("import time\ntime.sleep(30)\n")
        defer { try? FileManager.default.removeItem(at: script) }
        let cancellation = PhoneAssetExportCancellation()
        let task = Task.detached {
            PhoneAssetExporter.runProbe(41, fixture.snapshot.sourceFolder, 5, cancellation, scriptURL: script)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        cancellation.cancel()
        let result = await task.value

        if case .cancelled = result { } else { XCTFail("Expected child cancellation") }
    }

    func testProbeDeadlineIncludesDescendantHoldingStdoutAfterParentExit() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let script = try makeProbeScript("import subprocess,sys\nsubprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'])\n")
        defer { try? FileManager.default.removeItem(at: script) }
        let cancellation = PhoneAssetExportCancellation()
        let started = ProcessInfo.processInfo.systemUptime

        let result = await runRealProbe(snapshot: fixture.snapshot.sourceFolder, script: script,
                                        timeout: 0.25, cancellation: cancellation)

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2.0)
        if case .timedOut = result { } else { XCTFail("Expected timeout while descendant holds stdout") }
    }

    func testLauncherPreAcknowledgementSignalStopsChildAndDescendant() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let markers = fixture.root.appendingPathComponent("launcher-markers", isDirectory: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let childScript = """
        import os,sys,time,signal,subprocess
        root=sys.argv[1]
        def stopped(path):
         open(path,'w').close()
         raise SystemExit(0)
        descendant="import os,sys,time,signal; root=sys.argv[1]; signal.signal(signal.SIGTERM,lambda s,f:(open(os.path.join(root,'descendant-stopped'),'w').close(),sys.exit(0))); open(os.path.join(root,'descendant.pid'),'w').write(str(os.getpid())); time.sleep(30)"
        signal.signal(signal.SIGTERM,lambda s,f:stopped(os.path.join(root,'child-stopped')))
        child=subprocess.Popen([sys.executable,'-c',descendant,root])
        open(os.path.join(root,'child.pid'),'w').write(str(os.getpid()))
        while not os.path.exists(os.path.join(root,'descendant.pid')): time.sleep(0.01)
        time.sleep(30)
        """
        let script = try makeProbeScript(childScript)
        defer { try? FileManager.default.removeItem(at: script) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", PhoneAssetExporter.processGroupLauncherSource, script.path, markers.path]
        process.standardOutput = Pipe() // Deliberately leave READY unread to exercise the pre-ack path.
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { _ = kill(process.processIdentifier, SIGTERM); process.waitUntilExit() } }

        let markerDeadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < markerDeadline &&
            (!FileManager.default.fileExists(atPath: markers.appendingPathComponent("child.pid").path) ||
             !FileManager.default.fileExists(atPath: markers.appendingPathComponent("descendant.pid").path)) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: markers.appendingPathComponent("child.pid").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markers.appendingPathComponent("descendant.pid").path))
        _ = kill(process.processIdentifier, SIGTERM)
        let parentDeadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < parentDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning,
           let childPID = Int32(try String(contentsOf: markers.appendingPathComponent("child.pid"), encoding: .utf8)) {
            _ = kill(-pid_t(childPID), SIGKILL)
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning, "Launcher did not stop after its signal handler ran")

        let stopDeadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < stopDeadline &&
            (!FileManager.default.fileExists(atPath: markers.appendingPathComponent("child-stopped").path) ||
             !FileManager.default.fileExists(atPath: markers.appendingPathComponent("descendant-stopped").path)) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: markers.appendingPathComponent("child-stopped").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markers.appendingPathComponent("descendant-stopped").path))
    }

    private func makeFixture() throws -> (root: URL, snapshot: PhoneCatalogSnapshot, destination: URL, cacheRoot: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let build = root.appendingPathComponent(".build", isDirectory: true)
        let snapshotRoot = build.appendingPathComponent("phone-catalog-probe", isDirectory: true)
        let snapshotFolder = snapshotRoot.appendingPathComponent("fixture", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let cacheRoot = build.appendingPathComponent("phone-asset-copy-probe", isDirectory: true)
        for folder in [snapshotFolder, destination, cacheRoot] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let snapshot = PhoneCatalogSnapshot(assets: [], snapshotDate: Date(), sourceFolder: snapshotFolder)
        return (root, snapshot, destination, cacheRoot)
    }

    private func makeAsset(id: Int64, filename: String, type: PhoneCatalogMediaType) -> PhoneCatalogAsset {
        PhoneCatalogAsset(id: id, filename: filename, createdAt: nil, mediaType: type,
                          scope: .mediaLibrary, isHidden: false, visibilityState: 0)
    }

    private func makeProbeScript(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".py")
        try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    private func runRealProbe(snapshot: URL, script: URL, timeout: TimeInterval,
                              cancellation: PhoneAssetExportCancellation) async -> PhoneAssetCopyProbeResult {
        await Task.detached {
            PhoneAssetExporter.runProbe(41, snapshot, timeout, cancellation, scriptURL: script)
        }.value
    }

    private static func fakeRunner(cacheRoot: URL, behaviors: [Int64: FixtureBehavior]) -> PhoneAssetExporter.ProbeRunner {
        { assetID, snapshotFolder, _, cancellation in
            guard !cancellation.isCancelled, let behavior = behaviors[assetID] else { return .cancelled }
            switch behavior {
            case .fail(let status): return .failed(status: status)
            case .copy(let bytes, let corruptHash):
                do {
                    let filenameByID: [Int64: String] = [41: "IMG_0041.MOV", 52: "photo.heic", 61: "first.heic", 62: "second.mov"]
                    guard let filename = filenameByID[assetID] else { return .failed(status: "fixture_failure") }
                    let folder = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    let media = folder.appendingPathComponent("media.bin")
                    try bytes.write(to: media, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: media.path)
                    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    let streamHash = corruptHash ? String(repeating: "0", count: 64) : digest
                    let count = bytes.count
                    let copyReceipt: [String: Any] = [
                        "source": "iphone_afc", "status": "asset_copy_complete", "declaredBytes": count,
                        "copiedBytes": count, "stableObserved": true, "receivedStreamSHA256": streamHash,
                    ]
                    let fullReceipt: [String: Any] = [
                        "source": "iphone_afc", "status": "asset_copy_complete",
                        "sourceSnapshot": snapshotFolder.resolvingSymlinksInPath().path,
                        "assetID": assetID, "filename": filename,
                        "ZKIND": assetID == 41 || assetID == 62 ? 1 : 0,
                        "ZORIGINALFILESIZE": NSNull(), "ZORIGINALRESOURCECHOICE": NSNull(),
                        "linkedResources": NSNull(), "declaredBytes": count, "copiedBytes": count,
                        "stableObserved": true, "receivedStreamSHA256": streamHash,
                    ]
                    try Self.writeJSON(copyReceipt, to: folder.appendingPathComponent("copy-receipt.json"))
                    try Self.writeJSON(fullReceipt, to: folder.appendingPathComponent("asset-copy-receipt.json"))
                    return .copied(folder: folder, bytes: Int64(count), stableObserved: true)
                } catch {
                    return .failed(status: "fixture_failure")
                }
            }
        }
    }

    private static func writeJSON(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @MainActor
    private func waitForCompletion(_ exporter: PhoneAssetExporter) async {
        for _ in 0..<500 where exporter.isExporting {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(exporter.isExporting, "Exporter did not finish its local fixture run")
    }
}
