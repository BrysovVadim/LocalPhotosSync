import Foundation

/// Month groups over the catalog's display order (newest first), used for headers and for jumping between pages.
struct PhoneCatalogMonth: Identifiable, Equatable {
    /// First day of the month in the given calendar, or nil for records without a creation date.
    let start: Date?
    /// Index of the first record of this month in the displayed list.
    let firstIndex: Int
    let count: Int

    var id: String { start.map { String(Int($0.timeIntervalSince1970)) } ?? "undated" }
}

enum PhoneCatalogTimeline {
    /// Consecutive runs of the same month. A month that reappears later (out-of-order dates) forms a separate run,
    /// so every run maps to one contiguous range of the displayed list.
    static func months(of assets: [PhoneCatalogAsset], calendar: Calendar = .current) -> [PhoneCatalogMonth] {
        var result: [PhoneCatalogMonth] = []
        var currentStart: Date??
        var firstIndex = 0
        var count = 0
        for (index, asset) in assets.enumerated() {
            let start = asset.createdAt.map { monthStart($0, calendar: calendar) }
            if let open = currentStart, open == start {
                count += 1
                continue
            }
            if let open = currentStart {
                result.append(PhoneCatalogMonth(start: open, firstIndex: firstIndex, count: count))
            }
            currentStart = .some(start)
            firstIndex = index
            count = 1
        }
        if let open = currentStart {
            result.append(PhoneCatalogMonth(start: open, firstIndex: firstIndex, count: count))
        }
        return result
    }

    static func page(containing index: Int, pageSize: Int) -> Int {
        guard pageSize > 0, index > 0 else { return 0 }
        return index / pageSize
    }

    /// Sections of one page: consecutive assets of the same month, in display order.
    static func sections(of pageAssets: [PhoneCatalogAsset], calendar: Calendar = .current) -> [(month: Date?, assets: [PhoneCatalogAsset])] {
        sections(of: pageAssets, date: \.createdAt, calendar: calendar).map { ($0.month, $0.items) }
    }

    /// Consecutive items of the same month, for any list that carries an optional date.
    static func sections<Item>(of items: [Item], date: (Item) -> Date?, calendar: Calendar = .current) -> [(month: Date?, items: [Item])] {
        var sections: [(month: Date?, items: [Item])] = []
        for item in items {
            let start = date(item).map { monthStart($0, calendar: calendar) }
            if let last = sections.last, last.month == start {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append((start, [item]))
            }
        }
        return sections
    }

    static func monthStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    static func title(for month: Date?, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let month else { return "Без даты" }
        var style = Date.FormatStyle(date: .omitted, time: .omitted).month(.wide).year()
        style.calendar = calendar
        style.locale = locale
        style.timeZone = calendar.timeZone
        let text = month.formatted(style)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
