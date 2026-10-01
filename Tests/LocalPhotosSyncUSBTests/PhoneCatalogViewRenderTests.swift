import AppKit
import SwiftUI
import XCTest
@testable import LocalPhotosSyncUSB

/// Renders the catalog screen with fixture data to PNG files for visual review.
/// Runs only when `LPS_RENDER_DIR` names an output folder; CI uploads that folder as an artifact.
@MainActor
final class PhoneCatalogViewRenderTests: XCTestCase {
    func testRendersCatalogScreens() throws {
        let output = try ScreenRenderer.outputDirectory()

        let snapshot = Self.fixtureSnapshot()
        let ids = snapshot.assets(category: .mediaLibrary).map(\.id)
        let cases: [(name: String, size: CGSize, selection: Set<Int64>, appearance: NSAppearance.Name)] = [
            ("catalog-wide-light", CGSize(width: 1060, height: 760), [], .aqua),
            ("catalog-wide-dark", CGSize(width: 1060, height: 760), Set(ids.prefix(3)), .darkAqua),
            ("catalog-minimum-selected", CGSize(width: 820, height: 580), Set(ids.prefix(1)), .aqua),
            ("catalog-over-limit", CGSize(width: 1060, height: 760), Set(ids.prefix(15)), .aqua),
        ]
        for item in cases {
            let view = PhoneCatalogView(exporter: PhoneAssetExporter(),
                                        reader: PhoneCatalogReader(fixedSnapshot: snapshot),
                                        selected: item.selection)
            let png = try ScreenRenderer.render(view, size: item.size, appearance: item.appearance)
            XCTAssertGreaterThan(png.count, 10_000, item.name)
            try png.write(to: output.appendingPathComponent("\(item.name).png"))
        }

        let defaults = UserDefaults.standard
        let previousSize = defaults.object(forKey: "catalog.tileSize")
        defaults.set(PhoneCatalogTileSize.steps.last, forKey: "catalog.tileSize")
        defer { defaults.set(previousSize, forKey: "catalog.tileSize") }
        let large = PhoneCatalogView(exporter: PhoneAssetExporter(),
                                     reader: PhoneCatalogReader(fixedSnapshot: snapshot))
        try ScreenRenderer.render(large, size: CGSize(width: 1060, height: 760))
            .write(to: output.appendingPathComponent("catalog-large-tiles.png"))
    }

    private static func fixtureSnapshot() -> PhoneCatalogSnapshot {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var assets: [PhoneCatalogAsset] = []
        for index in 0..<60 {
            let id = Int64(1_000 + index)
            let isVideo = index % 7 == 3
            assets.append(PhoneCatalogAsset(
                id: id,
                filename: isVideo ? "IMG_\(4_200 + index).MOV" : "IMG_\(4_200 + index).HEIC",
                createdAt: start.addingTimeInterval(TimeInterval(-index * 129_600)),
                mediaType: isVideo ? .video : .photo,
                scope: .mediaLibrary,
                isHidden: false,
                visibilityState: 0))
        }
        assets.append(PhoneCatalogAsset(id: 2_000, filename: "IMG_0001.HEIC", createdAt: start, mediaType: .photo,
                                        scope: .mediaLibrary, isHidden: true, visibilityState: 0))
        assets.append(PhoneCatalogAsset(id: 2_001, filename: "IMG_0002.JPG", createdAt: start, mediaType: .photo,
                                        scope: .otherRecords, isHidden: false, visibilityState: 0))
        return PhoneCatalogSnapshot(assets: assets, snapshotDate: start,
                                    sourceFolder: URL(fileURLWithPath: "/nonexistent/phone-catalog-fixture", isDirectory: true))
    }
}
