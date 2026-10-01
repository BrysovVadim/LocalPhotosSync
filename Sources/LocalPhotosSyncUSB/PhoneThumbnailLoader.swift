import AppKit
import Combine
import Darwin
import Foundation
import ImageIO

// The decoded bitmap is immutable and is handed to the main actor once.
struct PhoneThumbnailBitmap: @unchecked Sendable {
    let image: CGImage
}

enum PhoneThumbnailResult: Sendable {
    case loaded(PhoneThumbnailBitmap)
    case unavailable
    case failed(String)
}

enum PhoneThumbnailDecoder {
    static func decode(_ url: URL, within cacheRoot: URL) -> PhoneThumbnailBitmap? {
        let normalized = url.standardizedFileURL
        let root = cacheRoot.standardizedFileURL
        guard normalized.path.hasPrefix(root.path + "/"),
              normalized.resolvingSymlinksInPath() == normalized,
              let values = try? normalized.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 4 * 1024 * 1024,
              let attributes = try? FileManager.default.attributesOfItem(atPath: normalized.path),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              let data = try? Data(contentsOf: normalized),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= 8 * 1024 * 1024 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return PhoneThumbnailBitmap(image: image)
    }
}

@MainActor
final class PhoneThumbnailLoader: ObservableObject {
    @Published private(set) var images: [Int64: NSImage] = [:]
    @Published private(set) var unavailable: Set<Int64> = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    /// Set when the last batch stopped on a transport error; automatic loading waits for a manual retry.
    @Published private(set) var lastBatchFailed = false

    private var generation = 0
    private var attempted: Set<Int64> = []
    private var cacheOrder: [Int64] = []

    func reset() {
        generation += 1
        images.removeAll()
        unavailable.removeAll()
        attempted.removeAll()
        cacheOrder.removeAll()
        message = nil
        lastBatchFailed = false
    }

    /// Stops a running batch after its current item, e.g. when the user leaves the page; loaded previews stay cached.
    func supersede() {
        guard isLoading else { return }
        generation += 1
    }

    func canLoad(_ assets: [PhoneCatalogAsset]) -> Bool {
        assets.contains { ($0.mediaType == .photo || $0.mediaType == .video) && $0.isVisibleLibraryItem && !attempted.contains($0.id) }
    }

    func load(_ assets: [PhoneCatalogAsset], snapshot: PhoneCatalogSnapshot) {
        guard !isLoading else { return }
        let pending = Array(assets.filter {
            ($0.mediaType == .photo || $0.mediaType == .video) && $0.isVisibleLibraryItem && !attempted.contains($0.id)
        }.prefix(12))
        guard !pending.isEmpty else { return }
        let folder = snapshot.sourceFolder
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("source-binding.bin").path) else {
            message = "Обновите каталог с iPhone, чтобы загрузить превью из того же телефона."
            lastBatchFailed = true
            return
        }
        isLoading = true
        lastBatchFailed = false
        message = "Загружаем превью с iPhone…"
        let currentGeneration = generation
        Task {
            let deadline = ProcessInfo.processInfo.systemUptime + 45
            var loaded = 0
            for asset in pending {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard generation == currentGeneration, remaining > 0 else { break }
                let result = await Task.detached(priority: .userInitiated) {
                    Self.fetch(assetID: asset.id, snapshotFolder: folder, timeout: remaining)
                }.value
                guard generation == currentGeneration else { break }
                switch result {
                case .loaded(let bitmap):
                    images[asset.id] = NSImage(cgImage: bitmap.image, size: .zero)
                    attempted.insert(asset.id)
                    cacheOrder.append(asset.id)
                    if cacheOrder.count > 96 {
                        let oldest = cacheOrder.removeFirst()
                        images.removeValue(forKey: oldest)
                        attempted.remove(oldest)
                    }
                    loaded += 1
                case .unavailable:
                    attempted.insert(asset.id)
                    unavailable.insert(asset.id)
                case .failed(let reason):
                    message = reason
                    lastBatchFailed = true
                    isLoading = false
                    return
                }
                message = "Загружено превью: \(loaded) из \(pending.count)"
            }
            isLoading = false
            if generation == currentGeneration {
                message = "Загружено превью: \(loaded). Превью не подтверждает наличие оригинала."
            }
        }
    }

    nonisolated static func fetch(assetID: Int64, snapshotFolder: URL, timeout: TimeInterval = 45) -> PhoneThumbnailResult {
        guard assetID > 0, timeout.isFinite, timeout > 0, timeout <= 45,
              snapshotFolder.deletingLastPathComponent().lastPathComponent == "phone-catalog-probe" else {
            return .failed("Не удалось проверить источник каталога.")
        }
        let build = snapshotFolder.deletingLastPathComponent().deletingLastPathComponent()
        guard build.lastPathComponent == ".build" else { return .failed("Не удалось найти файлы приложения.") }
        let root = build.deletingLastPathComponent()
        let script = root.appendingPathComponent("experiments/afc/run-thumbnail-probe.py")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Isolate the runner and its compiler/device child so the deadline stops all of them.
        let launch = "import os,sys; os.getpgrp()==os.getpid() or os.setsid(); os.execv(sys.executable,[sys.executable]+sys.argv[1:])"
        process.arguments = ["-c", launch, script.path, "--snapshot", snapshotFolder.path, "--asset-id", String(assetID)]
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "USBMUXD_SOCKET_ADDRESS")
        process.environment = environment
        do { try process.run() } catch { return .failed("Не удалось запустить загрузку превью.") }
        let watchdog = DispatchWorkItem {
            if process.isRunning { _ = kill(-process.processIdentifier, SIGTERM) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        if process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM {
            return .failed("Загрузка превью заняла слишком много времени. Попробуйте ещё раз.")
        }
        guard data.count <= 16 * 1024,
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["source"] as? String == "iphone_afc",
              let status = result["status"] as? String else {
            return .failed("Не удалось получить превью. Проверьте подключение iPhone.")
        }
        if status == "thumbnail_unavailable" || status == "candidate_unknown" { return .unavailable }
        if status == "source_binding_mismatch" || status == "source_device_mismatch" || status == "source_binding_unavailable" {
            return .failed("Подключён другой iPhone или каталог устарел. Обновите каталог с телефона.")
        }
        guard process.terminationStatus == 0, status == "thumbnail_copied",
              let path = result["localImagePath"] as? String,
              let image = PhoneThumbnailDecoder.decode(URL(fileURLWithPath: path),
                  within: build.appendingPathComponent("phone-thumbnail-probe")) else {
            return .failed("Не удалось загрузить превью. Разблокируйте iPhone и проверьте подключение.")
        }
        return .loaded(image)
    }
}
