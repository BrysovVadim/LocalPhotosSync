import AVFoundation
import AppKit
import CoreGraphics
import CoreFoundation
import Foundation
import ImageIO
import Photos
import Darwin

@MainActor
private final class LivePhotoRequestState {
    var finished = false
    var loadable = false
}

@main
struct VerifyPhoneLivePhoto {
    private static let maxInputBytes = 8 * 1024
    private static let maxMediaBytes: Int64 = 32 * 1024 * 1024
    private static let maxReceiptBytes: Int64 = 2 * 1024
    private static let maxDimension = 8192
    private static let maxPixels = 64_000_000

    @MainActor
    static func main() async {
        guard CommandLine.arguments.count == 2 else { emit(status: "input_invalid"); return }
        do {
            let values = try loadInputs(URL(fileURLWithPath: CommandLine.arguments[1]))
            let image = URL(fileURLWithPath: values.imageFile)
            let movie = URL(fileURLWithPath: values.movieFile)
            let imageFolder = URL(fileURLWithPath: values.imageFolder, isDirectory: true)
            let movieFolder = URL(fileURLWithPath: values.movieFolder, isDirectory: true)
            _ = try validateMedia(image)
            _ = try validateMedia(movie)

            let imageReceipt = try validateReceipt(in: imageFolder, media: image)
            let movieReceipt = try validateReceipt(in: movieFolder, media: movie)
            guard imageReceipt && movieReceipt else {
                emit(status: "hash_mismatch", hashMatches: false)
                return
            }

            guard let imageSource = CGImageSourceCreateWithURL(image as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
                  let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
                  width > 0, height > 0, width <= maxDimension, height <= maxDimension,
                  Int64(width) * Int64(height) <= maxPixels else {
                emit(status: "image_metadata_invalid", hashMatches: true)
                return
            }
            guard let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
                  let imageIdentifier = maker["17"] as? String,
                  !imageIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                emit(status: "image_identifier_missing", hashMatches: true,
                     imageWidth: width, imageHeight: height)
                return
            }
            guard CGImageSourceCreateImageAtIndex(imageSource, 0,
                                                   [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
                emit(status: "image_decode_failed", hashMatches: true, imageIdentifierFound: true,
                     imageWidth: width, imageHeight: height)
                return
            }

            let asset = AVURLAsset(url: movie)
            let metadata = try await asset.load(.metadata)
            let items = AVMetadataItem.metadataItems(from: metadata,
                filteredByIdentifier: .quickTimeMetadataContentIdentifier)
            var movieIdentifier: String?
            for item in items {
                if let identifier = try await item.load(.stringValue),
                   !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    movieIdentifier = identifier
                    break
                }
            }
            let duration = try await asset.load(.duration)
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let durationSeconds = duration.seconds
            guard durationSeconds.isFinite, durationSeconds >= 0 else {
                emit(status: "movie_metadata_invalid", hashMatches: true, imageIdentifierFound: true,
                     movieIdentifierFound: movieIdentifier != nil, imageWidth: width, imageHeight: height,
                     videoTracks: tracks.count, containerPlayable: playable)
                return
            }
            guard let movieIdentifier else {
                emit(status: "movie_identifier_missing", hashMatches: true, imageIdentifierFound: true,
                     imageWidth: width, imageHeight: height, durationSeconds: durationSeconds,
                     videoTracks: tracks.count, containerPlayable: playable)
                return
            }
            let identifiersMatch = imageIdentifier == movieIdentifier
            guard identifiersMatch else {
                emit(status: "identifier_mismatch", hashMatches: true, imageIdentifierFound: true,
                     movieIdentifierFound: true, identifiersMatch: false, imageWidth: width,
                     imageHeight: height, durationSeconds: durationSeconds,
                     videoTracks: tracks.count, containerPlayable: playable)
                return
            }

            let state = LivePhotoRequestState()
            let request = PHLivePhoto.request(withResourceFileURLs: [image, movie], placeholderImage: nil,
                targetSize: CGSize(width: 1024, height: 1024), contentMode: .aspectFit) { livePhoto, info in
                    let degraded = info[PHLivePhotoInfoIsDegradedKey] as? Bool == true
                    if !degraded {
                        Task { @MainActor in
                            state.loadable = livePhoto != nil
                            state.finished = true
                        }
                    }
                }
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !state.finished && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if !state.finished { PHLivePhoto.cancelRequest(withRequestID: request) }
            let verified = state.finished && state.loadable && playable && !tracks.isEmpty
            emit(status: verified ? "verified" : (state.finished ? "live_photo_unavailable" : "live_photo_timeout"),
                 verified: verified, hashMatches: true, imageIdentifierFound: true,
                 movieIdentifierFound: true, identifiersMatch: true, imageWidth: width,
                 imageHeight: height, durationSeconds: durationSeconds, videoTracks: tracks.count,
                 containerPlayable: playable, livePhotoFilesLoadable: state.loadable)
        } catch let failure as VerifyFailure {
            emit(status: failure.rawValue)
        } catch {
            emit(status: "validation_failed")
        }
    }

    private struct Inputs {
        let imageFile: String
        let movieFile: String
        let imageFolder: String
        let movieFolder: String
    }

    private enum VerifyFailure: String, Error {
        case inputInvalid = "input_invalid"
        case receiptInvalid = "receipt_invalid"
        case hashMismatch = "hash_mismatch"
    }

    private static func loadInputs(_ url: URL) throws -> Inputs {
        let data = try readPrivateFile(url, limit: Int64(maxInputBytes), expectedMode: 0o600)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["imageFile", "movieFile", "imageFolder", "movieFolder", "proofFolder"]),
              let imageFile = object["imageFile"] as? String, !imageFile.isEmpty,
              let movieFile = object["movieFile"] as? String, !movieFile.isEmpty,
              let imageFolder = object["imageFolder"] as? String, !imageFolder.isEmpty,
              let movieFolder = object["movieFolder"] as? String, !movieFolder.isEmpty,
              let proofFolder = object["proofFolder"] as? String, !proofFolder.isEmpty else {
            throw VerifyFailure.inputInvalid
        }
        try validatePrivateDirectory(URL(fileURLWithPath: imageFolder, isDirectory: true))
        try validatePrivateDirectory(URL(fileURLWithPath: movieFolder, isDirectory: true))
        try validatePrivateDirectory(URL(fileURLWithPath: proofFolder, isDirectory: true))
        return Inputs(imageFile: imageFile, movieFile: movieFile,
                      imageFolder: imageFolder, movieFolder: movieFolder)
    }

    private static func validateMedia(_ url: URL) throws -> Int64 {
        try validatePrivateDirectory(url.deletingLastPathComponent())
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o777) == 0o600, info.st_size > 0,
              info.st_size <= maxMediaBytes else { throw VerifyFailure.inputInvalid }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VerifyFailure.inputInvalid }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_ino == info.st_ino,
              opened.st_dev == info.st_dev, (opened.st_mode & S_IFMT) == S_IFREG else {
            throw VerifyFailure.inputInvalid
        }
        return Int64(opened.st_size)
    }

    private static func validateReceipt(in folder: URL, media: URL) throws -> Bool {
        let receiptURL = folder.appendingPathComponent("copy-receipt.json")
        let data: Data
        do { data = try readPrivateFile(receiptURL, limit: maxReceiptBytes, expectedMode: 0o600) }
        catch { throw VerifyFailure.receiptInvalid }
        guard let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(receipt.keys) == Set(["source", "status", "declaredBytes", "copiedBytes", "stableObserved", "receivedStreamSHA256"]),
              receipt["source"] as? String == "iphone_afc",
              receipt["status"] as? String == "asset_copy_complete",
              receipt["stableObserved"] as? Bool == true,
              let bytes = strictInt64(receipt["copiedBytes"]),
              let declared = strictInt64(receipt["declaredBytes"]),
              bytes > 0, bytes <= maxMediaBytes, declared == bytes,
              let hash = receipt["receivedStreamSHA256"] as? String,
              hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw VerifyFailure.receiptInvalid
        }
        let digest: (bytes: Int64, sha256: String)
        do { digest = try FileReceipt.archiveDigest(media) }
        catch { throw VerifyFailure.receiptInvalid }
        return (digest.bytes == bytes && digest.sha256 == hash)
    }

    private static func readPrivateFile(_ url: URL, limit: Int64, expectedMode: mode_t) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VerifyFailure.inputInvalid }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o777) == expectedMode, info.st_size >= 0, info.st_size <= limit else {
            throw VerifyFailure.inputInvalid
        }
        var result = Data(capacity: Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 { throw VerifyFailure.inputInvalid }
            if count == 0 { break }
            guard result.count + count <= limit else { throw VerifyFailure.inputInvalid }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard result.count == info.st_size else { throw VerifyFailure.inputInvalid }
        return result
    }

    private static func validatePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o777) == 0o700 else { throw VerifyFailure.inputInvalid }
    }

    private static func strictInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.int64Value
    }

    @MainActor
    private static func emit(status: String, verified: Bool = false, hashMatches: Bool = false,
                             imageIdentifierFound: Bool = false, movieIdentifierFound: Bool = false,
                             identifiersMatch: Bool = false, imageWidth: Int = 0, imageHeight: Int = 0,
                             durationSeconds: Double = 0, videoTracks: Int = 0,
                             containerPlayable: Bool = false, livePhotoFilesLoadable: Bool = false) {
        let output: [String: Any] = [
            "verified": verified, "status": status, "hashMatches": hashMatches,
            "imageIdentifierFound": imageIdentifierFound, "movieIdentifierFound": movieIdentifierFound,
            "identifiersMatch": identifiersMatch, "imageWidth": imageWidth, "imageHeight": imageHeight,
            "durationSeconds": durationSeconds.isFinite ? durationSeconds : 0,
            "videoTracks": videoTracks, "containerPlayable": containerPlayable,
            "livePhotoFilesLoadable": livePhotoFilesLoadable, "libraryAccessRequested": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else {
            print("{\"verified\":false,\"status\":\"output_failed\"}")
            fflush(stdout)
            Darwin.exit(1)
        }
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
        Darwin.exit(verified ? 0 : 1)
    }
}
