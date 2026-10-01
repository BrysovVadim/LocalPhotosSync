import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One saved file of an archive as recorded in its report, with companion files from the same subfolder.
struct ArchiveContentsEntry: Identifiable, Equatable {
    struct Companion: Equatable {
        let name: String
        let bytes: Int64
    }

    let id: String
    let name: String
    /// Path inside the archive folder; nil for old reports that only recorded absolute paths.
    let relativePath: String?
    let bytes: Int64
    let sha256: String
    let companions: [Companion]
}

enum ArchiveContents {
    private struct Report: Decodable {
        struct File: Decodable {
            let sourceName: String
            let relativePath: String?
            let savedBytes: Int64
            let sha256: String
        }
        struct Inventory: Decodable {
            let path: String
            let bytes: Int64
        }
        let files: [File]?
        let companionFiles: [Inventory]?
    }

    /// Reads the file list from `import-report.json`; nil if the report is missing or unreadable.
    static func read(folder: URL) -> [ArchiveContentsEntry]? {
        let url = folder.appendingPathComponent("import-report.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              let report = try? JSONDecoder().decode(Report.self, from: data) else { return nil }
        var companionsByFolder: [String: [ArchiveContentsEntry.Companion]] = [:]
        for item in report.companionFiles ?? [] where isSafeRelative(item.path) {
            let folderPath = (item.path as NSString).deletingLastPathComponent
            companionsByFolder[folderPath, default: []].append(.init(name: (item.path as NSString).lastPathComponent,
                                                                     bytes: item.bytes))
        }
        return (report.files ?? []).enumerated().map { index, file in
            let relative = file.relativePath.flatMap { isSafeRelative($0) ? $0 : nil }
            let folderPath = relative.map { ($0 as NSString).deletingLastPathComponent }
            return ArchiveContentsEntry(id: relative ?? "\(index)-\(file.sourceName)", name: file.sourceName,
                                        relativePath: relative, bytes: file.savedBytes, sha256: file.sha256,
                                        companions: folderPath.flatMap { companionsByFolder[$0] } ?? [])
        }
    }

    static func isSafeRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    /// The file a report entry points to, only if it really lies inside the archive after resolving symlinks.
    static func resolve(_ relativePath: String, in folder: URL) -> URL? {
        guard isSafeRelative(relativePath) else { return nil }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let file = folder.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        return file.path.hasPrefix(root) ? file : nil
    }

    /// Only photos and videos are opened in their app; anything else is shown in Finder instead of being launched.
    static func opensDirectly(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
    }
}

/// Sheet listing what an archive folder contains, from its report.
struct ArchiveContentsSheet: View {
    let folderName: String
    /// When set, the report is read from this folder once, off the main thread.
    let folder: URL?
    let open: (String) -> Void
    let reveal: (String) -> Void
    let close: () -> Void
    @State private var entries: [ArchiveContentsEntry]?
    @State private var isLoading: Bool

    /// Shows entries that are already known (used for rendering checks).
    init(folderName: String, entries: [ArchiveContentsEntry]?, open: @escaping (String) -> Void,
         reveal: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.folderName = folderName
        folder = nil
        self.open = open
        self.reveal = reveal
        self.close = close
        _entries = State(initialValue: entries)
        _isLoading = State(initialValue: false)
    }

    /// Reads the folder's report in the background when the sheet appears.
    init(folderName: String, folder: URL, open: @escaping (String) -> Void,
         reveal: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.folderName = folderName
        self.folder = folder
        self.open = open
        self.reveal = reveal
        self.close = close
        _entries = State(initialValue: nil)
        _isLoading = State(initialValue: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(folderName).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            if isLoading {
                ProgressView("Читаем отчёт…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let entries, !entries.isEmpty {
                List(entries) { entry in
                    row(entry)
                }
                .listStyle(.inset)
            } else {
                let title: String = entries == nil ? "Отчёт не прочитан" : "Файлов нет"
                let detail: String = entries == nil ? "В папке нет читаемого import-report.json." : "Отчёт не содержит сохранённых файлов."
                ContentUnavailableView(title, systemImage: "doc.questionmark", description: Text(detail))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("Список из отчёта папки; проверка файлов — кнопкой «Проверить» в списке архивов.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Закрыть") { close() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 460)
        .task {
            guard let folder, isLoading else { return }
            entries = await Task.detached(priority: .userInitiated) { ArchiveContents.read(folder: folder) }.value
            isLoading = false
        }
    }

    private var summary: String {
        if isLoading { return "Чтение отчёта…" }
        guard let entries else { return "Отчёт не прочитан" }
        let bytes = entries.reduce(Int64(0)) { $0 + $1.bytes + $1.companions.reduce(0) { $0 + $1.bytes } }
        let companions = entries.reduce(0) { $0 + $1.companions.count }
        var text = "Файлов: \(entries.count), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        if companions > 0 { text += " · сопутствующих: \(companions)" }
        return text
    }

    private func row(_ entry: ArchiveContentsEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text("\(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)) · SHA-256 \(entry.sha256.prefix(12))…")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                if !entry.companions.isEmpty {
                    Text("+ " + entry.companions.map { "\($0.name) (\(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file)))" }
                        .joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if let path = entry.relativePath {
                Button("Открыть") { open(path) }
                Button {
                    reveal(path)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Показать в Finder")
            }
        }
        .padding(.vertical, 3)
    }
}
