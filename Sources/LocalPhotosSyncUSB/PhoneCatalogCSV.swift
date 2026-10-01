import Foundation

/// The catalog list as CSV for spreadsheets: one row per record of the current view.
enum PhoneCatalogCSV {
    static let header = ["id", "filename", "type", "created", "category", "hidden", "last_check", "checked_bytes", "saved_this_session"]

    static func make(assets: [PhoneCatalogAsset], checks: [Int64: PhoneAssetAvailabilityCheck],
                     saved: Set<Int64>, failed: Set<Int64>) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [header.joined(separator: ",")]
        for asset in assets {
            let type: String = switch asset.mediaType {
            case .photo: "photo"
            case .video: "video"
            case .other: "other"
            }
            let category: String = switch asset.scope {
            case .mediaLibrary: asset.isVisibleLibraryItem ? "library" : "library_extra"
            case .otherRecords: "other"
            case .unknown: "unknown"
            }
            var checkState = ""
            var checkedBytes = ""
            if let check = checks[asset.id] {
                switch check.state {
                case .mainFileReadable(let bytes): checkState = "readable"; checkedBytes = String(bytes)
                case .mainFileMissing: checkState = "missing"
                case .exceedsCopyLimit(let bytes): checkState = "too_large"; checkedBytes = String(bytes)
                case .failed: checkState = "check_failed"
                }
            }
            let savedState = saved.contains(asset.id) ? "saved" : (failed.contains(asset.id) ? "not_saved" : "")
            let fields = [String(asset.id), asset.filename, type, asset.createdAt.map(formatter.string(from:)) ?? "",
                          category, asset.isHidden ? "yes" : "no", checkState, checkedBytes, savedState]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 quoting; also neutralises leading formula characters so spreadsheets do not evaluate file names.
    static func escape(_ field: String) -> String {
        var value = field
        if let first = value.first, "=+-@".contains(first) { value = "'" + value }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
