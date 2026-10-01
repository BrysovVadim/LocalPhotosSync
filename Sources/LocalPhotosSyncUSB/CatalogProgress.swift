import Combine
import Foundation

/// Which records of a catalog snapshot were saved, and into which archive folder.
/// Keyed by snapshot folder: record IDs are only known to be stable within one snapshot, so marks do not carry
/// over to a refreshed catalog. Stores numbers and paths only, never file names or phone identifiers.
struct CatalogProgressFile: Codable, Equatable {
    struct Snapshot: Codable, Equatable {
        var updatedAt: Date
        /// Record ID → archive folder path.
        var saved: [Int64: String]
    }

    var version = 1
    var snapshots: [String: Snapshot] = [:]

    static let keptSnapshots = 5

    /// Adds saved records for a snapshot and keeps only the most recently updated snapshots.
    func adding(_ ids: Set<Int64>, snapshotFolder: URL, archive: URL, at date: Date) -> CatalogProgressFile {
        guard !ids.isEmpty else { return self }
        var copy = self
        let key = snapshotFolder.standardizedFileURL.path
        var entry = copy.snapshots[key] ?? Snapshot(updatedAt: date, saved: [:])
        for id in ids { entry.saved[id] = archive.standardizedFileURL.path }
        entry.updatedAt = date
        copy.snapshots[key] = entry
        if copy.snapshots.count > Self.keptSnapshots {
            let keep = copy.snapshots.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(Self.keptSnapshots).map(\.key)
            copy.snapshots = copy.snapshots.filter { keep.contains($0.key) }
        }
        return copy
    }

    func saved(in snapshotFolder: URL) -> [Int64: String] {
        snapshots[snapshotFolder.standardizedFileURL.path]?.saved ?? [:]
    }
}

@MainActor
final class CatalogProgressStore: ObservableObject {
    @Published private(set) var progress: CatalogProgressFile
    private let fileURL: URL?
    private var subscriptions: Set<AnyCancellable> = []

    /// `fileURL == nil` keeps progress in memory only.
    init(fileURL: URL? = CatalogProgressStore.defaultFileURL()) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            progress = (try? decoder.decode(CatalogProgressFile.self, from: data)) ?? CatalogProgressFile()
        } else {
            progress = CatalogProgressFile()
        }
    }

    nonisolated static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LocalPhotosSync", isDirectory: true)
            .appendingPathComponent("catalog-progress.json")
    }

    func savedIDs(in snapshotFolder: URL) -> [Int64: String] {
        progress.saved(in: snapshotFolder)
    }

    func record(_ ids: Set<Int64>, snapshotFolder: URL, archive: URL) {
        let updated = progress.adding(ids, snapshotFolder: snapshotFolder, archive: archive, at: Date())
        guard updated != progress else { return }
        progress = updated
        persist()
    }

    /// Records files saved by each finished catalog transfer, read once the exporter has published its final state.
    func observe(exporter: PhoneAssetExporter) {
        guard subscriptions.isEmpty else { return }
        exporter.$isTransferring
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak exporter] _ in
                guard let self, let exporter else { return }
                MainActor.assumeIsolated {
                    guard let snapshot = exporter.sourceFolder, let archive = exporter.outputFolder else { return }
                    self.record(exporter.savedAssetIDs, snapshotFolder: snapshot, archive: archive)
                }
            }
            .store(in: &subscriptions)
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(progress).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Progress marks are a convenience; a failed save must not interrupt transfers.
        }
    }
}
