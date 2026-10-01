import AppKit
import Foundation

enum ArchiveSource: String, Codable, Sendable {
    case catalog
    case usbImport
    case added

    var label: String {
        switch self {
        case .catalog: "Каталог iPhone"
        case .usbImport: "Импорт по USB"
        case .added: "Добавлена вручную"
        }
    }
}

/// An archive folder this app created or the user added. Only the path is remembered; nothing about the phone.
struct ArchiveRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let path: String
    let recordedAt: Date
    let source: ArchiveSource

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { url.lastPathComponent }
    var parentPath: String { url.deletingLastPathComponent().path }
}

enum ArchiveCheckState: Equatable, Sendable {
    case unchecked
    case checking
    case passed(files: Int, at: Date)
    case failed(details: String, at: Date)
    case missing(at: Date)
}

enum ArchiveHistoryFile {
    private struct Payload: Codable {
        var version = 1
        var archives: [ArchiveRecord]
    }

    static func load(from url: URL) throws -> [ArchiveRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Payload.self, from: Data(contentsOf: url)).archives
    }

    static func save(_ records: [ArchiveRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Payload(archives: records)).write(to: url, options: [.atomic])
    }

    /// Newest first; a folder already in the list is not added twice.
    static func adding(_ folder: URL, source: ArchiveSource, at date: Date, to records: [ArchiveRecord]) -> [ArchiveRecord] {
        let path = folder.standardizedFileURL.path
        guard !records.contains(where: { $0.url.standardizedFileURL.path == path }) else { return records }
        return [ArchiveRecord(id: UUID(), path: path, recordedAt: date, source: source)] + records
    }

    /// Checks one folder against its own report. Does not need the phone.
    static func check(folder: URL, at date: Date = Date()) -> ArchiveCheckState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missing(at: date)
        }
        do {
            let result = try ArchiveVerification.verify(reportAt: folder.appendingPathComponent("import-report.json"))
            return result.isValid
                ? .passed(files: result.verifiedFiles, at: date)
                : .failed(details: result.failures.joined(separator: "\n"), at: date)
        } catch {
            return .failed(details: "Не удалось прочитать отчёт: \(error.localizedDescription)", at: date)
        }
    }
}

@MainActor
final class ArchiveHistoryStore: ObservableObject {
    @Published private(set) var records: [ArchiveRecord]
    @Published private(set) var checks: [UUID: ArchiveCheckState]
    @Published private(set) var message: String?
    @Published private(set) var isChecking = false

    private let fileURL: URL?

    /// `fileURL == nil` keeps the history in memory only.
    init(fileURL: URL? = ArchiveHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        checks = [:]
        if let fileURL {
            do { records = try ArchiveHistoryFile.load(from: fileURL) }
            catch {
                records = []
                message = "Не удалось прочитать список архивов; новые записи заменят его."
            }
        } else {
            records = []
        }
    }

    /// Shows fixed records and results without touching disk; used for rendering checks.
    init(fixedRecords: [ArchiveRecord], checks: [UUID: ArchiveCheckState]) {
        fileURL = nil
        records = fixedRecords
        self.checks = checks
    }

    nonisolated static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LocalPhotosSync", isDirectory: true)
            .appendingPathComponent("archive-history.json")
    }

    func record(_ folder: URL, source: ArchiveSource) {
        let updated = ArchiveHistoryFile.adding(folder, source: source, at: Date(), to: records)
        guard updated != records else { return }
        records = updated
        persist()
    }

    /// Removes the entry from the list only; the folder on disk is left untouched.
    func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        checks.removeValue(forKey: id)
        persist()
    }

    func addExistingFolder() {
        let panel = NSOpenPanel()
        panel.title = "Добавить папку переноса"
        panel.message = "Выберите папку, в которой лежит import-report.json."
        panel.prompt = "Добавить"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("import-report.json").path) else {
            message = "В папке «\(folder.lastPathComponent)» нет import-report.json; это не папка переноса."
            return
        }
        message = nil
        record(folder, source: .added)
        if let id = records.first(where: { $0.url.standardizedFileURL.path == folder.standardizedFileURL.path })?.id {
            verify([id])
        }
    }

    func verifyAll() { verify(records.map(\.id)) }

    func verify(_ ids: [UUID]) {
        guard !isChecking else { return }
        let targets = records.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        isChecking = true
        for record in targets { checks[record.id] = .checking }
        Task {
            for record in targets {
                let folder = record.url
                let state = await Task.detached(priority: .utility) { ArchiveHistoryFile.check(folder: folder) }.value
                checks[record.id] = state
            }
            isChecking = false
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do { try ArchiveHistoryFile.save(records, to: fileURL) }
        catch { message = "Не удалось сохранить список архивов: \(error.localizedDescription)" }
    }
}
