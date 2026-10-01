import AppKit
import Combine
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

/// Outcome of the most recent check, kept across launches. Failure details are not stored: they name photo files.
struct ArchiveLastCheck: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case passed, failed, missing }
    let at: Date
    let outcome: Outcome
    let verifiedFiles: Int?
    let problems: Int?

    init(at: Date, outcome: Outcome, verifiedFiles: Int? = nil, problems: Int? = nil) {
        self.at = at
        self.outcome = outcome
        self.verifiedFiles = verifiedFiles
        self.problems = problems
    }

    init?(_ state: ArchiveCheckState) {
        switch state {
        case .passed(let files, let date): self.init(at: date, outcome: .passed, verifiedFiles: files)
        case .failed(let details, let date):
            self.init(at: date, outcome: .failed, problems: details.split(separator: "\n").count)
        case .missing(let date): self.init(at: date, outcome: .missing)
        case .unchecked, .checking: return nil
        }
    }
}

/// An archive folder this app created or the user added. Only the path is remembered; nothing about the phone.
struct ArchiveRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let path: String
    let recordedAt: Date
    let source: ArchiveSource
    var lastCheck: ArchiveLastCheck?

    init(id: UUID, path: String, recordedAt: Date, source: ArchiveSource, lastCheck: ArchiveLastCheck? = nil) {
        self.id = id
        self.path = path
        self.recordedAt = recordedAt
        self.source = source
        self.lastCheck = lastCheck
    }

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

/// Size of an archive as recorded in its report, read without hashing the files.
struct ArchiveReportSummary: Equatable, Sendable {
    let files: Int
    let bytes: Int64
    let completed: Bool

    private struct Report: Decodable {
        struct File: Decodable { let savedBytes: Int64 }
        struct Companion: Decodable { let bytes: Int64 }
        let files: [File]?
        let companionFiles: [Companion]?
        let completed: Bool?
    }

    static func read(folder: URL) -> ArchiveReportSummary? {
        let url = folder.appendingPathComponent("import-report.json")
        guard let data = try? Data(contentsOf: url), data.count <= 32 * 1024 * 1024,
              let report = try? JSONDecoder().decode(Report.self, from: data) else { return nil }
        let files = report.files ?? []
        let bytes = files.reduce(Int64(0)) { $0 + max(0, $1.savedBytes) } +
            (report.companionFiles ?? []).reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        return ArchiveReportSummary(files: files.count, bytes: bytes, completed: report.completed ?? false)
    }
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
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Moves an unreadable history file aside so the next save cannot overwrite it. Returns the new location.
    static func preserveUnreadable(_ url: URL, at date: Date = Date()) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("archive-history.unreadable-\(stamp).json")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Newest first; a folder already in the list is not added twice.
    static func adding(_ folder: URL, source: ArchiveSource, at date: Date, to records: [ArchiveRecord]) -> [ArchiveRecord] {
        guard !records.contains(where: { samePath($0.url, folder) }) else { return records }
        return [ArchiveRecord(id: UUID(), path: folder.standardizedFileURL.path, recordedAt: date, source: source)] + records
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
    @Published private(set) var summaries: [UUID: ArchiveReportSummary] = [:]

    private let fileURL: URL?
    /// Set when an unreadable history file could not be moved aside; saving is then refused to avoid overwriting it.
    private var persistenceBlocked = false
    private var subscriptions: Set<AnyCancellable> = []

    /// `fileURL == nil` keeps the history in memory only.
    init(fileURL: URL? = ArchiveHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        checks = [:]
        records = []
        guard let fileURL else { return }
        do {
            records = try ArchiveHistoryFile.load(from: fileURL)
        } catch {
            if let preserved = try? ArchiveHistoryFile.preserveUnreadable(fileURL) {
                message = "Список архивов не удалось прочитать; прежний файл сохранён как \(preserved.lastPathComponent). Начат новый список."
            } else {
                persistenceBlocked = true
                message = "Список архивов не удалось прочитать; изменения не сохраняются, чтобы не затереть прежний файл."
            }
        }
    }

    /// Records finished catalog exports and USB imports straight from the stores, so a folder is remembered
    /// even if the window is closed while a transfer finishes. Safe to call more than once.
    func observe(exporter: PhoneAssetExporter, camera: CameraStore) {
        guard subscriptions.isEmpty else { return }
        exporter.$outputFolder
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] folder in
                guard let self else { return }
                MainActor.assumeIsolated { self.record(folder, source: .catalog) }
            }
            .store(in: &subscriptions)
        camera.$importing
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak camera] _ in
                guard let self, let camera else { return }
                MainActor.assumeIsolated {
                    if let folder = camera.lastArchive { self.record(folder, source: .usbImport) }
                }
            }
            .store(in: &subscriptions)
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
        loadSummaries()
    }

    /// Reads file counts and sizes from each folder's report in the background; missing folders are skipped.
    func loadSummaries() {
        let pending = records.filter { summaries[$0.id] == nil }.map { ($0.id, $0.url) }
        guard !pending.isEmpty else { return }
        Task {
            let loaded = await Task.detached(priority: .utility) {
                pending.compactMap { id, folder in ArchiveReportSummary.read(folder: folder).map { (id, $0) } }
            }.value
            for (id, summary) in loaded where summaries[id] == nil && records.contains(where: { $0.id == id }) {
                summaries[id] = summary
            }
        }
    }

    /// Removes the entry from the list only; the folder on disk is left untouched.
    func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        checks.removeValue(forKey: id)
        summaries.removeValue(forKey: id)
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
        if let id = records.first(where: { ArchiveHistoryFile.samePath($0.url, folder) })?.id {
            verify([id])
        }
    }

    func verifyAll() { verify(records.map(\.id)) }

    /// Archives never checked, or last checked more than `days` days before `now`.
    nonisolated static func staleIDs(in records: [ArchiveRecord], olderThanDays days: Int, now: Date = Date()) -> [UUID] {
        let limit = now.addingTimeInterval(-TimeInterval(max(0, days)) * 86_400)
        return records.filter { ($0.lastCheck?.at ?? .distantPast) < limit }.map(\.id)
    }

    /// Re-checks stale archives in the background; used at launch when enabled in Settings.
    func verifyStale(olderThanDays days: Int) {
        verify(Self.staleIDs(in: records, olderThanDays: days))
    }

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
                // The entry may have been removed from the list while it was being checked.
                guard let index = records.firstIndex(where: { $0.id == record.id }) else { continue }
                checks[record.id] = state
                records[index].lastCheck = ArchiveLastCheck(state)
                persist()
                summaries[record.id] = await Task.detached(priority: .utility) { ArchiveReportSummary.read(folder: folder) }.value
            }
            isChecking = false
        }
    }

    private func persist() {
        guard let fileURL, !persistenceBlocked else { return }
        do { try ArchiveHistoryFile.save(records, to: fileURL) }
        catch { message = "Не удалось сохранить список архивов: \(error.localizedDescription)" }
    }
}
