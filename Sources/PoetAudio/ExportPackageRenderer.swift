import Foundation

struct ExportPackageRequest: Sendable {
    let folder: URL
    let baseName: String
    let sourceURL: URL?
    let words: [TranscriptWord]
    let duration: TimeInterval
    let renderOptions: AudioRenderOptions
    let includeAudio: Bool
    let includeTXT: Bool
    let includeSRT: Bool
    let includeVTT: Bool
}

enum ExportPackageRenderer {
    static func render(
        _ request: ExportPackageRequest,
        progress: PolishProgressHandler? = nil
    ) throws -> URL {
        let exportFolder = request.folder.appendingPathComponent("\(request.baseName) — Poet Export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)

        let ranges = AudioEditPlanner.keptRanges(
            words: request.words,
            duration: request.duration,
            maximumPause: request.renderOptions.maximumPause
        )
        let keptWords = request.words.filter { !$0.isRemoved }

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
            try VoicePolisher.render(
                sourceURL: editedURL,
                destinationURL: finishedURL,
                options: request.renderOptions,
                progress: progress
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
