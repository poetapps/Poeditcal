import Foundation

struct ExportPackageRequest: Sendable {
    let folder: URL
    let baseName: String
    let sourceURL: URL?
    let sourceVideoURL: URL?
    let videoInfo: VideoMediaInfo?
    let words: [TranscriptWord]
    let pauseDecisions: [PauseEditDecision]?
    let duration: TimeInterval
    let renderOptions: AudioRenderOptions
    let includeAudio: Bool
    let includeOriginal: Bool
    let includeTXT: Bool
    let includeSRT: Bool
    let includeVTT: Bool
    let includeEditableTimelines: Bool
    let includeFinishedVideo: Bool

    init(
        folder: URL,
        baseName: String,
        sourceURL: URL?,
        sourceVideoURL: URL? = nil,
        videoInfo: VideoMediaInfo? = nil,
        words: [TranscriptWord],
        pauseDecisions: [PauseEditDecision]? = nil,
        duration: TimeInterval,
        renderOptions: AudioRenderOptions,
        includeAudio: Bool,
        includeOriginal: Bool = false,
        includeTXT: Bool,
        includeSRT: Bool,
        includeVTT: Bool,
        includeEditableTimelines: Bool = false,
        includeFinishedVideo: Bool = false
    ) {
        self.folder = folder
        self.baseName = baseName
        self.sourceURL = sourceURL
        self.sourceVideoURL = sourceVideoURL
        self.videoInfo = videoInfo
        self.words = words
        self.pauseDecisions = pauseDecisions
        self.duration = duration
        self.renderOptions = renderOptions
        self.includeAudio = includeAudio
        self.includeOriginal = includeOriginal
        self.includeTXT = includeTXT
        self.includeSRT = includeSRT
        self.includeVTT = includeVTT
        self.includeEditableTimelines = includeEditableTimelines
        self.includeFinishedVideo = includeFinishedVideo
    }
}

enum ExportPackageRenderer {
    static func render(
        _ request: ExportPackageRequest,
        progress: PolishProgressHandler? = nil
    ) async throws -> URL {
        let exportFolder = request.folder.appendingPathComponent("\(request.baseName) — Poet Export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)

        let ranges = AudioEditPlanner.keptRanges(
            words: request.words,
            duration: request.duration,
            maximumPause: request.renderOptions.maximumPause,
            pauseDecisions: request.pauseDecisions
        )
        let keptWords = request.words.filter { !$0.isRemoved }

        if request.includeOriginal {
            guard let sourceURL = request.sourceVideoURL ?? request.sourceURL else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "Choose a real audio file before exporting the original recording."
                ])
            }
            let sourceExtension = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension.lowercased()
            let originalURL = exportFolder.appendingPathComponent(
                "\(request.baseName)-original.\(sourceExtension)"
            )
            try? FileManager.default.removeItem(at: originalURL)
            try FileManager.default.copyItem(at: sourceURL, to: originalURL)
        }

        if request.includeTXT {
            try keptWords.map(\.text).joined(separator: " ").write(
                to: exportFolder.appendingPathComponent("\(request.baseName).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        if request.includeSRT {
            try SubtitleRenderer.srt(words: keptWords, keptRanges: ranges).write(
                to: exportFolder.appendingPathComponent("\(request.baseName).srt"),
                atomically: true,
                encoding: .utf8
            )
        }
        if request.includeVTT {
            try SubtitleRenderer.vtt(words: keptWords, keptRanges: ranges).write(
                to: exportFolder.appendingPathComponent("\(request.baseName).vtt"),
                atomically: true,
                encoding: .utf8
            )
        }
        if request.includeAudio {
            guard let sourceURL = request.sourceURL else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "Choose a real audio file before exporting finished audio."
                ])
            }
            let tempFolder = FileManager.default.temporaryDirectory
                .appendingPathComponent("PoetRender-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempFolder) }

            let editedURL = tempFolder.appendingPathComponent("edited.wav")
            let finishedURL = exportFolder.appendingPathComponent("\(request.baseName)-finished.wav")
            try EditedAudioRenderer.render(sourceURL: sourceURL, destinationURL: editedURL, keptRanges: ranges)
            try await VoicePolisher.render(
                sourceURL: editedURL,
                destinationURL: finishedURL,
                options: request.renderOptions,
                progress: progress
            )
        }
        var fullLengthPolishedURL: URL?
        if request.includeEditableTimelines || request.includeFinishedVideo {
            guard let sourceAudioURL = request.sourceURL,
                  let sourceVideoURL = request.sourceVideoURL,
                  let videoInfo = request.videoInfo else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "An editable timeline requires the original video and its full-length audio."
                ])
            }
            // This is deliberately polished before any transcript cuts. Timeline
            // clips use source in/out points against the complete WAV, so editors
            // can extend either edge and recover audio that Poet initially hid.
            let fullSourceFolder = FileManager.default.temporaryDirectory
                .appendingPathComponent("PoetFullSource-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: fullSourceFolder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fullSourceFolder) }
            let fullSourceWAV = fullSourceFolder.appendingPathComponent("full-source.wav")
            try EditedAudioRenderer.render(
                sourceURL: sourceAudioURL,
                destinationURL: fullSourceWAV,
                keptRanges: [AudioTimeRange(start: 0, end: request.duration)]
            )
            let polishedFullURL = exportFolder.appendingPathComponent("\(request.baseName)-polished-full.wav")
            try await VoicePolisher.render(
                sourceURL: fullSourceWAV,
                destinationURL: polishedFullURL,
                options: request.renderOptions,
                progress: progress
            )
            fullLengthPolishedURL = polishedFullURL
            if request.includeEditableTimelines {
                let videoExtension = sourceVideoURL.pathExtension.isEmpty ? "mov" : sourceVideoURL.pathExtension.lowercased()
                let timelineVideoURL = exportFolder.appendingPathComponent("\(request.baseName)-source.\(videoExtension)")
                if sourceVideoURL.standardizedFileURL != timelineVideoURL.standardizedFileURL {
                    try? FileManager.default.removeItem(at: timelineVideoURL)
                    try FileManager.default.copyItem(at: sourceVideoURL, to: timelineVideoURL)
                }
                try EditableTimelineRenderer.render(
                    EditableTimelineRequest(
                        name: request.baseName,
                        videoURL: timelineVideoURL,
                        polishedAudioURL: polishedFullURL,
                        originalAudioURL: nil,
                        keptRanges: ranges,
                        sourceDuration: request.duration,
                        frameRate: videoInfo.frameRate,
                        width: videoInfo.width,
                        height: videoInfo.height
                    ),
                    to: exportFolder
                )
            }
        }
        if request.includeFinishedVideo {
            guard let sourceVideoURL = request.sourceVideoURL,
                  let fullLengthPolishedURL else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "A finished video requires the source video and polished audio."
                ])
            }
            try await EditedVideoRenderer.render(
                sourceVideoURL: sourceVideoURL,
                polishedAudioURL: fullLengthPolishedURL,
                destinationURL: exportFolder.appendingPathComponent("\(request.baseName)-finished.mov"),
                keptRanges: ranges
            )
        }
        return exportFolder
    }
}

enum SubtitleRenderer {
    static func srt(words: [TranscriptWord], keptRanges: [AudioTimeRange]) -> String {
        cues(words: words, keptRanges: keptRanges, separator: ",", numbered: true)
    }

    static func vtt(words: [TranscriptWord], keptRanges: [AudioTimeRange]) -> String {
        "WEBVTT\n\n" + cues(words: words, keptRanges: keptRanges, separator: ".", numbered: false)
    }

    private static func cues(
        words: [TranscriptWord],
        keptRanges: [AudioTimeRange],
        separator: Character,
        numbered: Bool
    ) -> String {
        words.chunked(into: 8).enumerated().map { index, chunk in
            let sourceStart = chunk.first?.startTime ?? 0
            let sourceEnd = chunk.last?.endTime ?? sourceStart
            let start = AudioEditPlanner.editedTime(for: sourceStart, keptRanges: keptRanges)
            let end = max(start + 0.04, AudioEditPlanner.editedTime(for: sourceEnd, keptRanges: keptRanges))
            let timing = "\(timestamp(start, separator: separator)) --> \(timestamp(end, separator: separator))"
            let text = chunk.map(\.text).joined(separator: " ")
            return numbered ? "\(index + 1)\n\(timing)\n\(text)" : "\(timing)\n\(text)"
        }.joined(separator: "\n\n")
    }

    private static func timestamp(_ value: TimeInterval, separator: Character) -> String {
        let millis = max(0, Int(value * 1000))
        let hours = millis / 3_600_000
        let minutes = (millis % 3_600_000) / 60_000
        let seconds = (millis % 60_000) / 1000
        let ms = millis % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, String(separator), ms)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
