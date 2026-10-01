import Foundation
import XCTest
@testable import LocalPhotosSyncUSB

final class PhoneCatalogTimelineTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func testMonthsAreContiguousRunsInDisplayOrder() {
        let assets = [
            asset(1, "2026-09-30T23:00:00Z"),
            asset(2, "2026-09-01T00:00:00Z"),
            asset(3, "2026-08-31T23:59:59Z"),
            asset(4, nil),
            asset(5, nil),
            asset(6, "2026-08-02T10:00:00Z"),
        ]
        let months = PhoneCatalogTimeline.months(of: assets, calendar: calendar)
        XCTAssertEqual(months.map(\.firstIndex), [0, 2, 3, 5])
        XCTAssertEqual(months.map(\.count), [2, 1, 2, 1])
        XCTAssertEqual(months[0].start, date("2026-09-01T00:00:00Z"))
        XCTAssertEqual(months[1].start, date("2026-08-01T00:00:00Z"))
        XCTAssertNil(months[2].start)
        XCTAssertEqual(months[3].start, date("2026-08-01T00:00:00Z"))
        XCTAssertEqual(Set(months.map(\.id)).count, 3, "A month that reappears shares its id; callers key by firstIndex")
        XCTAssertTrue(PhoneCatalogTimeline.months(of: [], calendar: calendar).isEmpty)
    }

    func testPageContainingIndex() {
        XCTAssertEqual(PhoneCatalogTimeline.page(containing: 0, pageSize: 24), 0)
        XCTAssertEqual(PhoneCatalogTimeline.page(containing: 23, pageSize: 24), 0)
        XCTAssertEqual(PhoneCatalogTimeline.page(containing: 24, pageSize: 24), 1)
        XCTAssertEqual(PhoneCatalogTimeline.page(containing: 100, pageSize: 24), 4)
        XCTAssertEqual(PhoneCatalogTimeline.page(containing: 5, pageSize: 0), 0)
    }

    func testSectionsSplitPageByMonth() {
        let assets = [asset(1, "2026-09-10T00:00:00Z"), asset(2, "2026-09-02T00:00:00Z"),
                      asset(3, "2026-07-20T00:00:00Z"), asset(4, nil)]
        let sections = PhoneCatalogTimeline.sections(of: assets, calendar: calendar)
        XCTAssertEqual(sections.map { $0.assets.map(\.id) }, [[1, 2], [3], [4]])
        XCTAssertEqual(sections.map { $0.month }, [date("2026-09-01T00:00:00Z"), date("2026-07-01T00:00:00Z"), nil])
    }

    func testTitles() {
        let september = date("2026-09-01T00:00:00Z")
        let russian = PhoneCatalogTimeline.title(for: september, calendar: calendar, locale: Locale(identifier: "ru_RU"))
        XCTAssertTrue(russian.hasPrefix("Сентябрь"), russian)
        XCTAssertTrue(russian.contains("2026"), russian)
        XCTAssertEqual(PhoneCatalogTimeline.title(for: nil, calendar: calendar), "Без даты")
    }

    private func asset(_ id: Int64, _ iso: String?) -> PhoneCatalogAsset {
        PhoneCatalogAsset(id: id, filename: "IMG_\(id).HEIC", createdAt: iso.map { date($0) }, mediaType: .photo,
                          scope: .mediaLibrary, isHidden: false, visibilityState: 0)
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }
}
