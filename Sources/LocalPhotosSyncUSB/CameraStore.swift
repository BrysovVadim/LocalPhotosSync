import AppKit
import ImageCaptureCore
import UniformTypeIdentifiers

enum CameraConnectionState: String {
    case waiting, unlock, catalog, loading, ready, error

    var label: String {
        switch self {
        case .waiting: "Ожидание устройства"
        case .unlock: "Разблокируйте iPhone"
        case .catalog: "Подключено, получаем каталог"
        case .loading: "Загружается список файлов"
        case .ready: "Готово к просмотру и переносу"
        case .error: "Ошибка подключения"
        }
    }
}

struct MediaItem: Identifiable {
    let id: String
    let file: ICCameraFile
    var name: String { file.name ?? file.originalFilename ?? "Без имени" }
    var date: Date? { file.creationDate }
    var bytes: Int64 { Int64(file.fileSize) }
    var isVideo: Bool {
        if let uti = file.uti, let type = UTType(uti) { return type.conforms(to: .movie) }
        return ["mov", "mp4", "m4v"].contains((name as NSString).pathExtension.lowercased())
    }
}

@MainActor
private final class DownloadTicket {
    var progress: Progress?
    private var continuation: CheckedContinuation<String, Error>?

    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }

    func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func cancel(with error: Error = ArchiveError.disconnected) {
        finish(.failure(error))
        progress?.cancel()
    }
}

private struct ImportCancelledError: LocalizedError {
    var errorDescription: String? { "Импорт отменён пользователем." }
}

@MainActor
final class CameraStore: NSObject, ObservableObject, @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate {
    @Published private(set) var devices: [ICCameraDevice] = []
    @Published private(set) var items: [MediaItem] = []
    @Published var selected: Set<String> = []
    @Published private(set) var connectedID = ""
    @Published private(set) var ready = false
    @Published private(set) var connectionState: CameraConnectionState = .waiting
    @Published private(set) var importing = false
    @Published private(set) var status = "Подключите iPhone кабелем, разблокируйте его и подтвердите доверие к Mac."
    @Published private(set) var results = ""
    @Published private(set) var lastArchive: URL?
    @Published private(set) var importedCount = 0
    @Published private(set) var verifyingArchive = false
    @Published private(set) var verificationResults = ""

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var catalog: [String: MediaItem] = [:]
    private let thumbnails = NSCache<NSString, NSImage>()
    private var activeDownload: DownloadTicket?
    private var reconnectID: String?
    private var lastError: NSError?
    private var cancelRequested = false

    override init() {
        super.init()
        thumbnails.countLimit = 250
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }

    func deviceID(_ device: ICDevice) -> String { String(describing: ObjectIdentifier(device)) }

    func connect(_ id: String) {
        guard !importing, id != connectedID else { return }
        reconnectID = nil
        camera?.requestCloseSession()
        camera = devices.first { deviceID($0) == id }
        connectedID = camera.map(deviceID) ?? ""
        catalog = [:]
        items = []
        selected = []
        thumbnails.removeAllObjects()
        ready = false
        lastError = nil
        guard let camera else { connectionState = .waiting; status = "Выберите подключённый iPhone."; return }
        camera.delegate = self
        connectionState = .unlock
        status = "Подключение к \(camera.name ?? "устройству")… Разблокируйте iPhone."
        camera.requestOpenSession()
    }

    func reconnect() {
        guard !importing, let camera else { return }
        ready = false
        connectionState = .unlock
        lastError = nil
        status = "Повторное подключение… Разблокируйте iPhone."
        if camera.hasOpenSession {
            reconnectID = connectedID
            camera.requestCloseSession()
        } else {
            camera.requestOpenSession()
        }
    }

    private func collect(_ added: [ICCameraItem]) {
        for item in added {
            if let folder = item as? ICCameraFolder { collect(folder.contents ?? []) }
            if let file = item as? ICCameraFile {
                let id = String(describing: ObjectIdentifier(file))
                catalog[id] = MediaItem(id: id, file: file)
            }
        }
    }

    private func publishCatalog() {
        items = catalog.values.sorted {
            if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
        }
        selected.formIntersection(catalog.keys)
    }

    func thumbnail(for item: MediaItem) async -> NSImage? {
        if let cached = thumbnails.object(forKey: item.id as NSString) { return cached }
        guard ready, camera?.hasOpenSession == true else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            item.file.requestThumbnailData(options: nil) { data, _ in continuation.resume(returning: data) }
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        thumbnails.setObject(image, forKey: item.id as NSString)
        return image
    }

    func selectVisible(_ ids: [String]) {
        guard !importing, ready else { return }
        selected.formUnion(ids)
    }

    func diagnostics() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let error = lastError.map { "\($0.domain) code=\($0.code)" } ?? "none"
        return [
            "LocalPhotosSync \(version) (\(build))",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Devices: \(devices.count)",
            "Session: \(camera?.hasOpenSession == true ? "open" : "closed")",
            "State: \(connectionState.rawValue)",
            "Ready: \(ready)",
            "Catalog: \(items.count) files",
            "Selected: \(selected.count)",
            "Imported this run: \(importedCount)",
            "Last error: \(error)"
        ].joined(separator: "\n")
    }

    func cancelImport() {
        guard importing else { return }
        cancelRequested = true
        activeDownload?.cancel(with: ImportCancelledError())
        status = "Отмена после завершения текущей проверки файла…"
    }

    func verifyArchiveFolder() {
        guard !verifyingArchive else { return }
        let panel = NSOpenPanel()
        panel.title = "Выберите папку переноса для проверки"
        panel.prompt = "Проверить папку"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        verifyingArchive = true
        verificationResults = "Проверка файлов и контрольных сумм…"
        Task {
            let reportURL = directory.appendingPathComponent("import-report.json")
            let outcome = await Task.detached(priority: .utility) { () -> Result<ArchiveVerification, Error> in
                do { return .success(try ArchiveVerification.verify(reportAt: reportURL)) }
                catch { return .failure(error) }
            }.value
            switch outcome {
            case let .success(result):
                let heading = result.isValid ? "Проверка пройдена." : "Проверка не пройдена или архив неполон."
                verificationResults = "\(heading) Проверено файлов: \(result.verifiedFiles)." + (result.failures.isEmpty ? "" : "\n" + result.failures.joined(separator: "\n"))
            case let .failure(error):
                verificationResults = "Не удалось проверить папку: \(error.localizedDescription)"
            }
            verifyingArchive = false
        }
    }

    func importSelected() {
        guard ready, !importing, let sourceCamera = camera, sourceCamera.hasOpenSession else { return }
        let batch = items.filter { selected.contains($0.id) }
        guard !batch.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Куда сохранить выбранные файлы?"
        panel.prompt = "Выбрать папку"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let startedAt = Date()
        let stamp = ISO8601DateFormatter().string(from: startedAt).replacingOccurrences(of: ":", with: "-")
        let directory = parent.appendingPathComponent("LocalPhotosSync-\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        catch { results = "Не удалось создать папку: \(error.localizedDescription)"; return }
        importing = true
        cancelRequested = false
        importedCount = 0
        results = ""
        lastArchive = directory

        Task {
            var receipts: [FileReceipt] = []
            var errors: [String] = []
            var finishedBatch = false
            do {
                try ImportReport(startedAt: startedAt, files: receipts, errors: errors, expectedFileCount: batch.count, completed: false).write(to: directory)
            } catch {
                results = "Не удалось записать начальный отчёт: \(error.localizedDescription)"
                importing = false
                return
            }
            for (index, item) in batch.enumerated() {
                if cancelRequested {
                    errors.append("Импорт отменён пользователем. Оставшиеся файлы не обрабатывались.")
                    break
                }
                status = "Сохранение \(index + 1) из \(batch.count): \(item.name)"
                do {
                    guard camera === sourceCamera, ready, sourceCamera.hasOpenSession else { throw ArchiveError.disconnected }
                    // Separate directories prevent duplicate names and sidecars from overwriting earlier files.
                    let destination = directory.appendingPathComponent(String(format: "%05d", index + 1), isDirectory: true)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    let filename = try await download(item.file, to: destination)
                    let url = destination.appendingPathComponent((filename as NSString).lastPathComponent)
                    let sourceName = item.name
                    let sourceBytes = item.bytes
                    let receipt = try await Task.detached(priority: .utility) {
                        try FileReceipt.verify(url: url, sourceName: sourceName, sourceBytes: sourceBytes)
                    }.value
                    receipts.append(receipt)
                    importedCount = receipts.count
                } catch {
                    if !(error is ImportCancelledError) { lastError = error as NSError }
                    errors.append("\(item.name): \(error.localizedDescription)")
                }
                if cancelRequested {
                    errors.append("Импорт отменён пользователем после завершения текущей проверки. Архив неполон.")
                    do { try ImportReport(startedAt: startedAt, files: receipts, errors: errors, expectedFileCount: batch.count, completed: false).write(to: directory) }
                    catch { errors.append("Не удалось записать отчёт об отмене: \(error.localizedDescription)") }
                    break
                }
                if camera !== sourceCamera || !ready || !sourceCamera.hasOpenSession {
                    errors.append("Телефон стал недоступен. Оставшиеся \(batch.count - index - 1) файлов не обрабатывались.")
                    do { try ImportReport(startedAt: startedAt, files: receipts, errors: errors, expectedFileCount: batch.count, completed: false).write(to: directory) }
                    catch { errors.append("Не удалось записать отчёт об отключении: \(error.localizedDescription)") }
                    break
                }
                do { try ImportReport(startedAt: startedAt, files: receipts, errors: errors, expectedFileCount: batch.count, completed: false).write(to: directory) }
                catch {
                    errors.append("Не удалось записать промежуточный отчёт: \(error.localizedDescription)")
                    try? ImportReport(startedAt: startedAt, files: receipts, errors: errors, expectedFileCount: batch.count, completed: false).write(to: directory)
                    break
                }
                if index == batch.count - 1 { finishedBatch = true }
            }
            if finishedBatch {
                do { try ImportReport(startedAt: startedAt, files: receipts, errors: errors, expectedFileCount: batch.count, completed: true).write(to: directory) }
                catch {
                    errors.append("Не удалось записать финальный отчёт: \(error.localizedDescription)")
                    try? ImportReport(startedAt: startedAt, files: receipts, errors: errors, expectedFileCount: batch.count, completed: false).write(to: directory)
                    finishedBatch = false
                }
            }
            importing = false
            activeDownload = nil
            cancelRequested = false
            status = "Сохранено: \(receipts.count) из \(batch.count). Ошибок: \(errors.count)."
            let summary = finishedBatch && errors.isEmpty ? "Файлы и отчёт сохранены. Исходники на iPhone не изменены." : errors.joined(separator: "\n")
            results = summary
        }
    }

    private func download(_ file: ICCameraFile, to directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let ticket = DownloadTicket(continuation)
            activeDownload = ticket
            ticket.progress = file.requestDownload(options: [
                .downloadsDirectoryURL: directory,
                .overwrite: false,
                .deleteAfterSuccessfulDownload: false,
                .sidecarFiles: true,
            ]) { filename, error in
                Task { @MainActor in
                    if let error { ticket.finish(.failure(error)) }
                    else if let filename { ticket.finish(.success(filename)) }
                    else { ticket.finish(.failure(ArchiveError.missingFilename)) }
                }
            }
        }
    }

    private func lostAccess(_ device: ICDevice) {
        guard device === camera else { return }
        ready = false
        connectionState = lastError == nil ? .unlock : .error
        activeDownload?.cancel()
        status = "Разблокируйте iPhone и проверьте кабель. Затем нажмите «Подключиться снова»."
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        if !devices.contains(where: { $0 === camera }) { devices.append(camera) }
        if self.camera == nil { connect(deviceID(camera)) }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        lostAccess(device)
        devices.removeAll { $0 === device }
        if device === camera {
            connectionState = .waiting
            camera = nil
            connectedID = ""
            catalog = [:]
            items = []
            selected = []
        }
    }

    func didRemove(_ device: ICDevice) { lostAccess(device) }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        guard device === camera else { return }
        if let id = reconnectID {
            reconnectID = nil
            camera = nil
            connectedID = ""
            connect(id)
        } else {
            if let error { lastError = error as NSError; connectionState = .error }
            lostAccess(device)
        }
    }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard device === camera else { return }
        if let error {
            lastError = error as NSError
            connectionState = .error
            status = "Не удалось открыть iPhone: \(error.localizedDescription)"
        } else {
            lastError = nil
            connectionState = .catalog
            status = "Чтение списка файлов…"
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        guard camera === self.camera else { return }
        collect(items)
        publishCatalog()
        if !ready {
            connectionState = .loading
            status = "Чтение списка: найдено \(self.items.count) файлов…"
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        guard camera === self.camera else { return }
        catalog = [:]
        collect(camera.mediaFiles ?? [])
        publishCatalog()
    }

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        guard camera === self.camera else { return }
        publishCatalog()
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard device === camera else { return }
        collect(device.mediaFiles ?? [])
        publishCatalog()
        ready = true
        connectionState = .ready
        status = "Доступно \(items.count) файлов. Выберите несколько для первого переноса."
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { lostAccess(device) }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        guard device === camera else { return }
        if let camera, camera.hasOpenSession {
            ready = camera.contentCatalogPercentCompleted == 100
            connectionState = ready ? .ready : .loading
            status = ready ? "Доступ восстановлен. Файлов: \(items.count)." : "Чтение списка файлов…"
        }
    }
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
}
