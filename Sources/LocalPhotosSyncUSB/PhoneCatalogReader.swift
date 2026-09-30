import Foundation
import Combine
import SQLite3

enum PhoneCatalogMediaType: Equatable, Sendable {
    case photo
    case video
    case other
}

enum PhoneCatalogScope: Equatable, Sendable {
    case mediaLibrary
    case otherRecords
    case unknown
}

struct PhoneCatalogAsset: Identifiable, Equatable, Sendable {
    let id: Int64
    let filename: String
    let createdAt: Date?
    let mediaType: PhoneCatalogMediaType
    let scope: PhoneCatalogScope
    let isHidden: Bool
    let visibilityState: Int64

    var isVisibleLibraryItem: Bool {
        scope == .mediaLibrary && !isHidden && visibilityState == 0
    }
}

enum PhoneCatalogCategory: String, CaseIterable, Identifiable {
    case mediaLibrary = "Медиатека"
    case allRecords = "Все записи"
    case otherRecords = "Другие записи"
    case unknownScope = "Неизвестная категория"

    var id: String { rawValue }
}

enum PhoneCatalogTypeFilter: String, CaseIterable, Identifiable {
    case all = "Все"
    case photos = "Фото"
    case videos = "Видео"

    var id: String { rawValue }
}

struct PhoneCatalogSnapshot: Equatable, Sendable {
    let assets: [PhoneCatalogAsset]
    let snapshotDate: Date

    func assets(category: PhoneCatalogCategory, type: PhoneCatalogTypeFilter = .all, search: String = "") -> [PhoneCatalogAsset] {
        assets.filter { asset in
            let categoryMatches: Bool
            switch category {
            case .mediaLibrary: categoryMatches = asset.isVisibleLibraryItem
            case .allRecords: categoryMatches = true
            case .otherRecords: categoryMatches = asset.scope == .otherRecords
            case .unknownScope: categoryMatches = asset.scope == .unknown
            }
            let typeMatches: Bool
            switch type {
            case .all: typeMatches = true
            case .photos: typeMatches = asset.mediaType == .photo
            case .videos: typeMatches = asset.mediaType == .video
            }
            return categoryMatches && typeMatches &&
                (search.isEmpty || asset.filename.localizedCaseInsensitiveContains(search))
        }
    }

    func counts(in category: PhoneCatalogCategory) -> (photos: Int, videos: Int) {
        let selected = assets(category: category)
        return (selected.filter { $0.mediaType == .photo }.count,
                selected.filter { $0.mediaType == .video }.count)
    }
}

enum PhoneCatalogError: Error, LocalizedError, Equatable {
    case snapshotUnavailable
    case unknownSchema
    case databaseReadFailed

    var errorDescription: String? {
        switch self {
        case .snapshotUnavailable: return "Не удалось открыть сохранённый каталог телефона."
        case .unknownSchema: return "Структура каталога телефона неизвестна; список не загружен."
        case .databaseReadFailed: return "Не удалось прочитать каталог телефона."
        }
    }
}

enum PhoneCatalogDatabase {
    private static let requiredColumns: Set<String> = [
        "Z_PK", "ZFILENAME", "ZDATECREATED", "ZKIND", "ZBUNDLESCOPE",
        "ZHIDDEN", "ZTRASHEDSTATE", "ZVISIBILITYSTATE",
    ]

    private struct CompletionReceipt: Decodable {
        let source: String
        let status: String
        let capturedAt: String
        let usbDevices: Int
        let candidateBytes: Int64
        let sqliteHeader: Bool
        let databaseBytesCopied: Int64
        let databaseStableObserved: Bool
        let walPresent: Bool
        let walBytesCopied: Int64
        let walStableObserved: Bool
        let stabilityProven: Bool
        let assetCounts: Int?
    }

    static func load(from snapshotFolder: URL) throws -> PhoneCatalogSnapshot {
        let databaseURL = snapshotFolder.appendingPathComponent("Photos.sqlite")
        let snapshotDate = try validateReceipt(in: snapshotFolder, databaseURL: databaseURL)
        try validateSidecars(in: snapshotFolder)
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else { throw PhoneCatalogError.databaseReadFailed }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF;", nil, nil, nil) == SQLITE_OK else {
            throw PhoneCatalogError.databaseReadFailed
        }
        try validateSchema(database)

        let sql = """
        SELECT Z_PK, ZFILENAME, ZDATECREATED, ZKIND, ZBUNDLESCOPE, ZHIDDEN, ZTRASHEDSTATE, ZVISIBILITYSTATE
        FROM ZASSET
        ORDER BY ZDATECREATED DESC, Z_PK DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PhoneCatalogError.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }

        var assets: [PhoneCatalogAsset] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw PhoneCatalogError.databaseReadFailed }
            let filename = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let dateType = sqlite3_column_type(statement, 2)
            let rawDate: Double?
            if dateType == SQLITE_NULL {
                rawDate = nil
            } else if dateType == SQLITE_INTEGER || dateType == SQLITE_FLOAT {
                let value = sqlite3_column_double(statement, 2)
                rawDate = value.isFinite ? value : nil
            } else {
                rawDate = nil
            }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 5) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 6) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 7) == SQLITE_INTEGER else {
                throw PhoneCatalogError.databaseReadFailed
            }
            let scopeType = sqlite3_column_type(statement, 4)
            guard scopeType == SQLITE_INTEGER || scopeType == SQLITE_NULL else { throw PhoneCatalogError.databaseReadFailed }
            let kind = sqlite3_column_int64(statement, 3)
            let trashed = sqlite3_column_int64(statement, 6)
            let rawScope = scopeType == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 4)
            let hidden = sqlite3_column_int64(statement, 5) != 0
            let visibility = sqlite3_column_int64(statement, 7)
            guard trashed == 0 else { continue }
            assets.append(PhoneCatalogAsset(
                id: sqlite3_column_int64(statement, 0),
                filename: filename,
                createdAt: rawDate.map { Date(timeIntervalSince1970: $0 + 978_307_200) },
                mediaType: kind == 0 ? .photo : (kind == 1 ? .video : .other),
                scope: rawScope == 0 ? .mediaLibrary : (rawScope == 3 ? .otherRecords : .unknown),
                isHidden: hidden,
                visibilityState: visibility
            ))
        }
        return PhoneCatalogSnapshot(assets: assets, snapshotDate: snapshotDate)
    }

    private static func validateReceipt(in folder: URL, databaseURL: URL) throws -> Date {
        let receiptURL = folder.appendingPathComponent("catalog-receipt.json")
        guard isRegularFileWithoutSymlink(databaseURL), isRegularFileWithoutSymlink(receiptURL),
              let receiptAttributes = try? FileManager.default.attributesOfItem(atPath: receiptURL.path),
              let receiptPermissions = receiptAttributes[.posixPermissions] as? NSNumber,
              receiptPermissions.intValue == 0o600,
              let contents = try? Data(contentsOf: receiptURL),
              let object = try? JSONSerialization.jsonObject(with: contents) as? [String: Any],
              Set(object.keys) == Set([
                "source", "status", "capturedAt", "usbDevices", "candidateBytes", "sqliteHeader",
                "databaseBytesCopied", "databaseStableObserved", "walPresent", "walBytesCopied",
                "walStableObserved", "stabilityProven", "assetCounts",
              ]),
              let receipt = try? JSONDecoder().decode(CompletionReceipt.self, from: contents),
              receipt.source == "iphone_afc", receipt.status == "metadata_copy_complete",
              receipt.usbDevices == 1, receipt.candidateBytes >= 16,
              receipt.candidateBytes <= 256 * 1024 * 1024, receipt.sqliteHeader,
              receipt.databaseBytesCopied > 0,
              receipt.databaseBytesCopied <= 256 * 1024 * 1024,
              receipt.walBytesCopied >= 0, receipt.walBytesCopied <= 64 * 1024 * 1024,
              !receipt.stabilityProven, receipt.assetCounts == nil else {
            throw PhoneCatalogError.snapshotUnavailable
        }
        let databaseBytes = try fileSize(databaseURL)
        guard databaseBytes == receipt.databaseBytesCopied,
              try hasSQLiteHeader(databaseURL) else { throw PhoneCatalogError.snapshotUnavailable }
        let walURL = folder.appendingPathComponent("Photos.sqlite-wal")
        guard let directoryContents = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            throw PhoneCatalogError.snapshotUnavailable
        }
        let names = Set(directoryContents)
        if receipt.walPresent {
            guard names.contains(walURL.lastPathComponent), isRegularFileWithoutSymlink(walURL),
                  try fileSize(walURL) == receipt.walBytesCopied else {
                throw PhoneCatalogError.snapshotUnavailable
            }
        } else {
            guard receipt.walBytesCopied == 0, !names.contains(walURL.lastPathComponent) else {
                throw PhoneCatalogError.snapshotUnavailable
            }
        }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        guard let date = fractionalFormatter.date(from: receipt.capturedAt) ?? standardFormatter.date(from: receipt.capturedAt) else {
            throw PhoneCatalogError.snapshotUnavailable
        }
        return date
    }

    private static func validateSidecars(in folder: URL) throws {
        guard let directoryContents = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            throw PhoneCatalogError.snapshotUnavailable
        }
        let entries = Set(directoryContents)
        for name in ["Photos.sqlite-wal", "Photos.sqlite-shm"] where entries.contains(name) {
            guard isRegularFileWithoutSymlink(folder.appendingPathComponent(name)) else {
                throw PhoneCatalogError.snapshotUnavailable
            }
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { throw PhoneCatalogError.snapshotUnavailable }
        return size.int64Value
    }

    private static func hasSQLiteHeader(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: 16) == Data("SQLite format 3\0".utf8)
    }

    private static func isRegularFileWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func validateSchema(_ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(ZASSET)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw PhoneCatalogError.unknownSchema }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
        }
        guard requiredColumns.isSubset(of: columns) else { throw PhoneCatalogError.unknownSchema }
    }

}

@MainActor
final class PhoneCatalogReader: ObservableObject {
    @Published private(set) var snapshot: PhoneCatalogSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingSnapshot = false
    @Published private(set) var errorMessage: String?

    private let buildDirectory: URL?

    convenience init() {
        self.init(buildDirectory: Self.findBuildDirectory())
    }

    init(buildDirectory: URL?) {
        self.buildDirectory = buildDirectory
        if buildDirectory != nil {
            isLoadingSnapshot = true
            Task { await loadLatestSnapshot() }
        }
    }

    func refresh() {
        guard let buildDirectory else {
            errorMessage = "Не удалось найти каталог приложения для обновления."
            return
        }
        guard !isRefreshing, !isLoadingSnapshot else { return }
        isRefreshing = true
        errorMessage = nil
        Task {
            let result = await Self.runRefresh(buildDirectory: buildDirectory)
            switch result {
            case .success(let loaded): snapshot = loaded; errorMessage = nil
            case .failure(let error): errorMessage = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    private func loadLatestSnapshot() async {
        guard let buildDirectory else { return }
        let result = await Self.loadLatest(in: buildDirectory)
        switch result {
        case .success(let loaded): snapshot = loaded
        case .failure(let error): errorMessage = error.localizedDescription
        }
        isLoadingSnapshot = false
    }

    nonisolated private static func runRefresh(buildDirectory: URL) async -> Result<PhoneCatalogSnapshot, PhoneCatalogError> {
        await Task.detached(priority: .utility) {
            do {
                let repo = buildDirectory.deletingLastPathComponent()
                let runner = repo.appendingPathComponent("experiments/afc/run-probe.py")
                guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
                      FileManager.default.fileExists(atPath: runner.path) else { return .failure(.snapshotUnavailable) }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [runner.path, "--copy-metadata"]
                process.currentDirectoryURL = repo
                var environment = ProcessInfo.processInfo.environment
                environment.removeValue(forKey: "USBMUXD_SOCKET_ADDRESS")
                environment["DYLD_LIBRARY_PATH"] = localLibraryPath(in: repo.appendingPathComponent(".build/afc-runtime"))
                process.environment = environment
                let output = Pipe()
                process.standardOutput = output
                process.standardError = Pipe()
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["source"] as? String == "iphone_afc",
                      object["status"] as? String == "metadata_copy_complete",
                      let path = object["snapshotPath"] as? String else { return .failure(.snapshotUnavailable) }
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                guard isContained(folder, in: buildDirectory.appendingPathComponent("phone-catalog-probe", isDirectory: true)) else {
                    return .failure(.snapshotUnavailable)
                }
                return loadSnapshot(folder: folder)
            } catch {
                return .failure(.snapshotUnavailable)
            }
        }.value
    }

    nonisolated private static func loadLatest(in buildDirectory: URL) async -> Result<PhoneCatalogSnapshot, PhoneCatalogError> {
        await Task.detached(priority: .utility) {
            let root = buildDirectory.appendingPathComponent("phone-catalog-probe", isDirectory: true)
            guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                return .failure(.snapshotUnavailable)
            }
            let sorted = folders.sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            for folder in sorted where isContained(folder, in: root) {
                if case .success(let result) = loadSnapshot(folder: folder) { return .success(result) }
            }
            return .failure(.snapshotUnavailable)
        }.value
    }

    nonisolated private static func loadSnapshot(folder: URL) -> Result<PhoneCatalogSnapshot, PhoneCatalogError> {
        let database = folder.appendingPathComponent("Photos.sqlite")
        guard isRegularFileWithoutSymlink(database) else { return .failure(.snapshotUnavailable) }
        do {
            return .success(try PhoneCatalogDatabase.load(from: folder))
        } catch let error as PhoneCatalogError {
            return .failure(error)
        } catch {
            return .failure(.databaseReadFailed)
        }
    }

    nonisolated private static func isRegularFileWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    nonisolated private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(base)
    }

    nonisolated private static func localLibraryPath(in runtime: URL) -> String {
        let enumerator = FileManager.default.enumerator(at: runtime, includingPropertiesForKeys: nil)
        var directories = Set<URL>()
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "dylib" { directories.insert(url.deletingLastPathComponent()) }
        }
        return directories.map(\.path).sorted().joined(separator: ":")
    }

    nonisolated private static func findBuildDirectory() -> URL? {
        var current = Bundle.main.bundleURL.standardizedFileURL
        while current.path != "/" {
            if current.lastPathComponent == ".build" { return current }
            current.deleteLastPathComponent()
        }
        return nil
    }
}
