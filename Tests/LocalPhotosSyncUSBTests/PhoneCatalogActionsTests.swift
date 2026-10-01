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

    func testFollowUpsAfterCheckAndTransfer() {
        let folder = URL(fileURLWithPath: "/snapshot-a")
        let other = URL(fileURLWithPath: "/snapshot-b")
        let assets = (Int64(1)...6).map { asset($0) } + [asset(7, hidden: true)]
        let snapshot = PhoneCatalogSnapshot(assets: assets, snapshotDate: Date(), sourceFolder: folder)
        let now = Date()
        let checks: [Int64: PhoneAssetAvailabilityCheck] = [
            1: PhoneAssetAvailabilityCheck(state: .mainFileReadable(bytes: 10), sourceFolder: folder, checkedAt: now),
            2: PhoneAssetAvailabilityCheck(state: .mainFileMissing, sourceFolder: folder, checkedAt: now),
            3: PhoneAssetAvailabilityCheck(state: .exceedsCopyLimit(bytes: 99), sourceFolder: folder, checkedAt: now),
            4: PhoneAssetAvailabilityCheck(state: .failed, sourceFolder: folder, checkedAt: now),
            5: PhoneAssetAvailabilityCheck(state: .mainFileMissing, sourceFolder: other, checkedAt: now),
        ]
        let followUps = PhoneCatalogFollowUps(selection: [1, 2, 3, 4, 5, 6], checks: checks, checksFolder: folder,
                                              failed: [2, 6, 7], exportFolder: folder, snapshot: snapshot, isBusy: false)
        XCTAssertEqual(followUps.notReadable, [2, 3, 4], "Unchecked and other-snapshot results are kept")
        XCTAssertEqual(followUps.unsaved, [2, 6], "Non-transferable failures are not offered")

        let stale = PhoneCatalogFollowUps(selection: [2], checks: checks, checksFolder: other,
                                          failed: [2], exportFolder: other, snapshot: snapshot, isBusy: false)
        XCTAssertTrue(stale.notReadable.isEmpty && stale.unsaved.isEmpty)

        let busy = PhoneCatalogFollowUps(selection: [2], checks: checks, checksFolder: folder,
                                         failed: [2], exportFolder: folder, snapshot: snapshot, isBusy: true)
        XCTAssertTrue(busy.notReadable.isEmpty && busy.unsaved.isEmpty)
    }

    func testFilterStorageCodesRoundTripAndFallBack() {
        for category in PhoneCatalogCategory.allCases {
            XCTAssertEqual(PhoneCatalogCategory(storageCode: category.storageCode), category)
        }
        for type in PhoneCatalogTypeFilter.allCases {
            XCTAssertEqual(PhoneCatalogTypeFilter(storageCode: type.storageCode), type)
        }
        XCTAssertEqual(PhoneCatalogCategory(storageCode: "Медиатека"), .mediaLibrary, "Unknown codes fall back to the default")
        XCTAssertEqual(PhoneCatalogTypeFilter(storageCode: ""), .all)
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

final class PhoneCatalogDiagnosticsTests: XCTestCase {
    @MainActor
    func testDiagnosticsContainCountsButNoFileNames() {
        let assets = [
            PhoneCatalogAsset(id: 1, filename: "SECRET_NAME.HEIC", createdAt: nil, mediaType: .photo,
                              scope: .mediaLibrary, isHidden: false, visibilityState: 0),
            PhoneCatalogAsset(id: 2, filename: "OTHER.MOV", createdAt: nil, mediaType: .video,
                              scope: .otherRecords, isHidden: false, visibilityState: 0),
        ]
        let reader = PhoneCatalogReader(fixedSnapshot: PhoneCatalogSnapshot(
            assets: assets, snapshotDate: Date(timeIntervalSince1970: 1_790_000_000),
            sourceFolder: URL(fileURLWithPath: "/nonexistent/snapshot")))
        let text = reader.diagnostics(thumbnailsLoaded: 3, autoLoadPreviews: true)
        XCTAssertTrue(text.contains("Media library: photos=1 videos=0"), text)
        XCTAssertTrue(text.contains("total=2"), text)
        XCTAssertTrue(text.contains("Previews in memory: 3"), text)
        XCTAssertFalse(text.contains("SECRET_NAME"))
        XCTAssertFalse(text.contains("OTHER.MOV"))
        XCTAssertFalse(text.contains("/nonexistent"), "Paths of the snapshot folder are not included")
    }
}

final class PhoneCatalogCSVTests: XCTestCase {
    func testRowsQuotingAndStates() {
        let folder = URL(fileURLWithPath: "/s")
        let assets = [
            PhoneCatalogAsset(id: 1, filename: "IMG_1.HEIC", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                              mediaType: .photo, scope: .mediaLibrary, isHidden: false, visibilityState: 0),
            PhoneCatalogAsset(id: 2, filename: "a,\"b\".mov", createdAt: nil, mediaType: .video,
                              scope: .otherRecords, isHidden: true, visibilityState: 0),
            PhoneCatalogAsset(id: 3, filename: "=cmd()", createdAt: nil, mediaType: .other,
                              scope: .unknown, isHidden: false, visibilityState: 0),
        ]
        let checks: [Int64: PhoneAssetAvailabilityCheck] = [1: PhoneAssetAvailabilityCheck(state: .mainFileReadable(bytes: 42), sourceFolder: folder, checkedAt: Date())]
        let csv = PhoneCatalogCSV.make(assets: assets, checks: checks, saved: [1], failed: [2])
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], PhoneCatalogCSV.header.joined(separator: ","))
        XCTAssertEqual(lines[1], "1,IMG_1.HEIC,photo,2026-09-21T14:13:20Z,library,no,readable,42,saved")
        XCTAssertEqual(lines[2], "2,\"a,\"\"b\"\".mov\",video,,other,yes,,,not_saved")
        XCTAssertEqual(lines[3], "3,'=cmd(),other,,unknown,no,,,")
        XCTAssertEqual(lines.count, 5, "Trailing CRLF after the last row")
    }
}
