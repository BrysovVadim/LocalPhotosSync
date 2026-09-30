import Foundation
import Photos

enum MacPhotoLibraryProbe {
    private struct Result: Encodable {
        let source: String = "mac_system_photos_library"
        let authorizationStatus: String
        let photos: Int?
        let videos: Int?
        let other: Int?
        let total: Int?
        let hiddenAssets: String = "excluded"
        let bursts: String = "representative_only"
        let iCloudSync: String = "unknown"
        let completeness: String = "unknown"
        let error: String?

        private enum CodingKeys: String, CodingKey {
            case source, authorizationStatus, photos, videos, other, total, hiddenAssets, bursts, iCloudSync, completeness, error
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(source, forKey: .source)
            try container.encode(authorizationStatus, forKey: .authorizationStatus)
            try container.encode(photos, forKey: .photos)
            try container.encode(videos, forKey: .videos)
            try container.encode(other, forKey: .other)
            try container.encode(total, forKey: .total)
            try container.encode(hiddenAssets, forKey: .hiddenAssets)
            try container.encode(bursts, forKey: .bursts)
            try container.encode(iCloudSync, forKey: .iCloudSync)
            try container.encode(completeness, forKey: .completeness)
            try container.encode(error, forKey: .error)
        }
    }

    private struct Counts {
        var photos = 0
        var videos = 0
        var other = 0
        var total: Int { photos + videos + other }
    }
    private enum FetchResult {
        case counts(Counts)
        case unavailable
    }

    @MainActor
    private final class Bridge<T> { var value: T? }

    @MainActor
    static func run(requestAccess: Bool, seconds: Int) -> LocalPhotosSyncCLI.Outcome {
        guard (10...120).contains(seconds) else {
            return outcome(status: "invalid_timeout", counts: nil, error: "timeout_must_be_10_to_120_seconds")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined && requestAccess {
            guard isConfiguredAppBundle else {
                return outcome(status: label(status), counts: nil, error: "access_request_requires_packaged_app")
            }
            let bridge = Bridge<PHAuthorizationStatus>()
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                Task { @MainActor in bridge.value = newStatus }
            }
            while bridge.value == nil && ProcessInfo.processInfo.systemUptime < deadline { pump(until: deadline) }
            guard ProcessInfo.processInfo.systemUptime < deadline, let requestedStatus = bridge.value else {
                return finalOutcome(status: label(status), counts: nil, libraryUnavailable: false, deadlineExceeded: true)
            }
            status = requestedStatus
        }
        guard status == .authorized || status == .limited else {
            let error = status == .notDetermined ? "use_request_access_from_packaged_app" : "photo_library_access_not_granted"
            return accessRequiredOutcome(status: label(status), error: error)
        }
        guard isConfiguredAppBundle else {
            return accessRequiredOutcome(status: label(status), error: "photo_library_probe_requires_packaged_app")
        }
        guard PHPhotoLibrary.shared().unavailabilityReason == nil else {
            return finalOutcome(status: label(status), counts: nil, libraryUnavailable: true, deadlineExceeded: false)
        }

        let bridge = Bridge<FetchResult>()
        DispatchQueue.global(qos: .utility).async {
            guard PHPhotoLibrary.shared().unavailabilityReason == nil else {
                Task { @MainActor in bridge.value = .unavailable }
                return
            }
            let options = PHFetchOptions()
            options.includeHiddenAssets = false
            options.includeAllBurstAssets = false
            let assets = PHAsset.fetchAssets(with: options)
            var counts = Counts()
            assets.enumerateObjects { asset, _, _ in
                switch asset.mediaType {
                case .image: counts.photos += 1
                case .video: counts.videos += 1
                default: counts.other += 1
                }
            }
            Task { @MainActor in bridge.value = .counts(counts) }
        }
        while bridge.value == nil && ProcessInfo.processInfo.systemUptime < deadline { pump(until: deadline) }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            return finalOutcome(status: label(status), counts: nil, libraryUnavailable: false, deadlineExceeded: true)
        }
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let unavailable = PHPhotoLibrary.shared().unavailabilityReason != nil
        let result = bridge.value
        let counts: (photos: Int, videos: Int, other: Int)?
        let fetchUnavailable: Bool
        switch result {
        case .counts(let fetched)?:
            counts = (fetched.photos, fetched.videos, fetched.other)
            fetchUnavailable = false
        case .unavailable?, nil:
            counts = nil
            fetchUnavailable = true
        }
        return finalOutcome(status: label(currentStatus), counts: counts, libraryUnavailable: unavailable || fetchUnavailable, deadlineExceeded: false)
    }

    private static var isConfiguredAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.bundleIdentifier != nil
            && Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") as? String != nil
    }

    private static func label(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not_determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        case .limited: "limited"
        @unknown default: "unknown"
        }
    }

    private static func pump(until deadline: TimeInterval) {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining > 0 {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: min(0.1, remaining)))
        }
    }

    private static func outcome(status: String, counts: Counts?, error: String?) -> LocalPhotosSyncCLI.Outcome {
        let result = Result(
            authorizationStatus: status,
            photos: counts?.photos,
            videos: counts?.videos,
            other: counts?.other,
            total: counts?.total,
            error: error
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let json = String(decoding: try encoder.encode(result), as: UTF8.self)
            return LocalPhotosSyncCLI.Outcome(exitCode: error == nil ? 0 : 1, stdout: json, stderr: "")
        } catch {
            return LocalPhotosSyncCLI.Outcome(exitCode: 2, stdout: "", stderr: "result_encoding_failed")
        }
    }

    static func accessRequiredOutcome(status: String, error: String) -> LocalPhotosSyncCLI.Outcome {
        outcome(status: status, counts: nil, error: error)
    }

    static func finalOutcome(status: String, counts: (photos: Int, videos: Int, other: Int)?, libraryUnavailable: Bool, deadlineExceeded: Bool) -> LocalPhotosSyncCLI.Outcome {
        if deadlineExceeded { return outcome(status: status, counts: nil, error: "deadline_exceeded") }
        if libraryUnavailable { return outcome(status: status, counts: nil, error: "photo_library_unavailable") }
        guard status == "authorized" || status == "limited" else {
            return outcome(status: status, counts: nil, error: "photo_library_access_not_granted")
        }
        guard let counts else { return outcome(status: status, counts: nil, error: "photo_library_fetch_failed") }
        return outcome(status: status, counts: Counts(photos: counts.photos, videos: counts.videos, other: counts.other), error: nil)
    }
}
