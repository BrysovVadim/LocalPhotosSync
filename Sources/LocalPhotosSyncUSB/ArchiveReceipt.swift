import CryptoKit
import Foundation

struct FileReceipt: Codable, Sendable {
    let sourceName: String
    let savedPath: String
    let sourceBytes: Int64
    let savedBytes: Int64
    let sha256: String
    let savedAt: Date
    var relativePath: String? = nil
    let companions: [CompanionReceipt]

    struct CompanionReceipt: Codable, Sendable {
        let filename: String
        let bytes: Int64
        let sha256: String
    }

    static func verify(url: URL, sourceName: String, sourceBytes: Int64) throws -> FileReceipt {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            count += Int64(data.count)
            hash.update(data: data)
        }
        guard count > 0 else { throw ArchiveError.emptyFile }
        guard sourceBytes <= 0 || count == sourceBytes else {
            throw ArchiveError.sizeMismatch(expected: sourceBytes, actual: count)
        }
        let primaryPath = url.standardizedFileURL
        let companions = try FileManager.default.contentsOfDirectory(at: primaryPath.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter {
                guard $0.standardizedFileURL != primaryPath,
                      let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
            .map { companion -> CompanionReceipt in
                let digest = try Self.digest(companion)
                return CompanionReceipt(filename: companion.lastPathComponent, bytes: digest.bytes, sha256: digest.sha256)
            }.sorted { $0.filename < $1.filename }
        return FileReceipt(
            sourceName: sourceName,
            savedPath: url.path,
            sourceBytes: sourceBytes,
            savedBytes: count,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
            savedAt: Date(),
            companions: companions
        )
    }

    private static func digest(_ url: URL) throws -> (bytes: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(); var count: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { count += Int64(data.count); hash.update(data: data) }
        guard count > 0 else { throw ArchiveError.emptyFile }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func archiveDigest(_ url: URL) throws -> (bytes: Int64, sha256: String) { try digest(url) }
}

struct ImportReport: Encodable, Sendable {
    let startedAt: Date
    let files: [FileReceipt]
    let errors: [String]
    let expectedFileCount: Int
    let completed: Bool
    let note = "Проверены чтение сохранённого файла и его размер. SHA-256 рассчитан на Mac; сравнения с контрольной суммой iPhone нет. Полнота Live Photo и облачной медиатеки не подтверждена."

    init(startedAt: Date, files: [FileReceipt], errors: [String], expectedFileCount: Int? = nil, completed: Bool = false) {
        self.startedAt = startedAt; self.files = files; self.errors = errors
        self.expectedFileCount = expectedFileCount ?? files.count; self.completed = completed
    }

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let files = self.files.map { receipt in
            ReportFile(receipt: receipt, relativePath: Self.relativePath(for: URL(fileURLWithPath: receipt.savedPath), from: directory))
        }
        let companions = self.files.flatMap { receipt -> [InventoryFile] in
            guard let primary = Self.relativePath(for: URL(fileURLWithPath: receipt.savedPath), from: directory) else { return [] }
            let folder = (primary as NSString).deletingLastPathComponent
            return receipt.companions.map { companion in
                InventoryFile(path: folder.isEmpty ? companion.filename : "\(folder)/\(companion.filename)", bytes: companion.bytes, sha256: companion.sha256)
            }
        }
        try encoder.encode(Report(startedAt: startedAt, files: files, errors: errors, expectedFileCount: expectedFileCount, completed: completed, note: note, companionFiles: companions))
            .write(to: directory.appendingPathComponent("import-report.json"), options: .atomic)
    }

    private struct Report: Encodable {
        let startedAt: Date; let files: [ReportFile]; let errors: [String]; let expectedFileCount: Int; let completed: Bool; let note: String
        let companionFiles: [InventoryFile]
    }
    private struct ReportFile: Encodable {
        let sourceName: String; let savedPath: String; let relativePath: String?
        let sourceBytes: Int64; let savedBytes: Int64; let sha256: String; let savedAt: Date
        init(receipt: FileReceipt, relativePath: String?) {
            sourceName = receipt.sourceName; savedPath = receipt.savedPath; self.relativePath = relativePath
            sourceBytes = receipt.sourceBytes; savedBytes = receipt.savedBytes; sha256 = receipt.sha256; savedAt = receipt.savedAt
        }
    }
    private struct InventoryFile: Encodable { let path: String; let bytes: Int64; let sha256: String }

    private static func relativePath(for file: URL, from root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path + "/"
        guard file.standardizedFileURL.path.hasPrefix(rootPath) else { return nil }
        return String(file.standardizedFileURL.path.dropFirst(rootPath.count))
    }
}

struct ArchiveVerification: Sendable {
    let verifiedFiles: Int
    let failures: [String]
    var isValid: Bool { failures.isEmpty }

    static func verify(reportAt reportURL: URL) throws -> ArchiveVerification {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DecodedReport.self, from: Data(contentsOf: reportURL))
        let root = reportURL.deletingLastPathComponent().standardizedFileURL
        var failures = report.errors.map { "Импорт: \($0)" }; var verified = 0
        if !report.completed { failures.append("Импорт не завершён.") }
        if report.expectedFileCount <= 0 { failures.append("В отчёте нет ожидаемого числа файлов.") }
        if report.files.count != report.expectedFileCount { failures.append("Ожидалось файлов: \(report.expectedFileCount), записано: \(report.files.count).") }
        for file in report.files {
            do {
                let url: URL
                if let relative = file.relativePath {
                    guard Self.safeRelative(relative) else { throw VerificationFailure.unsafePath }
                    url = root.appendingPathComponent(relative).standardizedFileURL
                    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                    guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw VerificationFailure.unsafePath }
                } else {
                    url = URL(fileURLWithPath: file.savedPath).standardizedFileURL
                    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                    guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw VerificationFailure.unsafePath }
                }
                let actual = try FileReceipt.archiveDigest(url)
                guard actual.bytes == file.savedBytes else { throw ArchiveError.sizeMismatch(expected: file.savedBytes, actual: actual.bytes) }
                guard actual.sha256 == file.sha256 else { throw VerificationFailure.hashMismatch }
                verified += 1
            } catch { failures.append("\(file.sourceName): \(error.localizedDescription)") }
        }
        let primaryFolders = Set(report.files.compactMap { file -> String? in
            guard let relative = file.relativePath, Self.safeRelative(relative) else { return nil }
            return (relative as NSString).deletingLastPathComponent
        })
        for item in report.companionFiles ?? [] {
            do {
                guard Self.safeRelative(item.path) else { throw VerificationFailure.unsafePath }
                let folder = (item.path as NSString).deletingLastPathComponent
                guard primaryFolders.contains(folder) else { throw VerificationFailure.unsafePath }
                let url = root.appendingPathComponent(item.path).standardizedFileURL
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw VerificationFailure.unsafePath }
                let actual = try FileReceipt.archiveDigest(url)
                guard actual.bytes == item.bytes else { throw ArchiveError.sizeMismatch(expected: item.bytes, actual: actual.bytes) }
                guard actual.sha256 == item.sha256 else { throw VerificationFailure.hashMismatch }
            } catch { failures.append("\(item.path): \(error.localizedDescription)") }
        }
        return ArchiveVerification(verifiedFiles: verified, failures: failures)
    }
    private static func safeRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
    private struct DecodedReport: Decodable {
        let files: [DecodedFile]; let errors: [String]; let expectedFileCount: Int; let completed: Bool; let companionFiles: [DecodedInventory]?
        private enum CodingKeys: String, CodingKey { case files, errors, expectedFileCount, completed, companionFiles }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            files = try values.decodeIfPresent([DecodedFile].self, forKey: .files) ?? []
            errors = try values.decodeIfPresent([String].self, forKey: .errors) ?? ["Отчёт не содержит списка ошибок импорта."]
            expectedFileCount = try values.decodeIfPresent(Int.self, forKey: .expectedFileCount) ?? 0
            completed = try values.decodeIfPresent(Bool.self, forKey: .completed) ?? false
            companionFiles = try values.decodeIfPresent([DecodedInventory].self, forKey: .companionFiles)
        }
    }
    private struct DecodedFile: Decodable { let sourceName: String; let savedPath: String; let relativePath: String?; let savedBytes: Int64; let sha256: String }
    private struct DecodedInventory: Decodable { let path: String; let bytes: Int64; let sha256: String }
    private enum VerificationFailure: LocalizedError {
        case unsafePath, hashMismatch
        var errorDescription: String? { switch self { case .unsafePath: return "Отчёт содержит небезопасный путь."; case .hashMismatch: return "Контрольная сумма не совпадает." } }
    }
}

enum ArchiveError: LocalizedError {
    case emptyFile
    case sizeMismatch(expected: Int64, actual: Int64)
    case disconnected
    case missingFilename

    var errorDescription: String? {
        switch self {
        case .emptyFile: return "Получен пустой файл."
        case let .sizeMismatch(expected, actual): return "Размер отличается: ожидалось \(expected) байт, сохранено \(actual)."
        case .disconnected: return "Телефон отключён или доступ к нему закрыт."
        case .missingFilename: return "Устройство не сообщило имя сохранённого файла."
        }
    }
}
