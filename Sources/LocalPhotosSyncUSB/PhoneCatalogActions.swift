import Foundation

extension PhoneCatalogAsset {
    /// Records that the catalog tab may check or copy: visible photos and videos of the main library.
    var isTransferable: Bool {
        isVisibleLibraryItem && (mediaType == .photo || mediaType == .video)
    }
}

enum PhoneCatalogPaging {
    static func pageCount(total: Int, pageSize: Int) -> Int {
        guard pageSize > 0 else { return 1 }
        return max(1, (max(0, total) + pageSize - 1) / pageSize)
    }

    static func clamp(_ page: Int, total: Int, pageSize: Int) -> Int {
        min(max(0, page), pageCount(total: total, pageSize: pageSize) - 1)
    }

    static func page<T>(_ items: [T], index: Int, pageSize: Int) -> [T] {
        guard pageSize > 0 else { return [] }
        let start = clamp(index, total: items.count, pageSize: pageSize) * pageSize
        return Array(items.dropFirst(start).prefix(pageSize))
    }
}

enum PhoneCatalogSelection {
    /// Adds transferable assets in display order until the selection reaches `limit`; existing choices are kept.
    static func adding(_ assets: [PhoneCatalogAsset], to selection: Set<Int64>, limit: Int) -> Set<Int64> {
        var result = selection
        for asset in assets where asset.isTransferable && !result.contains(asset.id) {
            guard result.count < limit else { break }
            result.insert(asset.id)
        }
        return result
    }

    /// Shift-click: adds the transferable assets between `anchor` and `target` (both inclusive, in display order),
    /// walking from the anchor towards the target until the selection reaches `limit`.
    /// Returns nil when either end is not in `assets`, so the caller can fall back to a plain toggle.
    static func addingRange(in assets: [PhoneCatalogAsset], from anchor: Int64, to target: Int64,
                            to selection: Set<Int64>, limit: Int) -> Set<Int64>? {
        guard let start = assets.firstIndex(where: { $0.id == anchor }),
              let end = assets.firstIndex(where: { $0.id == target }) else { return nil }
        let range = start <= end ? Array(assets[start...end]) : Array(assets[end...start].reversed())
        return adding(range, to: selection, limit: limit)
    }
}

/// Card sizes for the catalog grid, smallest first.
enum PhoneCatalogTileSize {
    static let steps: [Double] = [132, 168, 224]
    static let standard: Double = 168

    static func nearestIndex(to value: Double) -> Int {
        steps.indices.min { abs(steps[$0] - value) < abs(steps[$1] - value) } ?? 1
    }

    static func smaller(than value: Double) -> Double? {
        let index = nearestIndex(to: value)
        return index > 0 ? steps[index - 1] : nil
    }

    static func larger(than value: Double) -> Double? {
        let index = nearestIndex(to: value)
        return index < steps.count - 1 ? steps[index + 1] : nil
    }
}

/// Which catalog actions are available for the current selection, and a short reason when they are not.
struct PhoneCatalogActionState: Equatable {
    static let selectionLimit = 12

    let selectedCount: Int
    let canCheck: Bool
    let canSave: Bool
    let canSaveLivePhoto: Bool
    let hint: String?

    init(selected: [PhoneCatalogAsset], busy: Bool) {
        selectedCount = selected.count
        let allTransferable = selected.allSatisfy(\.isTransferable)
        let withinLimit = !selected.isEmpty && selected.count <= Self.selectionLimit
        canCheck = !busy && withinLimit && allTransferable
        canSave = canCheck
        canSaveLivePhoto = !busy && selected.count == 1 && selected[0].isTransferable && selected[0].mediaType == .photo

        if busy {
            hint = nil
        } else if selected.isEmpty {
            hint = "Выберите фото или видео на карточках, чтобы проверить или сохранить их."
        } else if !allTransferable {
            hint = "Сохранять можно только видимые фото и видео основной медиатеки."
        } else if selected.count > Self.selectionLimit {
            let extra = selected.count - Self.selectionLimit
            hint = "Выбрано \(selected.count): за один перенос — до \(Self.selectionLimit). Уберите лишние: \(extra)."
        } else {
            hint = nil
        }
    }
}
