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
    var isPhoto: Bool {
        guard let uti = file.uti, let type = UTType(uti) else { return false }
        return type.conforms(to: .image)
    }
}

struct ProbeFileSelection {
    let photoCount: Int
    let videoCount: Int
    let sourceBytes: Int64
    var fileCount: Int { photoCount + videoCount }
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
    private(set) var deviceDiscoveryComplete = false
    private(set) var sessionOpenResult = "not_attempted"

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var catalog: [String: MediaItem] = [:]
    private let thumbnails = NSCache<NSString, NSImage>()
    private var activeDownload: DownloadTicket?
    private var reconnectID: String?
    private var lastError: NSError?
    private var cancelRequested = false
    private var accessRestricted = false

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
        accessRestricted = false
        thumbnails.removeAllObjects()
        ready = false
        lastError = nil
        guard let camera else { connectionState = .waiting; status = "Выберите подключённый iPhone."; return }
        camera.delegate = self
        connectionState = .unlock
        status = "Подключение к \(camera.name ?? "устройству")… Разблокируйте iPhone."
        requestOpenSession(camera)
    }

    private func requestOpenSession(_ device: ICCameraDevice) {
        sessionOpenResult = "pending"
        device.requestOpenSession()
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
            requestOpenSession(camera)
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
        let catalog = catalogAggregates()
        let catalogPaths = catalogPathInvariants()
        return [
            "LocalPhotosSync \(version) (\(build))",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Devices: \(devices.count)",
            "Transport: \(transportLabel(camera))",
            "Session: \(camera?.hasOpenSession == true ? "open" : "closed")",
            "Session open attempt: \(sessionOpenResult)",
            "Access restricted: \(accessRestricted)",
            "State: \(connectionState.rawValue)",
            "Ready: \(ready)",
            "Catalog: \(items.count) files",
            "SDK catalog progress: \(camera?.contentCatalogPercentCompleted ?? 0)%",
            "SDK direct mediaFiles files: \(catalogPaths.directMediaFileCount)",
            "SDK recursive contents files: \(catalogPaths.contentsTreeFileCount)",
            "SDK snapshot files absent from store.items: \(catalogPaths.snapshotFilesAbsentFromStore)",
            "SDK snapshot files absent by UTI: images=\(catalogPaths.absentImages) movies=\(catalogPaths.absentMovies) audio=\(catalogPaths.absentAudio) other=\(catalogPaths.absentOther)",
            "contents-only files with nonzero PTP handles: \(catalogPaths.treeOnlyNonzeroPTPHandles)",
            "contents-only files matching flat list by unique nonzero PTP handle: \(catalogPaths.treeOnlyUniquePTPHandleMatches)",
            "Catalog UTType counts: images=\(catalog.images) movies=\(catalog.movies) other=\(catalog.other)",
            "originatingAssetID: files=\(catalog.originatingAssetFiles) distinctIDs=\(catalog.distinctOriginatingAssetIDs)",
            "groupUUID: files=\(catalog.groupUUIDFiles) groups=\(catalog.groupUUIDCount) bytes=\(catalog.groupUUIDBytes) imageAndMovieGroups=\(catalog.groupUUIDMixedMediaGroups)",
            "relatedUUID: files=\(catalog.relatedUUIDFiles) groups=\(catalog.relatedUUIDCount) bytes=\(catalog.relatedUUIDBytes) imageAndMovieGroups=\(catalog.relatedUUIDMixedMediaGroups)",
            "Selected: \(selected.count)",
            "Imported this run: \(importedCount)",
            "Last error: \(error)"
        ].joined(separator: "\n")
    }

    private struct CatalogAggregates {
        let images: Int
        let movies: Int
        let other: Int
        let originatingAssetFiles: Int
        let distinctOriginatingAssetIDs: Int
        let groupUUIDFiles: Int
        let groupUUIDCount: Int
        let groupUUIDBytes: Int64
        let groupUUIDMixedMediaGroups: Int
        let relatedUUIDFiles: Int
        let relatedUUIDCount: Int
        let relatedUUIDBytes: Int64
        let relatedUUIDMixedMediaGroups: Int
    }

    private struct CatalogPathInvariants {
        let directMediaFileCount: Int
        let contentsTreeFileCount: Int
        let snapshotFilesAbsentFromStore: Int
        let absentImages: Int
        let absentMovies: Int
        let absentAudio: Int
        let absentOther: Int
        let treeOnlyNonzeroPTPHandles: Int
        let treeOnlyUniquePTPHandleMatches: Int
    }

    private func catalogPathInvariants() -> CatalogPathInvariants {
        guard let camera else {
            return CatalogPathInvariants(directMediaFileCount: 0, contentsTreeFileCount: 0, snapshotFilesAbsentFromStore: 0, absentImages: 0, absentMovies: 0, absentAudio: 0, absentOther: 0, treeOnlyNonzeroPTPHandles: 0, treeOnlyUniquePTPHandleMatches: 0)
        }
        var directFilesByID: [ObjectIdentifier: ICCameraFile] = [:]
        for item in camera.mediaFiles ?? [] {
            if let file = item as? ICCameraFile { directFilesByID[ObjectIdentifier(file)] = file }
        }

        var visited: Set<ObjectIdentifier> = []
        var treeFilesByID: [ObjectIdentifier: ICCameraFile] = [:]
        func visit(_ nodes: [ICCameraItem]) {
            for node in nodes {
                guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
                if let file = node as? ICCameraFile { treeFilesByID[ObjectIdentifier(file)] = file }
                if let folder = node as? ICCameraFolder { visit(folder.contents ?? []) }
            }
        }
        visit(camera.contents ?? [])

        let directFileIDs = Set(directFilesByID.keys)
        let treeFileIDs = Set(treeFilesByID.keys)
        let sdkSnapshotFileIDs = directFileIDs.union(treeFileIDs)
        let storeFileIDs = Set(items.map { ObjectIdentifier($0.file) })
        let absentIDs = sdkSnapshotFileIDs.subtracting(storeFileIDs)
        var absentImages = 0
        var absentMovies = 0
        var absentAudio = 0
        var absentOther = 0
        for identifier in absentIDs {
            guard let file = directFilesByID[identifier] ?? treeFilesByID[identifier],
                  let uti = file.uti,
                  let type = UTType(uti) else {
                absentOther += 1
                continue
            }
            if type.conforms(to: .image) { absentImages += 1 }
            else if type.conforms(to: .movie) { absentMovies += 1 }
            else if type.conforms(to: .audio) { absentAudio += 1 }
            else { absentOther += 1 }
        }

        let treeOnlyFiles = treeFileIDs.subtracting(directFileIDs).compactMap { treeFilesByID[$0] }
        let directHandleCounts = Dictionary(grouping: directFilesByID.values.filter { $0.ptpObjectHandle != 0 }, by: \.ptpObjectHandle).mapValues(\.count)
        let treeHandleCounts = Dictionary(grouping: treeFilesByID.values.filter { $0.ptpObjectHandle != 0 }, by: \.ptpObjectHandle).mapValues(\.count)
        let treeOnlyNonzeroPTPHandles = treeOnlyFiles.filter { $0.ptpObjectHandle != 0 }.count
        let treeOnlyUniquePTPHandleMatches = treeOnlyFiles.filter { file in
            let handle = file.ptpObjectHandle
            return handle != 0 && directHandleCounts[handle] == 1 && treeHandleCounts[handle] == 1
        }.count
        return CatalogPathInvariants(
            directMediaFileCount: directFileIDs.count,
            contentsTreeFileCount: treeFileIDs.count,
            snapshotFilesAbsentFromStore: absentIDs.count,
            absentImages: absentImages,
            absentMovies: absentMovies,
            absentAudio: absentAudio,
            absentOther: absentOther,
            treeOnlyNonzeroPTPHandles: treeOnlyNonzeroPTPHandles,
            treeOnlyUniquePTPHandleMatches: treeOnlyUniquePTPHandleMatches
        )
    }

    private struct MediaGroupAggregate {
        var fileCount = 0
        var bytes: Int64 = 0
        var hasImage = false
        var hasMovie = false

        mutating func add(kind: CatalogMediaKind, bytes: Int64) {
            fileCount += 1
            self.bytes += max(0, bytes)
            hasImage = hasImage || kind == .image
            hasMovie = hasMovie || kind == .movie
        }
    }

    private enum CatalogMediaKind { case image, movie, other }

    private func catalogAggregates() -> CatalogAggregates {
        var images = 0
        var movies = 0
        var other = 0
        var originatingAssetIDs: Set<String> = []
        var originatingAssetFiles = 0
        var groups: [String: MediaGroupAggregate] = [:]
        var related: [String: MediaGroupAggregate] = [:]

        for item in items {
            let kind: CatalogMediaKind
            if let uti = item.file.uti, let type = UTType(uti), type.conforms(to: .image) {
                kind = .image
                images += 1
            } else if let uti = item.file.uti, let type = UTType(uti), type.conforms(to: .movie) {
                kind = .movie
                movies += 1
            } else {
                kind = .other
                other += 1
            }

            if let identifier = item.file.originatingAssetID, !identifier.isEmpty {
                originatingAssetFiles += 1
                originatingAssetIDs.insert(identifier)
            }
            if let identifier = item.file.groupUUID, !identifier.isEmpty {
                groups[identifier, default: MediaGroupAggregate()].add(kind: kind, bytes: item.bytes)
            }
            if let identifier = item.file.relatedUUID, !identifier.isEmpty {
                related[identifier, default: MediaGroupAggregate()].add(kind: kind, bytes: item.bytes)
            }
        }

        return CatalogAggregates(
            images: images,
            movies: movies,
            other: other,
            originatingAssetFiles: originatingAssetFiles,
            distinctOriginatingAssetIDs: originatingAssetIDs.count,
            groupUUIDFiles: groups.values.reduce(0) { $0 + $1.fileCount },
            groupUUIDCount: groups.count,
            groupUUIDBytes: groups.values.reduce(0) { $0 + $1.bytes },
            groupUUIDMixedMediaGroups: groups.values.filter { $0.hasImage && $0.hasMovie }.count,
            relatedUUIDFiles: related.values.reduce(0) { $0 + $1.fileCount },
            relatedUUIDCount: related.count,
            relatedUUIDBytes: related.values.reduce(0) { $0 + $1.bytes },
            relatedUUIDMixedMediaGroups: related.values.filter { $0.hasImage && $0.hasMovie }.count
        )
    }

    var currentTransportLabel: String { transportLabel(camera) }

    private func transportLabel(_ device: ICDevice?) -> String {
        guard let transport = device?.transportType else { return "other" }
        if transport == ICDeviceTransport.transportTypeUSB.rawValue { return "USB" }
        if transport == ICDeviceTransport.transportTypeTCPIP.rawValue { return "network" }
        return "other"
    }

    @discardableResult
    func selectProbeFiles(maxBytes: Int64) -> ProbeFileSelection? {
        guard ready else { return nil }
        let eligible = items.filter { $0.bytes > 0 && $0.bytes <= maxBytes }
        guard let photo = eligible.filter(\.isPhoto).min(by: { $0.bytes < $1.bytes }) else {
            selected = []
            return nil
        }
        var chosen = [photo]
        let video = eligible.filter(\.isVideo).min(by: { $0.bytes < $1.bytes })
        if let video { chosen.append(video) }
        selected = Set(chosen.map(\.id))
        return ProbeFileSelection(photoCount: 1, videoCount: video.map { _ in 1 } ?? 0, sourceBytes: chosen.reduce(0) { $0 + $1.bytes })
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
        importSelected(to: parent)
    }

    @discardableResult
    func importSelected(to parent: URL, includeSidecars: Bool = true) -> URL? {
        guard ready, !importing, let sourceCamera = camera, sourceCamera.hasOpenSession else { return nil }
        let batch = items.filter { selected.contains($0.id) }
        guard !batch.isEmpty else { return nil }
        let startedAt = Date()
        let stamp = ISO8601DateFormatter().string(from: startedAt).replacingOccurrences(of: ":", with: "-")
        let directory = parent.appendingPathComponent("LocalPhotosSync-\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        catch { results = "Не удалось создать папку: \(error.localizedDescription)"; return nil }
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
                    let filename = try await download(item.file, to: destination, includeSidecars: includeSidecars)
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
        return directory
    }

    static func downloadOptions(to directory: URL, includeSidecars: Bool) -> [ICDownloadOption: Any] {
        [
            .downloadsDirectoryURL: directory,
            .overwrite: false,
            .deleteAfterSuccessfulDownload: false,
            .sidecarFiles: includeSidecars,
        ]
    }

    private func download(_ file: ICCameraFile, to directory: URL, includeSidecars: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let ticket = DownloadTicket(continuation)
            activeDownload = ticket
            ticket.progress = file.requestDownload(options: Self.downloadOptions(to: directory, includeSidecars: includeSidecars)) { filename, error in
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
        connectionState = accessRestricted || lastError?.code == -9943 ? .unlock : (lastError == nil ? .unlock : .error)
        activeDownload?.cancel()
        status = "Разблокируйте iPhone и проверьте кабель. Затем нажмите «Подключиться снова»."
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        deviceDiscoveryComplete = !moreComing
        guard let camera = device as? ICCameraDevice else { return }
        if !devices.contains(where: { $0 === camera }) { devices.append(camera) }
        if self.camera == nil { connect(deviceID(camera)) }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        deviceDiscoveryComplete = !moreGoing
        lostAccess(device)
        devices.removeAll { $0 === device }
        if device === camera {
            connectionState = .waiting
            camera = nil
            connectedID = ""
            catalog = [:]
            items = []
            selected = []
            accessRestricted = false
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
            ready = false
            let isLocked = (error as NSError).code == -9943
            if isLocked { accessRestricted = true }
            sessionOpenResult = isLocked ? "failed_passcode_locked" : "failed"
            connectionState = isLocked ? .unlock : .error
            status = isLocked ? "Разблокируйте iPhone, чтобы получить доступ к файлам." : "Не удалось открыть iPhone: \(error.localizedDescription)"
        } else {
            guard device.hasOpenSession else {
                ready = false
                sessionOpenResult = "callback_without_open_session"
                connectionState = .error
                status = "Сессия iPhone не открылась. Нажмите «Подключиться снова»."
                return
            }
            sessionOpenResult = "succeeded"
            if accessRestricted {
                ready = false
                connectionState = .unlock
                status = "Разблокируйте iPhone, чтобы восстановить доступ к файлам."
            } else {
                lastError = nil
                connectionState = .catalog
                status = "Чтение списка файлов…"
            }
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
        guard device.hasOpenSession, !accessRestricted else {
            ready = false
            connectionState = accessRestricted ? .unlock : .error
            return
        }
        lastError = nil
        sessionOpenResult = "succeeded"
        collect(device.mediaFiles ?? [])
        publishCatalog()
        ready = true
        connectionState = .ready
        status = "Доступно \(items.count) файлов. Выберите несколько для первого переноса."
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        guard device === camera else { return }
        accessRestricted = true
        lostAccess(device)
    }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        guard device === camera else { return }
        accessRestricted = false
        if let camera, camera.hasOpenSession {
            lastError = nil
            sessionOpenResult = "succeeded"
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
