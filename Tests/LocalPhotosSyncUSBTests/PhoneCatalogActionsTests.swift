import Foundation
import XCTest
@testable import LocalPhotosSyncUSB

final class PhoneCatalogActionsTests: XCTestCase {
    func testPagingClampsAndSlices() {
        let items = Array(1...50)
        XCTAssertEqual(PhoneCatalogPaging.pageCount(total: 0, pageSize: 24), 1)
        XCTAssertEqual(PhoneCatalogPaging.pageCount(total: 48, pageSize: 24), 2)
        XCTAssertEqual(PhoneCatalogPaging.pageCount(total: 50, pageSize: 24), 3)
        XCTAssertEqual(PhoneCatalogPaging.clamp(-1, total: 50, pageSize: 24), 0)
        XCTAssertEqual(PhoneCatalogPaging.clamp(9, total: 50, pageSize: 24), 2)
        XCTAssertEqual(PhoneCatalogPaging.page(items, index: 2, pageSize: 24), [49, 50])
        XCTAssertEqual(PhoneCatalogPaging.page(items, index: 7, pageSize: 24), [49, 50])
        XCTAssertEqual(PhoneCatalogPaging.page([Int](), index: 0, pageSize: 24), [])
        XCTAssertEqual(PhoneCatalogPaging.page(items, index: 0, pageSize: 0), [])
    }

    func testSelectPageAddsOnlyTransferableAssetsUpToLimit() {
        let assets = (Int64(1)...20).map { asset($0) } + [asset(21, hidden: true), asset(22, type: .other)]
        let fromEmpty = PhoneCatalogSelection.adding(assets, to: [], limit: 12)
        XCTAssertEqual(fromEmpty, Set<Int64>(1...12))

        let kept = PhoneCatalogSelection.adding(assets, to: [100, 3], limit: 12)
        XCTAssertEqual(kept.count, 12)
        XCTAssertTrue(kept.isSuperset(of: [100, 3]))
        XCTAssertEqual(kept.subtracting([100]), Set<Int64>(1...11))

        let ineligible = PhoneCatalogSelection.adding([asset(21, hidden: true), asset(22, type: .other)], to: [], limit: 12)
        XCTAssertTrue(ineligible.isEmpty)

        let alreadyFull = Set<Int64>(Int64(200)...Int64(213))
        XCTAssertEqual(PhoneCatalogSelection.adding(assets, to: alreadyFull, limit: 12), alreadyFull)
    }

    func testActionStateExplainsWhyActionsAreUnavailable() {
        let empty = PhoneCatalogActionState(selected: [], busy: false)
        XCTAssertFalse(empty.canSave || empty.canCheck || empty.canSaveLivePhoto)
        XCTAssertNotNil(empty.hint)

        let onePhoto = PhoneCatalogActionState(selected: [asset(1)], busy: false)
        XCTAssertTrue(onePhoto.canSave && onePhoto.canCheck && onePhoto.canSaveLivePhoto)
        XCTAssertNil(onePhoto.hint)

        let oneVideo = PhoneCatalogActionState(selected: [asset(1, type: .video)], busy: false)
        XCTAssertTrue(oneVideo.canSave)
        XCTAssertFalse(oneVideo.canSaveLivePhoto)

        let two = PhoneCatalogActionState(selected: [asset(1), asset(2)], busy: false)
        XCTAssertTrue(two.canSave)
        XCTAssertFalse(two.canSaveLivePhoto)

        let limit = PhoneCatalogActionState(selected: (Int64(1)...12).map { asset($0) }, busy: false)
        XCTAssertTrue(limit.canSave)
        XCTAssertNil(limit.hint)

        let overLimit = PhoneCatalogActionState(selected: (Int64(1)...15).map { asset($0) }, busy: false)
        XCTAssertFalse(overLimit.canSave || overLimit.canCheck)
        XCTAssertEqual(overLimit.selectedCount, 15)
        XCTAssertTrue(overLimit.hint?.contains("3") == true)

        let hidden = PhoneCatalogActionState(selected: [asset(1, hidden: true)], busy: false)
        XCTAssertFalse(hidden.canSave || hidden.canSaveLivePhoto)
        XCTAssertNotNil(hidden.hint)
    }

    func testBusyStateDisablesActionsWithoutHint() {
        let busy = PhoneCatalogActionState(selected: [asset(1)], busy: true)
        XCTAssertFalse(busy.canSave || busy.canCheck || busy.canSaveLivePhoto)
        XCTAssertNil(busy.hint)
    }

    func testShiftClickSelectsRangeFromAnchorUpToLimit() {
        let assets = (Int64(1)...30).map { asset($0) }
        XCTAssertEqual(PhoneCatalogSelection.addingRange(in: assets, from: 3, to: 6, to: [3], limit: 12), Set<Int64>(3...6))
        XCTAssertEqual(PhoneCatalogSelection.addingRange(in: assets, from: 6, to: 3, to: [], limit: 12), Set<Int64>(3...6))
        // Walks from the clicked target, so a capped range keeps the clicked card and its neighbours.
        XCTAssertEqual(PhoneCatalogSelection.addingRange(in: assets, from: 20, to: 1, to: [], limit: 5), Set<Int64>(1...5))
        XCTAssertEqual(PhoneCatalogSelection.addingRange(in: assets, from: 1, to: 30, to: [25], limit: 3), [25, 30, 29])
        XCTAssertEqual(PhoneCatalogSelection.addingRange(in: assets, from: 1, to: 30, to: [], limit: 12), Set<Int64>(19...30))
        XCTAssertNil(PhoneCatalogSelection.addingRange(in: assets, from: 99, to: 3, to: [], limit: 12))

        let mixed = [asset(1), asset(2, hidden: true), asset(3, type: .other), asset(4)]
        XCTAssertEqual(PhoneCatalogSelection.addingRange(in: mixed, from: 1, to: 4, to: [], limit: 12), [1, 4])
    }

    func testTileSizeSteps() {
        XCTAssertEqual(PhoneCatalogTileSize.smaller(than: 168), 132)
        XCTAssertNil(PhoneCatalogTileSize.smaller(than: 132))
        XCTAssertEqual(PhoneCatalogTileSize.larger(than: 168), 224)
        XCTAssertNil(PhoneCatalogTileSize.larger(than: 224))
        XCTAssertEqual(PhoneCatalogTileSize.larger(than: 150), 168, "Unknown stored sizes snap to the nearest step")
    }

    private func asset(_ id: Int64, type: PhoneCatalogMediaType = .photo, hidden: Bool = false) -> PhoneCatalogAsset {
        PhoneCatalogAsset(id: id, filename: "IMG_\(id).HEIC", createdAt: nil, mediaType: type,
                          scope: .mediaLibrary, isHidden: hidden, visibilityState: 0)
    }
}
