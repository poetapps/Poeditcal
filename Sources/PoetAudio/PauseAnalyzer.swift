import AVFoundation
import Foundation

struct PauseEditDecision: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    let afterWordID: UUID?
    let beforeWordID: UUID?
    let confidence: Double
    let reason: String
    var isCompacted: Bool
    var isProtected: Bool

    var originalDuration: TimeInterval { max(0, sourceEnd - sourceStart) }

    init(
        id: UUID = UUID(),
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        afterWordID: UUID? = nil,
        beforeWordID: UUID? = nil,
        confidence: Double,
        reason: String,
        isCompacted: Bool = true,
        isProtected: Bool = false
    ) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.afterWordID = afterWordID
        self.beforeWordID = beforeWordID
        self.confidence = confidence
        self.reason = reason
        self.isCompacted = isCompacted
        self.isProtected = isProtected
    }
}

enum PauseAnalyzer {
    private static let windowDuration: TimeInterval = 0.02

    static func analyze(
        sourceURL: URL,
        words: [TranscriptWord],
        maximumPause: TimeInterval
    ) throws -> [PauseEditDecision] {
        let file = try AVAudioFile(
            forReading: sourceURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard file.length > 0,
              file.length <= AVAudioFramePosition(UInt32.max),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              ), let channels = buffer.floatChannelData else {
            throw AudioRenderError.unsupportedPCMFormat
        }
        try file.read(into: buffer)
        let frameCount = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var strongest: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                let sample = channels[channel][frame]
                if abs(sample) > abs(strongest) { strongest = sample }
            }
            mono[frame] = strongest
        }
        return analyze(
            samples: mono,
            sampleRate: buffer.format.sampleRate,
            words: words,
            maximumPause: maximumPause
        )
    }

    static func analyze(
        samples: [Float],
        sampleRate: Double,
        words: [TranscriptWord],
        maximumPause: TimeInterval
    ) -> [PauseEditDecision] {
        guard sampleRate > 0, !samples.isEmpty, words.count > 1 else { return [] }
        let levels = windowLevels(samples: samples, sampleRate: sampleRate)
        guard !levels.isEmpty else { return [] }
        let sortedLevels = levels.sorted()
        let noiseFloor = percentile(sortedLevels, 0.18)
        let speechLevel = percentile(sortedLevels, 0.88)
        guard speechLevel > noiseFloor + 4 else { return [] }
        let activityGate = noiseFloor + min(12, max(6, (speechLevel - noiseFloor) * 0.36))
        let sortedWords = words.sorted { $0.startTime < $1.startTime }
        let cappedPause = max(0, maximumPause)

        return zip(sortedWords, sortedWords.dropFirst()).compactMap { previous, next in
            let gapStart = max(0, previous.endTime)
            let gapEnd = max(gapStart, next.startTime)
            let gap = gapEnd - gapStart
            guard gap > cappedPause + 0.08 else { return nil }

            let firstWindow = max(0, min(levels.count, Int(floor(gapStart / windowDuration))))
            let endWindow = max(firstWindow, min(levels.count, Int(ceil(gapEnd / windowDuration))))
            let gapLevels = Array(levels[firstWindow..<endWindow])
            guard !gapLevels.isEmpty else { return nil }
            let quietCount = gapLevels.count(where: { $0 <= activityGate })
            let quietFraction = Double(quietCount) / Double(gapLevels.count)

            var longestActiveRun = 0
            var activeRun = 0
            for level in gapLevels {
                if level > activityGate {
                    activeRun += 1
                    longestActiveRun = max(longestActiveRun, activeRun)
                } else {
                    activeRun = 0
                }
            }
            let activeRunDuration = Double(longestActiveRun) * windowDuration

            // A transcript gap is only eligible when the waveform independently
            // confirms that it is overwhelmingly nonspeech. This protects missed
            // words, laughter, music, and other meaningful untranscribed events.
            guard quietFraction >= 0.82, activeRunDuration <= 0.14 else { return nil }
            let punctuationBoundary = previous.text.hasSuffix(".") ||
                previous.text.hasSuffix("?") || previous.text.hasSuffix("!")
            let confidence = min(0.99, max(0.5, quietFraction - activeRunDuration * 0.35))
            return PauseEditDecision(
                sourceStart: gapStart,
                sourceEnd: gapEnd,
                afterWordID: previous.id,
                beforeWordID: next.id,
                confidence: confidence,
                reason: punctuationBoundary ? "Confirmed sentence pause" : "Confirmed silent pause"
            )
        }
    }

    private static func windowLevels(samples: [Float], sampleRate: Double) -> [Double] {
        let size = max(1, Int(sampleRate * windowDuration))
        var result: [Double] = []
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + size)
            var energy = 0.0
            for sample in samples[offset..<end] {
                energy += Double(sample) * Double(sample)
            }
            let rms = sqrt(energy / Double(max(end - offset, 1)))
            result.append(20 * log10(max(rms, 0.000_001)))
            offset = end
        }
        return result
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return -120 }
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }
}
