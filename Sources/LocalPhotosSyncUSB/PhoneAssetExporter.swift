import Combine
import CryptoKit
import CoreFoundation
import Darwin
import Foundation

enum PhoneAssetCopyProbeResult: Sendable {
    case copied(folder: URL, bytes: Int64, stableObserved: Bool)
    case failed(status: String)
    case timedOut
    case cancelled
}

enum PhoneLivePhotoProbeResult: Sendable {
    case verified(folder: URL)
    case failed(status: String)
    case timedOut
    case cancelled
}

enum PhoneAssetAvailabilityProbeResult: Equatable, Sendable {
    case mainFileReadable(bytes: Int64)
    case mainFileMissing
    case exceedsCopyLimit(bytes: Int64)
    case failed
    case timedOut
    case cancelled
}

enum PhoneAssetAvailabilityState: Equatable, Sendable {
    case mainFileReadable(bytes: Int64)
    case mainFileMissing
    case exceedsCopyLimit(bytes: Int64)
    case failed
}

struct PhoneAssetAvailabilityCheck: Equatable, Sendable {
    let state: PhoneAssetAvailabilityState
    let sourceFolder: URL
    let checkedAt: Date
}

final class PhoneAssetExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private struct PhoneAssetExportOutcome: Sendable {
    let folder: URL?
    let exported: Int
    let failed: Int
    let savedAssetIDs: Set<Int64>
    let failedAssetIDs: Set<Int64>
    let message: String
}

private struct VerifiedLivePhotoProof {
    let proofFolder: URL
    let imageFolder: URL
    let movieFolder: URL
    let imageFile: URL
    let movieFile: URL
    let imageReceipt: URL
    let movieReceipt: URL
    let context: URL
    let completion: URL
    let imageBytes: Int64
    let movieBytes: Int64
    let imageSHA256: String
    let movieSHA256: String
}

private enum PhoneAssetExportError: Error {
    case invalidSnapshot
    case unsafeFilename
    case invalidReceipt
    case unavailable
    case tooLarge
    case changed
    case copyFailed
    case cancelled
    case timedOut
    case livePhotoUnavailable
    case livePhotoInvalid
}

private enum PhoneProbeProcessResult {
    case completed(Data, Int32)
    case failed(String)
    case timedOut
    case cancelled
}

@MainActor
final class PhoneAssetExporter: ObservableObject {
    typealias ProbeRunner = @Sendable (Int64, URL, TimeInterval, PhoneAssetExportCancellation) -> PhoneAssetCopyProbeResult
    typealias LivePhotoProbeRunner = @Sendable (Int64, URL, TimeInterval, PhoneAssetExportCancellation) -> PhoneLivePhotoProbeResult
    typealias AvailabilityProbeRunner = @Sendable (Int64, URL, TimeInterval, PhoneAssetExportCancellation) -> PhoneAssetAvailabilityProbeResult

    nonisolated static let processGroupLauncherSource = """
    import os,sys,signal
    child=[None]
    args=[sys.executable]+sys.argv[1:]
    def stop(sig,frame):
     if child[0] is not None:
      try: os.killpg(child[0],sig)
      except OSError:
       try: os.kill(child[0],sig)
       except OSError: pass
     raise SystemExit(128+sig)
    signal.signal(signal.SIGTERM,stop)
    pid=os.fork()
    child[0]=pid
    if pid==0:
     signal.signal(signal.SIGTERM,signal.SIG_DFL)
     os.setsid()
     os.write(1,("READY:%d\\n"%os.getpid()).encode())
     os.execv(sys.executable,args)
    _,status=os.waitpid(pid,0)
    os._exit(os.waitstatus_to_exitcode(status))
    """

    @Published private(set) var isExporting = false
    /// True only while files are being copied (not during availability checks).
    @Published private(set) var isTransferring = false
    @Published private(set) var message: String?
    @Published private(set) var outputFolder: URL?
    @Published private(set) var exportedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var savedAssetIDs: Set<Int64> = []
    @Published private(set) var failedAssetIDs: Set<Int64> = []
    @Published private(set) var sourceFolder: URL?
    @Published private(set) var availabilityResults: [Int64: PhoneAssetAvailabilityCheck] = [:]
    @Published private(set) var availabilitySourceFolder: URL?
    @Published private(set) var availabilityMessage: String?

    private let probeRunner: ProbeRunner
    private let livePhotoProbeRunner: LivePhotoProbeRunner
    private let availabilityProbeRunner: AvailabilityProbeRunner
    private var activeCancellation: PhoneAssetExportCancellation?

    init(probeRunner: @escaping ProbeRunner = { assetID, snapshotFolder, timeout, cancellation in
        PhoneAssetExporter.runProbe(assetID, snapshotFolder, timeout, cancellation)
    }, livePhotoProbeRunner: @escaping LivePhotoProbeRunner = { assetID, snapshotFolder, timeout, cancellation in
        PhoneAssetExporter.runLivePhotoProbe(assetID, snapshotFolder, timeout, cancellation)
    }, availabilityProbeRunner: @escaping AvailabilityProbeRunner = { assetID, snapshotFolder, timeout, cancellation in
        PhoneAssetExporter.runAvailabilityProbe(assetID, snapshotFolder, timeout, cancellation)
    }) {
        self.probeRunner = probeRunner
        self.livePhotoProbeRunner = livePhotoProbeRunner
        self.availabilityProbeRunner = availabilityProbeRunner
    }

    func cancel() {
        activeCancellation?.cancel()
    }

    func checkAvailability(assets: [PhoneCatalogAsset], snapshot: PhoneCatalogSnapshot) {
        guard !isExporting else { return }
        let sameSnapshot = availabilitySourceFolder?.resolvingSymlinksInPath().standardizedFileURL ==
            snapshot.sourceFolder.resolvingSymlinksInPath().standardizedFileURL
        if !sameSnapshot { availabilityResults = [:] }
        let selectedIDs = Set(assets.map(\.id))
        availabilityResults = availabilityResults.filter { !selectedIDs.contains($0.key) }
        availabilitySourceFolder = snapshot.sourceFolder
        guard !assets.isEmpty, assets.count <= 12,
              Set(assets.map(\.id)).count == assets.count,
              assets.allSatisfy({ $0.id > 0 && $0.isVisibleLibraryItem &&
                  ($0.mediaType == .photo || $0.mediaType == .video) && Self.safeFilename($0.filename) }) else {
            availabilityMessage = "Выберите от 1 до 12 видимых фото или видео из медиатеки."
            return
        }
        isExporting = true
        availabilityMessage = "Проверяем доступность файлов…"
        let cancellation = PhoneAssetExportCancellation()
        activeCancellation = cancellation
        let runner = availabilityProbeRunner
        Task { [self] in
            let checks = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    Self.performAvailabilityCheck(assets: assets, snapshotFolder: snapshot.sourceFolder,
                                                  runner: runner, cancellation: cancellation)
                }.value
            } onCancel: {
                cancellation.cancel()
            }
            for (assetID, check) in checks { availabilityResults[assetID] = check }
            if cancellation.isCancelled {
                availabilityMessage = "Проверка доступности отменена; непроверенные записи остались без результата."
            } else if checks.values.contains(where: { $0.state == .failed }) {
                availabilityMessage = "Не все файлы удалось проверить; это не означает, что они находятся в iCloud."
            } else if checks.count < assets.count {
                availabilityMessage = "Общий лимит времени проверки истёк; непроверенные записи остались без результата."
            } else {
                availabilityMessage = "Проверка доступности завершена. Она проверяет только чтение заголовка файла."
            }
            activeCancellation = nil
            isExporting = false
        }
    }

    func export(assets: [PhoneCatalogAsset], snapshot: PhoneCatalogSnapshot, destination: URL) {
        guard !isExporting else { return }
        guard !assets.isEmpty, assets.count <= 12,
              Set(assets.map(\.id)).count == assets.count,
              assets.allSatisfy({ $0.id > 0 && $0.isVisibleLibraryItem && ($0.mediaType == .photo || $0.mediaType == .video) && Self.safeFilename($0.filename) }) else {
            outputFolder = nil
            exportedCount = 0
            failedCount = assets.count
            savedAssetIDs = []
            failedAssetIDs = []
            sourceFolder = snapshot.sourceFolder
            failedAssetIDs = Set(assets.map(\.id))
            message = "Выберите до 12 видимых фото или видео из медиатеки."
            return
        }
        isExporting = true
        isTransferring = true
        outputFolder = nil
        exportedCount = 0
        failedCount = 0
        savedAssetIDs = []
        failedAssetIDs = []
        sourceFolder = snapshot.sourceFolder
        message = "Сохраняем доступные файлы: 0 из \(assets.count)…"
        let cancellation = PhoneAssetExportCancellation()
        activeCancellation = cancellation
        let runner = probeRunner
        Task { [self] in
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    Self.performExport(assets: assets, snapshotFolder: snapshot.sourceFolder,
                                       destination: destination, runner: runner, cancellation: cancellation)
                }.value
            } onCancel: {
                cancellation.cancel()
            }
            outputFolder = result.folder
            exportedCount = result.exported
            failedCount = result.failed
            savedAssetIDs = result.savedAssetIDs
            failedAssetIDs = result.failedAssetIDs
            message = result.message
            activeCancellation = nil
            isExporting = false
            isTransferring = false
        }
    }

    func exportLivePhoto(asset: PhoneCatalogAsset, snapshot: PhoneCatalogSnapshot, destination: URL) {
        guard !isExporting else { return }
        sourceFolder = snapshot.sourceFolder
        outputFolder = nil
        exportedCount = 0
        failedCount = 0
        savedAssetIDs = []
        failedAssetIDs = []
        guard asset.id > 0, asset.isVisibleLibraryItem, asset.mediaType == .photo,
              Self.safeFilename(asset.filename) else {
            failedCount = 1
            failedAssetIDs = [asset.id]
            message = "Выберите одно видимое фото из медиатеки."
            return
        }
        isExporting = true
        isTransferring = true
        message = "Проверяем и сохраняем пару Live Photo…"
        let cancellation = PhoneAssetExportCancellation()
        activeCancellation = cancellation
        let runner = livePhotoProbeRunner
        Task { [self] in
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    Self.performLivePhotoExport(asset: asset, snapshotFolder: snapshot.sourceFolder,
                        destination: destination, runner: runner, cancellation: cancellation)
                }.value
            } onCancel: {
                cancellation.cancel()
            }
            outputFolder = result.folder
            exportedCount = result.exported
            failedCount = result.failed
            savedAssetIDs = result.savedAssetIDs
            failedAssetIDs = result.failedAssetIDs
            message = result.message
            activeCancellation = nil
            isExporting = false
            isTransferring = false
        }
    }

    /// Readable, sortable and unique name for a transfer folder, in the same style as USB imports.
    nonisolated static func runFolderName(livePhoto: Bool, at date: Date = Date(), suffix: String = UUID().uuidString) -> String {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        return "LocalPhotosSync-\(livePhoto ? "LivePhoto-" : "")\(stamp)-\(suffix.prefix(8))"
    }

    nonisolated private static func performExport(
        assets: [PhoneCatalogAsset], snapshotFolder: URL, destination: URL,
        runner: @escaping ProbeRunner, cancellation: PhoneAssetExportCancellation
    ) -> PhoneAssetExportOutcome {
        guard let repository = repositoryRoot(for: snapshotFolder),
              isDirectoryWithoutSymlink(destination) else {
            return PhoneAssetExportOutcome(folder: nil, exported: 0, failed: assets.count,
                                           savedAssetIDs: [], failedAssetIDs: Set(assets.map(\.id)),
                                           message: "Не удалось проверить каталог телефона или папку сохранения.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 240
        let runFolder = destination.appendingPathComponent(runFolderName(livePhoto: false), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runFolder.path)
            guard isPrivateDirectory(runFolder) else { throw PhoneAssetExportError.copyFailed }
        } catch {
            return PhoneAssetExportOutcome(folder: nil, exported: 0, failed: assets.count,
                                           savedAssetIDs: [], failedAssetIDs: Set(assets.map(\.id)),
                                           message: "Не удалось создать закрытую папку экспорта.")
        }

        let startedAt = Date()
        let reportURL = runFolder.appendingPathComponent("import-report.json")
        var receipts: [FileReceipt] = []
        var savedIDs: Set<Int64> = []
        var pendingSavedIDs: Set<Int64> = []
        var errors: [String] = []
        var hasUnavailableFiles = false
        do { try writeReport(startedAt: startedAt, files: receipts, errors: errors, expected: assets.count, completed: false, to: runFolder) }
        catch {
            return PhoneAssetExportOutcome(folder: runFolder, exported: 0, failed: assets.count,
                                           savedAssetIDs: [], failedAssetIDs: Set(assets.map(\.id)),
                                           message: "Не удалось создать начальный отчёт; экспорт остановлен.")
        }

        for (offset, asset) in assets.enumerated() {
            let index = offset + 1
            var stopAfterCheckpoint = false
            if cancellation.isCancelled {
                errors.append("Файл \(index): экспорт отменён; оставшиеся файлы не обрабатывались.")
                break
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                errors.append("Файл \(index): достигнут общий лимит времени экспорта.")
                break
            }
            do {
                let itemFolder = runFolder.appendingPathComponent(String(format: "%05d", index), isDirectory: true)
                try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: itemFolder.path)
                let probe = runner(asset.id, snapshotFolder, min(75, remaining), cancellation)
                if cancellation.isCancelled {
                    errors.append("Файл \(index): экспорт отменён; оставшиеся файлы не обрабатывались.")
                    stopAfterCheckpoint = true
                } else { switch probe {
                case .copied(let cacheFolder, let bytes, let stableObserved):
                    guard stableObserved else { throw PhoneAssetExportError.changed }
                    guard bytes > 0, bytes <= 32 * 1024 * 1024 else { throw PhoneAssetExportError.tooLarge }
                    try ensureActive(cancellation, deadline: deadline)
                    let verified = try verifyCacheCopy(cacheFolder, asset: asset, snapshotFolder: snapshotFolder,
                                                       repository: repository, expectedBytes: bytes,
                                                       cancellation: cancellation, deadline: deadline)
                    try copyRegularFile(verified.media, to: itemFolder.appendingPathComponent(asset.filename),
                                        expectedBytes: bytes, cancellation: cancellation, deadline: deadline)
                    try copyRegularFile(verified.receipt, to: itemFolder.appendingPathComponent("phone-asset-receipt.json"),
                                        expectedBytes: verified.receiptBytes, cancellation: cancellation, deadline: deadline)
                    let savedURL = itemFolder.appendingPathComponent(asset.filename)
                    try ensureActive(cancellation, deadline: deadline)
                    let receipt = try FileReceipt.verify(url: savedURL, sourceName: asset.filename, sourceBytes: bytes)
                    try ensureActive(cancellation, deadline: deadline)
                    guard receipt.sha256 == verified.receivedStreamSHA256,
                          let copiedReceipt = receipt.companions.first(where: { $0.filename == "phone-asset-receipt.json" }),
                          copiedReceipt.bytes == verified.receiptBytes,
                          copiedReceipt.sha256 == verified.receiptSHA256 else { throw PhoneAssetExportError.invalidReceipt }
                    receipts.append(receipt)
                    pendingSavedIDs.insert(asset.id)
                case .failed(let status):
                    throw errorForProbeStatus(status)
                case .timedOut:
                    throw PhoneAssetExportError.copyFailed
                case .cancelled:
                    cancellation.cancel()
                    errors.append("Файл \(index): экспорт отменён; оставшиеся файлы не обрабатывались.")
                    stopAfterCheckpoint = true
                }
                }
            } catch {
                if case .unavailable? = error as? PhoneAssetExportError {
                    hasUnavailableFiles = true
                }
                errors.append(errorMessage(error, index: index))
            }
            if cancellation.isCancelled && !stopAfterCheckpoint {
                errors.append("Файл \(index): экспорт отменён; оставшиеся файлы не обрабатывались.")
                stopAfterCheckpoint = true
            }
            do { try writeReport(startedAt: startedAt, files: receipts, errors: errors, expected: assets.count, completed: false, to: runFolder) }
            catch {
                errors.append("Файл \(index): не удалось сохранить промежуточный отчёт.")
                break
            }
            savedIDs.formUnion(pendingSavedIDs)
            pendingSavedIDs.removeAll()
            if stopAfterCheckpoint { break }
        }

        do { try writeReport(startedAt: startedAt, files: receipts, errors: errors, expected: assets.count, completed: false, to: runFolder) }
        catch { errors.append("Не удалось сохранить итоговый промежуточный отчёт.") }
        let allCopied = savedIDs.count == assets.count && errors.isEmpty && !cancellation.isCancelled
        var verificationIsComplete = false
        if allCopied {
            do {
                try ensureActive(cancellation, deadline: deadline)
                try writeReport(startedAt: startedAt, files: receipts, errors: [], expected: assets.count, completed: true, to: runFolder)
                let verification = try ArchiveVerification.verify(reportAt: reportURL)
                if !cancellation.isCancelled && ProcessInfo.processInfo.systemUptime < deadline &&
                    verification.isValid && verification.verifiedFiles == assets.count {
                    verificationIsComplete = true
                } else {
                    errors.append(cancellation.isCancelled ? "Экспорт отменён до завершения проверки архива." :
                                  (ProcessInfo.processInfo.systemUptime >= deadline ? "Достигнут общий лимит времени экспорта." :
                                   "Итоговая проверка архива не прошла."))
                    try? writeReport(startedAt: startedAt, files: receipts, errors: errors, expected: assets.count, completed: false, to: runFolder)
                }
            } catch {
                errors.append("Не удалось завершить проверку архива.")
                try? writeReport(startedAt: startedAt, files: receipts, errors: errors, expected: assets.count, completed: false, to: runFolder)
            }
        }
        let failed = assets.count - savedIDs.count
        var finalMessage = verificationIsComplete
            ? "Экспорт доступных файлов завершён: \(savedIDs.count) из \(assets.count). Полнота оригиналов не подтверждена."
            : (savedIDs.isEmpty
               ? "Не удалось сохранить файлы: 0 из \(assets.count). Ошибок: \(max(failed, errors.count))."
               : "Экспорт доступных файлов сохранён частично: \(savedIDs.count) из \(assets.count). Ошибок: \(max(failed, errors.count)).")
        if !verificationIsComplete {
            finalMessage += "\n" + errors.prefix(3).joined(separator: "\n")
            if hasUnavailableFiles {
                finalMessage += "\nОткройте нужное фото или видео на iPhone, дождитесь загрузки и нажмите «Проверить файлы». Если файл станет доступен, повторите сохранение."
            }
        }
        return PhoneAssetExportOutcome(folder: runFolder, exported: savedIDs.count, failed: failed,
                                       savedAssetIDs: savedIDs, failedAssetIDs: Set(assets.map(\.id)).subtracting(savedIDs),
                                       message: finalMessage)
    }

    nonisolated private static func performLivePhotoExport(
        asset: PhoneCatalogAsset, snapshotFolder: URL, destination: URL,
        runner: @escaping LivePhotoProbeRunner, cancellation: PhoneAssetExportCancellation
    ) -> PhoneAssetExportOutcome {
        guard asset.id > 0, asset.mediaType == .photo, asset.isVisibleLibraryItem,
              safeFilename(asset.filename), let repository = repositoryRoot(for: snapshotFolder),
              isDirectoryWithoutSymlink(destination) else {
            return PhoneAssetExportOutcome(folder: nil, exported: 0, failed: 1,
                savedAssetIDs: [], failedAssetIDs: [asset.id], message: "Выбранная Live Photo недоступна или не поддерживается.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 240
        let runFolder = destination.appendingPathComponent(runFolderName(livePhoto: true), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runFolder.path)
            guard isPrivateDirectory(runFolder) else { throw PhoneAssetExportError.copyFailed }
        } catch {
            return PhoneAssetExportOutcome(folder: nil, exported: 0, failed: 1,
                savedAssetIDs: [], failedAssetIDs: [asset.id], message: "Не удалось создать закрытую папку экспорта.")
        }
        let startedAt = Date()
        let reportURL = runFolder.appendingPathComponent("import-report.json")
        var files: [FileReceipt] = []
        var errors: [String] = []
        do { try writeReport(startedAt: startedAt, files: files, errors: errors, expected: 1, completed: false, to: runFolder) }
        catch {
            return PhoneAssetExportOutcome(folder: runFolder, exported: 0, failed: 1,
                savedAssetIDs: [], failedAssetIDs: [asset.id], message: "Не удалось создать незавершённый отчёт.")
        }

        do {
            try ensureActive(cancellation, deadline: deadline)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw PhoneAssetExportError.timedOut }
            let probe = runner(asset.id, snapshotFolder, min(210, remaining), cancellation)
            try ensureActive(cancellation, deadline: deadline)
            let proofFolder: URL
            switch probe {
            case .verified(let folder): proofFolder = folder
            case .failed(let status):
                if status == "live_photo_candidate_unavailable" || status == "asset_unavailable" ||
                    status == "source_binding_mismatch" || status == "source_binding_unavailable" {
                    throw PhoneAssetExportError.livePhotoUnavailable
                }
                throw PhoneAssetExportError.livePhotoInvalid
            case .timedOut: throw PhoneAssetExportError.timedOut
            case .cancelled: throw PhoneAssetExportError.cancelled
            }
            try ensureActive(cancellation, deadline: deadline)
            let proof = try validateLivePhotoProof(proofFolder, asset: asset, snapshotFolder: snapshotFolder,
                                                   repository: repository, cancellation: cancellation, deadline: deadline)
            try ensureActive(cancellation, deadline: deadline)

            let itemFolder = runFolder.appendingPathComponent("00001", isDirectory: true)
            try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: itemFolder.path)
            let stem = URL(fileURLWithPath: asset.filename).deletingPathExtension().lastPathComponent
            let movieName = stem + ".MOV"
            guard safeFilename(movieName) else { throw PhoneAssetExportError.unsafeFilename }
            try copyRegularFile(proof.imageFile, to: itemFolder.appendingPathComponent(asset.filename),
                                expectedBytes: proof.imageBytes, cancellation: cancellation, deadline: deadline)
            try copyRegularFile(proof.movieFile, to: itemFolder.appendingPathComponent(movieName),
                                expectedBytes: proof.movieBytes, cancellation: cancellation, deadline: deadline)
            try copyRegularFile(proof.completion, to: itemFolder.appendingPathComponent("phone-live-photo-complete.json"),
                                expectedBytes: fileSize(proof.completion) ?? 0, cancellation: cancellation, deadline: deadline)
            try copyRegularFile(proof.context, to: itemFolder.appendingPathComponent("phone-live-photo-context.json"),
                                expectedBytes: fileSize(proof.context) ?? 0, cancellation: cancellation, deadline: deadline)
            try copyRegularFile(proof.imageReceipt, to: itemFolder.appendingPathComponent("phone-live-photo-image-receipt.json"),
                                expectedBytes: fileSize(proof.imageReceipt) ?? 0, cancellation: cancellation, deadline: deadline)
            try copyRegularFile(proof.movieReceipt, to: itemFolder.appendingPathComponent("phone-live-photo-movie-receipt.json"),
                                expectedBytes: fileSize(proof.movieReceipt) ?? 0, cancellation: cancellation, deadline: deadline)

            try ensureActive(cancellation, deadline: deadline)
            let primary = try FileReceipt.verify(url: itemFolder.appendingPathComponent(asset.filename),
                                                 sourceName: asset.filename, sourceBytes: proof.imageBytes)
            let expectedCompanions: Set<String> = [movieName, "phone-live-photo-complete.json",
                "phone-live-photo-context.json", "phone-live-photo-image-receipt.json", "phone-live-photo-movie-receipt.json"]
            guard primary.sha256 == proof.imageSHA256,
                  Set(primary.companions.map(\.filename)) == expectedCompanions,
                  let movieReceipt = primary.companions.first(where: { $0.filename == movieName }),
                  movieReceipt.bytes == proof.movieBytes, movieReceipt.sha256 == proof.movieSHA256 else {
                throw PhoneAssetExportError.invalidReceipt
            }
            files = [primary]
            try writeReport(startedAt: startedAt, files: files, errors: [], expected: 1, completed: false, to: runFolder)
            try ensureActive(cancellation, deadline: deadline)
            try writeReport(startedAt: startedAt, files: files, errors: [], expected: 1, completed: true, to: runFolder)
            let verification = try ArchiveVerification.verify(reportAt: reportURL)
            try ensureActive(cancellation, deadline: deadline)
            guard verification.isValid, verification.verifiedFiles == 1 else {
                throw PhoneAssetExportError.invalidReceipt
            }
            return PhoneAssetExportOutcome(folder: runFolder, exported: 1, failed: 0,
                savedAssetIDs: [asset.id], failedAssetIDs: [],
                message: "Пара Live Photo сохранена и проверена локально. Полнота облачной медиатеки не подтверждена.")
        } catch {
            errors.append(errorMessage(error, index: 1))
            try? writeReport(startedAt: startedAt, files: files, errors: errors, expected: 1, completed: false, to: runFolder)
            return PhoneAssetExportOutcome(folder: runFolder, exported: 0, failed: 1,
                savedAssetIDs: [], failedAssetIDs: [asset.id], message: errorMessage(error, index: 1))
        }
    }

    nonisolated private static func validateLivePhotoProof(
        _ folder: URL, asset: PhoneCatalogAsset, snapshotFolder: URL, repository: URL,
        cancellation: PhoneAssetExportCancellation, deadline: TimeInterval
    ) throws -> VerifiedLivePhotoProof {
        let proofRoot = repository.appendingPathComponent(".build/phone-live-photo-proof", isDirectory: true)
        let cacheRoot = repository.appendingPathComponent(".build/phone-asset-copy-probe", isDirectory: true)
        guard isContained(folder, in: proofRoot), isPrivateDirectory(folder) else { throw PhoneAssetExportError.invalidReceipt }
        let suffix = URL(fileURLWithPath: asset.filename).pathExtension
        guard !suffix.isEmpty, suffix.utf8.count <= 8,
              suffix.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }) else {
            throw PhoneAssetExportError.unsafeFilename
        }
        let imageFile = folder.appendingPathComponent("still." + suffix)
        let movieFile = folder.appendingPathComponent("motion.MOV")
        let contextURL = folder.appendingPathComponent("pair-context.json")
        let completionURL = folder.appendingPathComponent("complete.json")
        let verifierInputsURL = folder.appendingPathComponent("verifier-inputs.json")
        guard Set((try FileManager.default.contentsOfDirectory(atPath: folder.path))) ==
            Set(["pair-context.json", "complete.json", "verifier-inputs.json", "still." + suffix, "motion.MOV"]) else {
            throw PhoneAssetExportError.invalidReceipt
        }
        let contextData = try readPrivateData(contextURL, limit: 8192)
        guard let context = try JSONSerialization.jsonObject(with: contextData) as? [String: Any],
              Set(context.keys) == Set(["sourceSnapshot", "assetID", "imageName", "movieName", "imageResourceBytes", "movieResourceBytes"]),
              context["sourceSnapshot"] as? String == snapshotFolder.resolvingSymlinksInPath().path,
              integer(context["assetID"]) == asset.id, context["imageName"] as? String == asset.filename,
              context["movieName"] as? String == URL(fileURLWithPath: asset.filename).deletingPathExtension().lastPathComponent + ".MOV",
              let imageBytes = integer(context["imageResourceBytes"]), imageBytes > 0, imageBytes <= 32 * 1024 * 1024,
              let movieBytes = integer(context["movieResourceBytes"]), movieBytes > 0, movieBytes <= 32 * 1024 * 1024,
              imageBytes + movieBytes <= 64 * 1024 * 1024 else { throw PhoneAssetExportError.invalidReceipt }
        let completionData = try readPrivateData(completionURL, limit: 2048)
        guard let completion = try JSONSerialization.jsonObject(with: completionData) as? [String: Any],
              Set(completion.keys) == Set(["source", "status", "imageBytes", "movieBytes", "verified"]),
              completion["source"] as? String == "iphone_afc", completion["status"] as? String == "live_photo_pair_verified",
              completion["verified"] as? Bool == true, integer(completion["imageBytes"]) == imageBytes,
              integer(completion["movieBytes"]) == movieBytes else { throw PhoneAssetExportError.invalidReceipt }
        let verifierData = try readPrivateData(verifierInputsURL, limit: 8192)
        guard let inputs = try JSONSerialization.jsonObject(with: verifierData) as? [String: Any],
              Set(inputs.keys) == Set(["imageFile", "movieFile", "imageFolder", "movieFolder", "proofFolder"]),
              inputs["imageFile"] as? String == imageFile.path, inputs["movieFile"] as? String == movieFile.path,
              inputs["proofFolder"] as? String == folder.path,
              let imageFolderPath = inputs["imageFolder"] as? String,
              let movieFolderPath = inputs["movieFolder"] as? String else { throw PhoneAssetExportError.invalidReceipt }
        let imageFolder = URL(fileURLWithPath: imageFolderPath, isDirectory: true)
        let movieFolder = URL(fileURLWithPath: movieFolderPath, isDirectory: true)
        guard imageFolder.standardizedFileURL != movieFolder.standardizedFileURL,
              isContained(imageFolder, in: cacheRoot), isContained(movieFolder, in: cacheRoot),
              isPrivateDirectory(imageFolder), isPrivateDirectory(movieFolder) else { throw PhoneAssetExportError.invalidReceipt }
        try ensureActive(cancellation, deadline: deadline)
        let imageReceipt = try validateLivePhotoCopy(imageFolder, expectedBytes: imageBytes,
                                                     cancellation: cancellation, deadline: deadline)
        let movieReceipt = try validateLivePhotoCopy(movieFolder, expectedBytes: movieBytes,
                                                     cancellation: cancellation, deadline: deadline)
        guard isRegularPrivateFile(imageFile), isRegularPrivateFile(movieFile),
              fileSize(imageFile) == imageBytes, fileSize(movieFile) == movieBytes else {
            throw PhoneAssetExportError.invalidReceipt
        }
        let imageDigest = try hashPrivateFile(imageFile, limit: 32 * 1024 * 1024,
                                               cancellation: cancellation, deadline: deadline)
        let movieDigest = try hashPrivateFile(movieFile, limit: 32 * 1024 * 1024,
                                               cancellation: cancellation, deadline: deadline)
        guard imageDigest.bytes == imageBytes, imageDigest.sha256 == imageReceipt.hash,
              movieDigest.bytes == movieBytes, movieDigest.sha256 == movieReceipt.hash else {
            throw PhoneAssetExportError.invalidReceipt
        }
        return VerifiedLivePhotoProof(proofFolder: folder, imageFolder: imageFolder, movieFolder: movieFolder,
            imageFile: imageFile, movieFile: movieFile, imageReceipt: imageReceipt.url,
            movieReceipt: movieReceipt.url, context: contextURL, completion: completionURL,
            imageBytes: imageBytes, movieBytes: movieBytes, imageSHA256: imageDigest.sha256,
            movieSHA256: movieDigest.sha256)
    }

    nonisolated private static func validateLivePhotoCopy(
        _ folder: URL, expectedBytes: Int64, cancellation: PhoneAssetExportCancellation, deadline: TimeInterval
    ) throws -> (url: URL, hash: String) {
        guard Set((try FileManager.default.contentsOfDirectory(atPath: folder.path))) == Set(["media.bin", "copy-receipt.json"]) else {
            throw PhoneAssetExportError.invalidReceipt
        }
        let receiptURL = folder.appendingPathComponent("copy-receipt.json")
        let data = try readPrivateData(receiptURL, limit: 2048)
        guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(receipt.keys) == Set(["source", "status", "declaredBytes", "copiedBytes", "stableObserved", "receivedStreamSHA256"]),
              receipt["source"] as? String == "iphone_afc", receipt["status"] as? String == "asset_copy_complete",
              receipt["stableObserved"] as? Bool == true,
              integer(receipt["declaredBytes"]) == expectedBytes, integer(receipt["copiedBytes"]) == expectedBytes,
              let hash = receipt["receivedStreamSHA256"] as? String,
              hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw PhoneAssetExportError.invalidReceipt
        }
        let media = folder.appendingPathComponent("media.bin")
        guard isRegularPrivateFile(media), fileSize(media) == expectedBytes else { throw PhoneAssetExportError.invalidReceipt }
        let digest = try hashPrivateFile(media, limit: 32 * 1024 * 1024,
                                         cancellation: cancellation, deadline: deadline)
        guard digest.bytes == expectedBytes, digest.sha256 == hash else { throw PhoneAssetExportError.invalidReceipt }
        return (receiptURL, hash)
    }

    nonisolated private static func verifyCacheCopy(
        _ folder: URL, asset: PhoneCatalogAsset, snapshotFolder: URL, repository: URL, expectedBytes: Int64,
        cancellation: PhoneAssetExportCancellation, deadline: TimeInterval
    ) throws -> (media: URL, receipt: URL, receiptBytes: Int64, receiptSHA256: String, receivedStreamSHA256: String) {
        let cacheRoot = repository.appendingPathComponent(".build/phone-asset-copy-probe", isDirectory: true)
        guard isContained(folder, in: cacheRoot), isPrivateDirectory(folder) else { throw PhoneAssetExportError.invalidReceipt }
        let media = folder.appendingPathComponent("media.bin")
        let cReceipt = folder.appendingPathComponent("copy-receipt.json")
        let receipt = folder.appendingPathComponent("asset-copy-receipt.json")
        guard isRegularPrivateFile(media), isRegularPrivateFile(cReceipt), isRegularPrivateFile(receipt),
              fileSize(media) == expectedBytes, expectedBytes > 0, expectedBytes <= 32 * 1024 * 1024 else {
            throw PhoneAssetExportError.invalidReceipt
        }
        try ensureActive(cancellation, deadline: deadline)
        let receiptData = try readPrivateData(receipt, limit: 64 * 1024)
        guard receiptData.count <= 64 * 1024,
              let value = try JSONSerialization.jsonObject(with: receiptData) as? [String: Any],
              Set(value.keys) == Set([
                "source", "status", "sourceSnapshot", "assetID", "filename", "ZKIND",
                "ZORIGINALFILESIZE", "ZORIGINALRESOURCECHOICE", "linkedResources", "declaredBytes",
                "copiedBytes", "stableObserved", "receivedStreamSHA256",
              ]),
              value["source"] as? String == "iphone_afc", value["status"] as? String == "asset_copy_complete",
              value["sourceSnapshot"] as? String == snapshotFolder.resolvingSymlinksInPath().path,
              integer(value["assetID"]) == asset.id, value["filename"] as? String == asset.filename,
              integer(value["ZKIND"]) == (asset.mediaType == .photo ? 0 : 1),
              isNullableInteger(value["ZORIGINALFILESIZE"]), isNullableInteger(value["ZORIGINALRESOURCECHOICE"]),
              validLinkedResources(value["linkedResources"]),
              integer(value["declaredBytes"]) == expectedBytes, integer(value["copiedBytes"]) == expectedBytes,
              value["stableObserved"] as? Bool == true,
              let streamHash = value["receivedStreamSHA256"] as? String,
              streamHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw PhoneAssetExportError.invalidReceipt
        }
        let copyData = try readPrivateData(cReceipt, limit: 1024)
        guard copyData.count <= 1024,
              let copyValue = try JSONSerialization.jsonObject(with: copyData) as? [String: Any],
              Set(copyValue.keys) == Set(["source", "status", "declaredBytes", "copiedBytes", "stableObserved", "receivedStreamSHA256"]),
              copyValue["source"] as? String == "iphone_afc", copyValue["status"] as? String == "asset_copy_complete",
              integer(copyValue["declaredBytes"]) == expectedBytes, integer(copyValue["copiedBytes"]) == expectedBytes,
              copyValue["stableObserved"] as? Bool == true, copyValue["receivedStreamSHA256"] as? String == streamHash else {
            throw PhoneAssetExportError.invalidReceipt
        }
        let diskDigest = try hashPrivateFile(media, limit: 32 * 1024 * 1024,
                                             cancellation: cancellation, deadline: deadline)
        guard diskDigest.bytes == expectedBytes, diskDigest.sha256 == streamHash else { throw PhoneAssetExportError.invalidReceipt }
        let receiptHash = SHA256.hash(data: receiptData).map { String(format: "%02x", $0) }.joined()
        return (media, receipt, Int64(receiptData.count), receiptHash, streamHash)
    }

    nonisolated private static func readPrivateData(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PhoneAssetExportError.invalidReceipt }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o777) == 0o600, info.st_size >= 0, info.st_size <= limit else {
            throw PhoneAssetExportError.invalidReceipt
        }
        var data = Data(capacity: Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(16 * 1024, max(1, limit)))
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in Darwin.read(descriptor, raw.baseAddress, raw.count) }
            if count < 0 { throw PhoneAssetExportError.invalidReceipt }
            if count == 0 { break }
            guard data.count + count <= limit else { throw PhoneAssetExportError.invalidReceipt }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == info.st_size else { throw PhoneAssetExportError.invalidReceipt }
        return data
    }

    nonisolated private static func hashPrivateFile(_ url: URL, limit: Int64,
                                                     cancellation: PhoneAssetExportCancellation,
                                                     deadline: TimeInterval) throws -> (bytes: Int64, sha256: String) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PhoneAssetExportError.invalidReceipt }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o777) == 0o600, info.st_size > 0, info.st_size <= limit else {
            throw PhoneAssetExportError.invalidReceipt
        }
        var hash = SHA256()
        var count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try ensureActive(cancellation, deadline: deadline)
            let readCount = buffer.withUnsafeMutableBytes { raw in Darwin.read(descriptor, raw.baseAddress, raw.count) }
            if readCount < 0 { throw PhoneAssetExportError.invalidReceipt }
            if readCount == 0 { break }
            count += Int64(readCount)
            guard count <= limit else { throw PhoneAssetExportError.invalidReceipt }
            hash.update(data: Data(buffer.prefix(readCount)))
        }
        guard count == Int64(info.st_size) else { throw PhoneAssetExportError.invalidReceipt }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    nonisolated private static func isNullableInteger(_ value: Any?) -> Bool {
        if value == nil || value is NSNull { return true }
        return integer(value) != nil
    }

    nonisolated private static func validLinkedResources(_ value: Any?) -> Bool {
        if value == nil || value is NSNull { return true }
        guard let rows = value as? [[String: Any]] else { return false }
        let keys: Set<String> = ["ZRESOURCETYPE", "ZDATASTORECLASSID", "ZDATASTORESUBTYPE", "ZVERSION", "ZRECIPEID", "ZDATALENGTH", "ZLOCALAVAILABILITY"]
        return rows.count <= 64 && rows.allSatisfy { row in
            Set(row.keys) == keys && row.values.allSatisfy { isNullableInteger($0) }
        }
    }

    nonisolated static func performAvailabilityCheck(
        assets: [PhoneCatalogAsset], snapshotFolder: URL,
        runner: @escaping AvailabilityProbeRunner, cancellation: PhoneAssetExportCancellation
    ) -> [Int64: PhoneAssetAvailabilityCheck] {
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        var checks: [Int64: PhoneAssetAvailabilityCheck] = [:]
        for asset in assets {
            if cancellation.isCancelled { break }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            let result = runner(asset.id, snapshotFolder, min(30, remaining), cancellation)
            if cancellation.isCancelled { break }
            if case .cancelled = result { break }
            let state: PhoneAssetAvailabilityState
            switch result {
            case .mainFileReadable(let bytes): state = .mainFileReadable(bytes: bytes)
            case .mainFileMissing: state = .mainFileMissing
            case .exceedsCopyLimit(let bytes): state = .exceedsCopyLimit(bytes: bytes)
            case .failed, .timedOut: state = .failed
            case .cancelled: continue
            }
            checks[asset.id] = PhoneAssetAvailabilityCheck(state: state, sourceFolder: snapshotFolder, checkedAt: Date())
        }
        return checks
    }

    nonisolated static func runAvailabilityProbe(
        _ assetID: Int64, _ snapshotFolder: URL, _ timeout: TimeInterval,
        _ cancellation: PhoneAssetExportCancellation, scriptURL overrideScriptURL: URL? = nil
    ) -> PhoneAssetAvailabilityProbeResult {
        guard !cancellation.isCancelled, assetID > 0, timeout.isFinite, timeout > 0, timeout <= 30,
              let repository = repositoryRoot(for: snapshotFolder) else { return .failed }
        let script = overrideScriptURL ?? repository.appendingPathComponent("experiments/afc/run-asset-header-probe.py")
        let execution = runPythonProbe(script, arguments: ["--snapshot", snapshotFolder.path, "--asset-id", String(assetID)],
                                       repository: repository, timeout: timeout, cancellation: cancellation)
        let data: Data
        let exitCode: Int32
        switch execution {
        case .completed(let output, let code): data = output; exitCode = code
        case .failed: return .failed
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        }
        let keys: Set<String> = ["source", "status", "found", "declaredBytes", "bytesRead", "format"]
        guard data.count <= 16 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == keys, value["source"] as? String == "iphone_afc",
              let status = value["status"] as? String,
              status.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil,
              let found = strictAvailabilityInteger(value["found"]),
              let declared = strictAvailabilityInteger(value["declaredBytes"]),
              let bytesRead = strictAvailabilityInteger(value["bytesRead"]),
              let format = value["format"] as? String, ["jpeg", "png", "isobmff", "unknown"].contains(format),
              found == 0 || found == 1, declared >= 0, bytesRead >= 0, bytesRead <= 16 else { return .failed }

        if status == "asset_unavailable", exitCode == 1, found == 0, declared == 0,
           bytesRead == 0, format == "unknown" { return .mainFileMissing }
        guard status == "asset_header_read", exitCode == 0, found == 1,
              declared > 0, declared <= 1024 * 1024 * 1024,
              bytesRead == min(16, declared) else { return .failed }
        if declared > 32 * 1024 * 1024 { return .exceedsCopyLimit(bytes: declared) }
        return .mainFileReadable(bytes: declared)
    }

    nonisolated static func runProbe(_ assetID: Int64, _ snapshotFolder: URL, _ timeout: TimeInterval,
                                     _ cancellation: PhoneAssetExportCancellation,
                                     scriptURL overrideScriptURL: URL? = nil) -> PhoneAssetCopyProbeResult {
        guard !cancellation.isCancelled, assetID > 0, timeout.isFinite, timeout > 0, timeout <= 75,
              let repository = repositoryRoot(for: snapshotFolder) else { return .failed(status: "invalid_arguments") }
        let script = overrideScriptURL ?? repository.appendingPathComponent("experiments/afc/run-asset-copy-probe.py")
        let execution = runPythonProbe(script, arguments: ["--snapshot", snapshotFolder.path, "--asset-id", String(assetID)],
                                       repository: repository, timeout: timeout, cancellation: cancellation)
        let data: Data
        let exitCode: Int32
        switch execution {
        case .completed(let output, let code): data = output; exitCode = code
        case .failed(let status): return .failed(status: status)
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        }
        guard data.count <= 16 * 1024,
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(result.keys) == Set(["source", "status", "copiedBytes", "stableObserved", "localFolder"]),
              result["source"] as? String == "iphone_afc",
              let status = result["status"] as? String else { return .failed(status: "invalid_output") }
        if status != "asset_copy_complete" { return .failed(status: status) }
        guard exitCode == 0,
              let bytes = integer(result["copiedBytes"]), bytes > 0, bytes <= 32 * 1024 * 1024,
              let folderPath = result["localFolder"] as? String else { return .failed(status: "copy_unverified") }
        guard result["stableObserved"] as? Bool == true else { return .failed(status: "asset_changed") }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let cacheRoot = repository.appendingPathComponent(".build/phone-asset-copy-probe", isDirectory: true)
        guard isContained(folder, in: cacheRoot) else { return .failed(status: "copy_path_invalid") }
        return .copied(folder: folder, bytes: bytes, stableObserved: true)
    }

    nonisolated private static func runLivePhotoProbe(_ assetID: Int64, _ snapshotFolder: URL, _ timeout: TimeInterval,
                                                       _ cancellation: PhoneAssetExportCancellation) -> PhoneLivePhotoProbeResult {
        guard !cancellation.isCancelled, assetID > 0, timeout.isFinite, timeout > 0, timeout <= 210,
              let repository = repositoryRoot(for: snapshotFolder) else { return .failed(status: "invalid_arguments") }
        let script = repository.appendingPathComponent("experiments/afc/run-live-photo-copy-probe.py")
        let execution = runPythonProbe(script, arguments: ["--snapshot", snapshotFolder.path, "--asset-id", String(assetID)],
                                       repository: repository, timeout: timeout, cancellation: cancellation)
        let data: Data
        let exitCode: Int32
        switch execution {
        case .completed(let output, let code): data = output; exitCode = code
        case .failed(let status): return .failed(status: status)
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        }
        let keys: Set<String> = ["source", "status", "copiedImages", "copiedMovies", "copiedBytes", "verified", "localFolder"]
        guard data.count <= 16 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == keys, value["source"] as? String == "iphone_afc",
              let status = value["status"] as? String else { return .failed(status: "invalid_output") }
        guard status.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil else {
            return .failed(status: "invalid_output")
        }
        guard status == "live_photo_pair_verified", exitCode == 0, value["verified"] as? Bool == true,
              integer(value["copiedImages"]) == 1, integer(value["copiedMovies"]) == 1,
              let total = integer(value["copiedBytes"]), total > 0, total <= 64 * 1024 * 1024,
              let folderPath = value["localFolder"] as? String else {
            return .failed(status: status == "live_photo_pair_verified" ? "live_photo_verification_failed" : status)
        }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let proofRoot = repository.appendingPathComponent(".build/phone-live-photo-proof", isDirectory: true)
        guard isContained(folder, in: proofRoot), isPrivateDirectory(folder) else {
            return .failed(status: "live_photo_path_invalid")
        }
        return .verified(folder: folder)
    }

    nonisolated private static func runPythonProbe(_ script: URL, arguments: [String], repository: URL,
                                                    timeout: TimeInterval,
                                                    cancellation: PhoneAssetExportCancellation) -> PhoneProbeProcessResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", processGroupLauncherSource, script.path] + arguments
        process.currentDirectoryURL = repository
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "USBMUXD_SOCKET_ADDRESS")
        process.environment = environment
        do { try process.run() } catch { return .failed("process_error") }
        let outputFD = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(outputFD, F_GETFL)
        guard flags >= 0, fcntl(outputFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
            terminateLauncher(process, groupPID: nil)
            return .failed("process_error")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var groupPID: pid_t?
        var readiness = Data()
        var reachedEOF = false
        var stdout = Data()
        while process.isRunning || !reachedEOF {
            if cancellation.isCancelled {
                terminateLauncher(process, groupPID: groupPID)
                return .cancelled
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                terminateLauncher(process, groupPID: groupPID)
                return .timedOut
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !reachedEOF {
                let count = Darwin.read(outputFD, &buffer, buffer.count)
                if count > 0 {
                    let bytes = Data(buffer.prefix(count))
                    if groupPID == nil {
                        readiness.append(bytes)
                        if let newline = readiness.firstIndex(of: 10) {
                            let line = String(decoding: readiness[..<newline], as: UTF8.self)
                            guard line.hasPrefix("READY:"), let value = Int32(line.dropFirst(6)), value > 0 else {
                                terminateLauncher(process, groupPID: nil)
                                return .failed("process_error")
                            }
                            groupPID = pid_t(value)
                            stdout.append(readiness[(newline + 1)...])
                            readiness.removeAll()
                        } else if readiness.count > 64 {
                            terminateLauncher(process, groupPID: nil)
                            return .failed("process_error")
                        }
                    } else {
                        stdout.append(bytes)
                    }
                    guard stdout.count <= 16 * 1024 else {
                        terminateLauncher(process, groupPID: groupPID)
                        return .failed("invalid_output")
                    }
                    continue
                }
                if count == 0 { reachedEOF = true; break }
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    terminateLauncher(process, groupPID: groupPID)
                    return .failed("process_error")
                }
                break
            }
            if groupPID == nil && !process.isRunning { return .failed("process_error") }
            if process.isRunning || !reachedEOF { Thread.sleep(forTimeInterval: 0.025) }
        }
        return .completed(stdout, process.terminationStatus)
    }

    nonisolated private static func terminateLauncher(_ process: Process, groupPID: pid_t?) {
        let pid = process.processIdentifier
        if let groupPID { _ = kill(-groupPID, SIGTERM) }
        _ = kill(pid, SIGTERM)
        Thread.sleep(forTimeInterval: 0.25)
        if let groupPID { _ = kill(-groupPID, SIGKILL) }
        _ = kill(pid, SIGKILL)
        if process.isRunning { process.waitUntilExit() }
    }

    nonisolated private static func copyRegularFile(_ source: URL, to destination: URL, expectedBytes: Int64,
                                                     cancellation: PhoneAssetExportCancellation,
                                                     deadline: TimeInterval) throws {
        let sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw PhoneAssetExportError.copyFailed }
        var sourceOpen = true
        defer { if sourceOpen { close(sourceFD) } }
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFREG,
              (sourceInfo.st_mode & 0o777) == 0o600,
              Int64(sourceInfo.st_size) == expectedBytes, expectedBytes > 0, expectedBytes <= 32 * 1024 * 1024 else {
            throw PhoneAssetExportError.invalidReceipt
        }
        let destinationFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard destinationFD >= 0 else { throw PhoneAssetExportError.copyFailed }
        var destinationOpen = true
        defer { if destinationOpen { close(destinationFD) } }
        guard fchmod(destinationFD, mode_t(0o600)) == 0 else { throw PhoneAssetExportError.copyFailed }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var copied: Int64 = 0
        while true {
            try ensureActive(cancellation, deadline: deadline)
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(sourceFD, raw.baseAddress, raw.count)
            }
            if count < 0 { throw PhoneAssetExportError.copyFailed }
            if count == 0 { break }
            copied += Int64(count)
            guard copied <= expectedBytes else { throw PhoneAssetExportError.changed }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { raw in
                    Darwin.write(destinationFD, raw.baseAddress!.advanced(by: offset), count - offset)
                }
                guard written > 0 else { throw PhoneAssetExportError.copyFailed }
                offset += written
            }
        }
        guard copied == expectedBytes, fsync(destinationFD) == 0 else { throw PhoneAssetExportError.copyFailed }
        var finalInfo = stat()
        guard fstat(destinationFD, &finalInfo) == 0, (finalInfo.st_mode & S_IFMT) == S_IFREG,
              Int64(finalInfo.st_size) == expectedBytes else { throw PhoneAssetExportError.copyFailed }
        guard close(destinationFD) == 0 else { destinationOpen = false; throw PhoneAssetExportError.copyFailed }
        destinationOpen = false
        guard close(sourceFD) == 0 else { sourceOpen = false; throw PhoneAssetExportError.copyFailed }
        sourceOpen = false
    }

    nonisolated private static func writeReport(startedAt: Date, files: [FileReceipt], errors: [String], expected: Int,
                                    completed: Bool, to folder: URL) throws {
        try ImportReport(startedAt: startedAt, files: files, errors: errors,
                         expectedFileCount: expected, completed: completed).write(to: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: folder.appendingPathComponent("import-report.json").path)
    }

    nonisolated private static func errorForProbeStatus(_ status: String) -> PhoneAssetExportError {
        switch status {
        case "asset_unavailable": return .unavailable
        case "asset_size_out_of_bounds": return .tooLarge
        case "asset_changed", "asset_stat_after_failed": return .changed
        default: return .copyFailed
        }
    }

    nonisolated private static func errorMessage(_ error: Error, index: Int) -> String {
        let reason: String
        switch error as? PhoneAssetExportError {
        case .cancelled: reason = "экспорт отменён"
        case .timedOut: reason = "достигнут общий лимит времени экспорта"
        case .livePhotoUnavailable: reason = "выбранная Live Photo недоступна или не поддерживается"
        case .livePhotoInvalid: reason = "не удалось проверить пару Live Photo"
        case .unavailable: reason = "файл недоступен на телефоне"
        case .tooLarge: reason = "файл превышает лимит размера"
        case .changed: reason = "файл изменился во время чтения"
        case .unsafeFilename: reason = "имя файла нельзя безопасно сохранить"
        case .invalidReceipt: reason = "проверка скопированного файла не пройдена"
        case .invalidSnapshot: reason = "источник каталога не прошёл проверку"
        default: reason = "не удалось скопировать и проверить файл"
        }
        return "Файл \(index): \(reason)."
    }

    nonisolated private static func ensureActive(_ cancellation: PhoneAssetExportCancellation,
                                                  deadline: TimeInterval) throws {
        if cancellation.isCancelled { throw PhoneAssetExportError.cancelled }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw PhoneAssetExportError.timedOut }
    }

    nonisolated private static func repositoryRoot(for snapshotFolder: URL) -> URL? {
        let folder = snapshotFolder.standardizedFileURL
        guard folder.deletingLastPathComponent().lastPathComponent == "phone-catalog-probe" else { return nil }
        let build = folder.deletingLastPathComponent().deletingLastPathComponent()
        guard build.lastPathComponent == ".build" else { return nil }
        return build.deletingLastPathComponent()
    }

    nonisolated private static func isContained(_ url: URL, in root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(resolvedRoot) && resolved != root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    nonisolated private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    nonisolated private static func isPrivateDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && (info.st_mode & 0o777) == 0o700
    }

    nonisolated private static func isRegularPrivateFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && (info.st_mode & 0o777) == 0o600
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(info.st_size)
    }

    nonisolated private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.int64Value
    }

    nonisolated private static func strictAvailabilityInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let parsed = Int64(number.stringValue), String(parsed) == number.stringValue else { return nil }
        return parsed
    }

    nonisolated private static func safeFilename(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\\"),
              value.utf8.count <= 255 else { return false }
        return !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
