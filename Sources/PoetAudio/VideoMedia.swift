import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

enum SourceMediaKind: String, Codable, Sendable {
    case audio
    case video
}

struct VideoMediaInfo: Sendable, Equatable {
    let duration: TimeInterval
    let frameRate: Double
    let width: Int
    let height: Int
}

enum VideoMediaError: LocalizedError {
    case missingVideoTrack
    case missingAudioTrack
    case cannotExtractAudio

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            "This file does not contain a readable video track."
        case .missingAudioTrack:
            "This video does not contain an audio track for Poet to edit."
        case .cannotExtractAudio:
            "Poet could not prepare this video's audio track."
        }
    }
}

enum SourceMediaInspector {
    static func kind(for url: URL) -> SourceMediaKind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .audio }
        return type.conforms(to: .movie) ? .video : .audio
    }

    static func inspectVideo(at url: URL) async throws -> VideoMediaInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoMediaError.missingVideoTrack
        }
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw VideoMediaError.missingAudioTrack
        }
        let duration = try await asset.load(.duration)
        let frameRate = Double(try await track.load(.nominalFrameRate))
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayedSize = naturalSize.applying(transform)
        return VideoMediaInfo(
            duration: max(0, duration.seconds),
            frameRate: frameRate > 0 ? frameRate : 30,
            width: Int(abs(displayedSize.width).rounded()),
            height: Int(abs(displayedSize.height).rounded())
        )
    }
}

enum VideoAudioExtractor {
    /// Produces one full-length, timing-aligned audio source for Poet's existing
    /// transcription and polish pipeline. No transcript edits are applied here.
    static func extractFullLengthAudio(from videoURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw VideoMediaError.missingAudioTrack
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw VideoMediaError.cannotExtractAudio
        }
        try? FileManager.default.removeItem(at: destinationURL)
        try await session.export(to: destinationURL, as: .m4a)
    }
}

enum EditedVideoRenderer {
    static func render(
        sourceVideoURL: URL,
        polishedAudioURL: URL,
        destinationURL: URL,
        keptRanges: [AudioTimeRange]
    ) async throws {
        guard !keptRanges.isEmpty else { throw AudioRenderError.emptyEdit }
        let videoAsset = AVURLAsset(url: sourceVideoURL)
        let audioAsset = AVURLAsset(url: polishedAudioURL)
        guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw VideoMediaError.missingVideoTrack
        }
        guard let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw VideoMediaError.missingAudioTrack
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoMediaError.cannotExtractAudio
        }
        videoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        var cursor = CMTime.zero
        for range in keptRanges {
            try Task.checkCancellation()
            let start = CMTime(seconds: range.start, preferredTimescale: 600)
            let duration = CMTime(seconds: max(0, range.end - range.start), preferredTimescale: 600)
            let sourceRange = CMTimeRange(start: start, duration: duration)
            try videoTrack.insertTimeRange(sourceRange, of: sourceVideoTrack, at: cursor)
            try audioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }

        try? FileManager.default.removeItem(at: destinationURL)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoMediaError.cannotExtractAudio
        }
        try await session.export(to: destinationURL, as: .mov)
    }
}
