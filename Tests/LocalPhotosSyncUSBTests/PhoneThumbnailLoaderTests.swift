import Darwin
import Foundation
import XCTest
@testable import LocalPhotosSyncUSB

final class PhoneThumbnailLoaderTests: XCTestCase {
    func testDeadlineTerminatesRunnerAndItsChildProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent(".build/phone-catalog-probe/snapshot", isDirectory: true)
        let scripts = root.appendingPathComponent("experiments/afc", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = """
        import subprocess, sys, time
        from pathlib import Path
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        Path(sys.argv[2]).joinpath('test-child.pid').write_text(str(child.pid))
        child.wait()
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("run-thumbnail-probe.py"))
        let pidFile = folder.appendingPathComponent("test-child.pid")
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) {
                _ = kill(pid, SIGKILL)
            }
        }

        let started = ProcessInfo.processInfo.systemUptime
        let result = PhoneThumbnailLoader.fetch(assetID: 1, snapshotFolder: folder, timeout: 1)

        guard case .failed(let message) = result else { return XCTFail("Deadline must fail the request") }
        XCTAssertTrue(message.contains("слишком много времени"))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 5)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText))
        for _ in 0..<100 where kill(pid, 0) == 0 { usleep(10_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "The helper child must be terminated with its runner")
    }
}
