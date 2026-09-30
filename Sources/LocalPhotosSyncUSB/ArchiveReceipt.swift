import CryptoKit
import Foundation

struct FileReceipt: Codable, Sendable {
    let sourceName: String
    let savedPath: String
    let sourceBytes: Int64
    let savedBytes: Int64
    let sha256: String
    let savedAt: Date

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
        return FileReceipt(
            sourceName: sourceName,
            savedPath: url.path,
            sourceBytes: sourceBytes,
            savedBytes: count,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
            savedAt: Date()
        )
    }
}

struct ImportReport: Encodable, Sendable {
    let startedAt: Date
    let files: [FileReceipt]
    let errors: [String]
    let note = "Проверены чтение сохранённого файла и его размер. SHA-256 рассчитан на Mac; сравнения с контрольной суммой iPhone нет. Полнота Live Photo и облачной медиатеки не подтверждена."

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: directory.appendingPathComponent("import-report.json"), options: .atomic)
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
