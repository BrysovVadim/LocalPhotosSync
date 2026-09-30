import AppKit
import ImageCaptureCore
import UniformTypeIdentifiers

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

    func cancel() {
        finish(.failure(ArchiveError.disconnected))
        progress?.cancel()
    }
}

@MainActor
final class CameraStore: NSObject, ObservableObject, @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate {
    @Published private(set) var devices: [ICCameraDevice] = []
    @Published private(set) var items: [MediaItem] = []
    @Published var selected: Set<String> = []
    @Published private(set) var connectedID = ""
    @Published private(set) var ready = false
    @Published private(set) var importing = false
    @Published private(set) var status = "Подключите iPhone кабелем, разблокируйте его и подтвердите доверие к Mac."
    @Published private(set) var results = ""
    @Published private(set) var lastArchive: URL?

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var catalog: [String: MediaItem] = [:]
    private let thumbnails = NSCache<NSString, NSImage>()
    private var activeDownload: DownloadTicket?
    private var reconnectID: String?

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
        guard let camera else { status = "Выберите подключённый iPhone."; return }
        camera.delegate = self
        status = "Подключение к \(camera.name ?? "устройству")… Разблокируйте iPhone."
        camera.requestOpenSession()
    }

    func reconnect() {
        guard !importing, let camera else { return }
        ready = false
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
        results = ""
        lastArchive = directory

        Task {
            var receipts: [FileReceipt] = []
            var errors: [String] = []
            for (index, item) in batch.enumerated() {
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
                } catch { errors.append("\(item.name): \(error.localizedDescription)") }
                do { try ImportReport(startedAt: startedAt, files: receipts, errors: errors).write(to: directory) }
                catch { errors.append("Не удалось записать отчёт: \(error.localizedDescription)"); break }
                if camera !== sourceCamera || !ready || !sourceCamera.hasOpenSession {
                    results = "Телефон стал недоступен. Оставшиеся \(batch.count - index - 1) файлов не обрабатывались."
                    break
                }
            }
            importing = false
            activeDownload = nil
            status = "Сохранено: \(receipts.count) из \(batch.count). Ошибок: \(errors.count)."
            let summary = errors.isEmpty ? "Файлы и отчёт сохранены. Исходники на iPhone не изменены." : errors.joined(separator: "\n")
            results = results.isEmpty ? summary : summary + "\n" + results
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
            lostAccess(device)
        }
    }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard device === camera else { return }
        if let error { status = "Не удалось открыть iPhone: \(error.localizedDescription)" }
        else { status = "Чтение списка файлов…" }
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        guard camera === self.camera else { return }
        collect(items)
        publishCatalog()
        if !ready { status = "Чтение списка: найдено \(self.items.count) файлов…" }
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
        status = "Доступно \(items.count) файлов. Выберите несколько для первого переноса."
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { lostAccess(device) }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        guard device === camera else { return }
        if let camera, camera.hasOpenSession {
            ready = camera.contentCatalogPercentCompleted == 100
            status = ready ? "Доступ восстановлен. Файлов: \(items.count)." : "Чтение списка файлов…"
        }
    }
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
}
