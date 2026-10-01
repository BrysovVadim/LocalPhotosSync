import AppKit
import SwiftUI
import XCTest
@testable import LocalPhotosSyncUSB

final class UsbImportScreenTests: XCTestCase {
    func testFilteringByTypeAndName() {
        let items = UsbImportFixtures.items(count: 10)
        XCTAssertEqual(UsbImportFiltering.visible(items, query: "", filter: .all).count, 10)
        let videos = UsbImportFiltering.visible(items, query: "", filter: .videos)
        XCTAssertFalse(videos.isEmpty)
        XCTAssertTrue(videos.allSatisfy(\.isVideo))
        XCTAssertEqual(UsbImportFiltering.visible(items, query: "", filter: .photos).count, 10 - videos.count)
        XCTAssertEqual(UsbImportFiltering.visible(items, query: "img_0103", filter: .all).map(\.name), ["IMG_0103.MOV"])
        XCTAssertTrue(UsbImportFiltering.visible(items, query: "img_0103", filter: .photos).isEmpty)
    }

    func testSelectedBytesIgnoresUnknownAndNegativeSizes() {
        let items = [
            UsbImportItem(id: "a", name: "a", date: nil, bytes: 100, isVideo: false),
            UsbImportItem(id: "b", name: "b", date: nil, bytes: -1, isVideo: false),
            UsbImportItem(id: "c", name: "c", date: nil, bytes: 50, isVideo: true),
        ]
        XCTAssertEqual(UsbImportFiltering.selectedBytes(items, selected: ["a", "b", "zzz"]), 100)
        XCTAssertEqual(UsbImportFiltering.selectedBytes(items, selected: ["a", "c"]), 150)
        XCTAssertEqual(UsbImportFiltering.selectedBytes(items, selected: []), 0)
    }

    func testStatusSummaryCollapsesLongReports() {
        XCTAssertEqual(StatusText.summary(of: "Одна строка").headline, "Одна строка")
        XCTAssertFalse(StatusText.summary(of: "a\nb\nc").isTruncated)
        let long = StatusText.summary(of: "a\nb\nc\nd\ne")
        XCTAssertTrue(long.isTruncated)
        XCTAssertEqual(long.headline, "a\nb\n…ещё строк: 3")
        XCTAssertEqual(StatusText.summary(of: "a\n\n\nb").headline, "a\nb")
    }
}

/// Renders the USB import screen in its main states for visual review (needs `LPS_RENDER_DIR`).
@MainActor
final class UsbImportScreenRenderTests: XCTestCase {
    func testRendersUsbImportScreens() throws {
        let output = try ScreenRenderer.outputDirectory()
        let items = UsbImportFixtures.items(count: 40)
        let device = UsbImportDevice(id: "device-1", name: "iPhone")
        let archive = URL(fileURLWithPath: "/tmp/LocalPhotosSync-fixture", isDirectory: true)

        var waiting = UsbImportScreenState()
        waiting.status = "Подключите iPhone кабелем, разблокируйте его и подтвердите доверие к Mac."

        var ready = UsbImportScreenState()
        ready.devices = [device]
        ready.connectedID = device.id
        ready.connectionState = .ready
        ready.ready = true
        ready.status = "Каталог получен: 40 файлов."
        ready.items = items
        ready.selected = Set(items.prefix(4).map(\.id))

        var importing = ready
        importing.importing = true
        importing.importProcessed = 2
        importing.importTotal = 4
        importing.importedCount = 2
        importing.status = "Сохранение 3 из 4: IMG_0102.HEIC"
        importing.lastArchive = archive

        var finished = ready
        finished.lastArchive = archive
        finished.results = """
        IMG_0101.HEIC: Размер полученного файла не совпадает с каталогом.
        IMG_0103.MOV: Телефон стал недоступен.
        Телефон стал недоступен. Оставшиеся 1 файлов не обрабатывались.
        Импорт неполон.
        """
        finished.lastImportSucceeded = false
        finished.verificationResults = "Проверка пройдена. Проверено файлов: 12."
        finished.lastVerificationPassed = true
        finished.status = "Сохранено: 2 из 4. Ошибок: 3."

        var failed = UsbImportScreenState()
        failed.devices = [device]
        failed.connectedID = device.id
        failed.connectionState = .error
        failed.status = "Не удалось открыть сессию. Разблокируйте iPhone и проверьте кабель."

        let actions = UsbImportActions(thumbnail: { id in UsbImportFixtures.thumbnail(for: id) })
        let cases: [(String, UsbImportScreenState, CGSize, NSAppearance.Name)] = [
            ("usb-waiting", waiting, CGSize(width: 1060, height: 760), .aqua),
            ("usb-ready-selected", ready, CGSize(width: 1060, height: 760), .aqua),
            ("usb-importing-dark", importing, CGSize(width: 1060, height: 760), .darkAqua),
            ("usb-finished-minimum", finished, CGSize(width: 820, height: 580), .aqua),
            ("usb-error", failed, CGSize(width: 820, height: 580), .aqua),
        ]
        for (name, state, size, appearance) in cases {
            let png = try ScreenRenderer.render(UsbImportScreen(state: state, actions: actions), size: size, appearance: appearance)
            XCTAssertGreaterThan(png.count, 10_000, name)
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
    }
}

enum UsbImportFixtures {
    static func items(count: Int) -> [UsbImportItem] {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return (0..<count).map { index in
            let isVideo = index % 6 == 3
            return UsbImportItem(id: "item-\(index)",
                                 name: String(format: "IMG_%04d.%@", 100 + index, isVideo ? "MOV" : "HEIC"),
                                 date: start.addingTimeInterval(TimeInterval(-index * 86_400)),
                                 bytes: Int64(isVideo ? 24_000_000 + index * 1_000 : 2_100_000 + index * 37_000),
                                 isVideo: isVideo)
        }
    }

    /// A deterministic colored gradient standing in for a phone thumbnail.
    static func thumbnail(for id: String) -> NSImage {
        let seed = Int(id.stableHash % 360)
        let hue = CGFloat(seed) / 360
        return NSImage(size: NSSize(width: 240, height: 180), flipped: false) { rect in
            let gradient = NSGradient(starting: NSColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1),
                                      ending: NSColor(hue: hue + 0.08 > 1 ? hue - 0.08 : hue + 0.08,
                                                      saturation: 0.6, brightness: 0.55, alpha: 1))
            gradient?.draw(in: rect, angle: -60)
            return true
        }
    }
}

private extension String {
    /// Stable across runs, unlike `hashValue`.
    var stableHash: UInt {
        unicodeScalars.reduce(UInt(5381)) { ($0 &* 33) &+ UInt($1.value) }
    }
}
