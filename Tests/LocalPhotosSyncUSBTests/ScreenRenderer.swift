import AppKit
import SwiftUI
import XCTest

/// Renders SwiftUI screens to PNG for visual review. Enabled only when `LPS_RENDER_DIR` is set.
@MainActor
enum ScreenRenderer {
    static func outputDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["LPS_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("Set LPS_RENDER_DIR to render screens.")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        return output
    }

    static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name = .aqua) throws -> Data {
        let hosting = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
