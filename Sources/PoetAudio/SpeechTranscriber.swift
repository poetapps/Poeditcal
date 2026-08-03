import AVFoundation
import FluidAudio
import Foundation

struct TranscribedToken: Sendable {
    let text: String
    let startTime: TimeInterval
    let duration: TimeInterval
    let confidence: Float
}

enum TranscriptionError: LocalizedError {
    case modelUnavailable(String)
    case unsupportedAudio
    case noSpeechFound

    var errorDescription: String? {
        switch self {
        case let .modelUnavailable(details):
            "Poet Audio couldn’t prepare its local Parakeet model. Check your connection for the first download, then try again.\n\n\(details)"
        case .unsupportedAudio:
            "Poet Audio couldn’t prepare this recording for transcription."
        case .noSpeechFound:
            "No spoken words were found in this recording."
        }
    }
}

/// Local, permission-free speech recognition powered by Parakeet TDT/Core ML.
/// The English v2 model is downloaded once by FluidAudio and then reused offline.
@MainActor
final class LocalSpeechTranscriber {
    private var manager: AsrManager?

    func transcribe(
        url: URL,
        progress: @escaping @MainActor @Sendable (_ fraction: Double, _ label: String) -> Void
    ) async throws -> [TranscribedToken] {
        try Task.checkCancellation()
        progress(0.04, manager == nil ? "Preparing local Parakeet" : "Loading your recording")

        let asr: AsrManager
        if let manager {
            asr = manager
        } else {
            do {
                let models = try await AsrModels.downloadAndLoad(version: .v2) { download in
                    Task { @MainActor in
                        progress(
                            0.08 + download.fractionCompleted * 0.32,
                            Self.downloadLabel(for: download.phase)
                        )
                    }
                }
                let loaded = AsrManager(config: .default)
                try await loaded.loadModels(models)
                manager = loaded
                asr = loaded
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TranscriptionError.modelUnavailable(error.localizedDescription)
            }
        }

        try Task.checkCancellation()
        progress(0.44, "Loading your recording")
        let samples = try await Task.detached(priority: .userInitiated) {
            try Self.load16kMonoAudio(from: url)
        }.value

        try Task.checkCancellation()
        progress(0.52, "Transcribing every word")
        var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &decoderState)
        try Task.checkCancellation()
        progress(0.88, "Looking for retakes and fillers")

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        let rawTokens = words.compactMap { word -> TranscribedToken? in
            let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = max(0, word.startTime)
            let end = max(start + 0.02, word.endTime)
            return TranscribedToken(
                text: text,
                startTime: start,
                duration: end - start,
                confidence: result.confidence
            )
        }
        let tokens = SpeechTimingRefiner.refine(rawTokens, samples: samples, sampleRate: 16_000)

        guard !tokens.isEmpty else { throw TranscriptionError.noSpeechFound }
        return tokens
    }

    func cancel() {
        // The surrounding structured-concurrency task is cancelled by AppModel.
    }

    nonisolated private static func downloadLabel(for phase: DownloadPhase) -> String {
        switch phase {
        case .listing:
            "Finding local Parakeet"
        case let .downloading(completedFiles, totalFiles):
            "Downloading Parakeet · \(completedFiles)/\(totalFiles) files"
        case .compiling:
            "Optimizing Parakeet for this Mac"
        }
    }

    /// AVAudioFile successfully decodes Voice Memo ALAC files that FluidAudio's
    /// convenience URL reader currently rejects. Parakeet expects mono Float32 at 16 kHz.
    nonisolated private static func load16kMonoAudio(from url: URL) throws -> [Float] {
        let source = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let sourceFormat = source.processingFormat
        guard source.length > 0,
              source.length <= AVAudioFramePosition(UInt32.max),
              let input = AVAudioPCMBuffer(
                  pcmFormat: sourceFormat,
                  frameCapacity: AVAudioFrameCount(source.length)
              ) else {
            throw TranscriptionError.unsupportedAudio
        }
        try source.read(into: input)

        let prepared: AVAudioPCMBuffer
        if abs(sourceFormat.sampleRate - 16_000) < 1,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           !sourceFormat.isInterleaved {
            prepared = input
        } else {
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ), let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
                throw TranscriptionError.unsupportedAudio
            }

            let ratio = 16_000 / sourceFormat.sampleRate
            let estimatedFrames = Int(ceil(Double(input.frameLength) * ratio)) + 512
            guard estimatedFrames > 0,
                  estimatedFrames <= Int(UInt32.max),
                  let converted = AVAudioPCMBuffer(
                      pcmFormat: outputFormat,
                      frameCapacity: AVAudioFrameCount(estimatedFrames)
                  ) else {
                throw TranscriptionError.unsupportedAudio
            }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, converted.frameLength > 0 else {
                throw TranscriptionError.unsupportedAudio
            }
            prepared = converted
        }

        guard let channel = prepared.floatChannelData?.pointee else {
            throw TranscriptionError.unsupportedAudio
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(prepared.frameLength)))
    }
}

/// Parakeet's TDT duration advances the decoder through blank frames, so a
/// token's nominal end can include the pause after the spoken word. Recover a
/// conservative acoustic word end from the already-loaded waveform. These
/// refined ends make pause compaction measure actual word-end to word-start
/// time instead of decoder-emission time.
enum SpeechTimingRefiner {
    private static let windowDuration: TimeInterval = 0.02

    private struct Window {
        let start: TimeInterval
        let end: TimeInterval
        let rmsDB: Double
        let derivativeRatio: Double
    }

    static func refine(
        _ tokens: [TranscribedToken],
        samples: [Float],
        sampleRate: Double
    ) -> [TranscribedToken] {
        guard tokens.count > 1, !samples.isEmpty, sampleRate > 0 else { return tokens }
        let windows = analyze(samples: samples, sampleRate: sampleRate)
        guard !windows.isEmpty else { return tokens }

        let levels = windows.map(\.rmsDB).sorted()
        let noiseFloor = percentile(levels, 0.15)
        let speechLevel = percentile(levels, 0.78)
        guard speechLevel > noiseFloor + 4 else { return tokens }

        return tokens.enumerated().map { index, token in
            guard index + 1 < tokens.count else { return token }
            let nextStart = tokens[index + 1].startTime
            guard nextStart > token.startTime + 0.04 else { return token }

            let firstWindow = min(
                windows.count,
                max(0, Int(floor(token.startTime / windowDuration)))
            )
            let windowAfterInterval = min(
                windows.count,
                max(firstWindow, Int(ceil(nextStart / windowDuration)))
            )
            let candidates = windows[firstWindow..<windowAfterInterval]
            let activityGate = noiseFloor + min(10, max(5, (speechLevel - noiseFloor) * 0.38))
            let breathCeiling = speechLevel - 5
            let lastSpeechEnd = candidates.last(where: { window in
                let breathLike = window.rmsDB < breathCeiling && window.derivativeRatio >= 0.55
                return window.rmsDB >= activityGate && !breathLike
            })?.end

            guard let lastSpeechEnd else { return token }
            // Preserve consonant releases and timestamp quantization at the word
            // edge, but never let that safety tail enter the next word.
            let acousticEnd = min(nextStart, max(token.startTime + 0.04, lastSpeechEnd + 0.04))
            return TranscribedToken(
                text: token.text,
                startTime: token.startTime,
                duration: acousticEnd - token.startTime,
                confidence: token.confidence
            )
        }
    }

    private static func analyze(samples: [Float], sampleRate: Double) -> [Window] {
        let windowSize = max(1, Int(sampleRate * windowDuration))
        var result: [Window] = []
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + windowSize)
            var energy = 0.0
            var differenceEnergy = 0.0
            var previous: Float?
            for index in offset..<end {
                let sample = samples[index]
                let value = Double(sample)
                energy += value * value
                if let previous {
                    let difference = Double(sample - previous)
                    differenceEnergy += difference * difference
                }
                previous = sample
            }
            let count = max(end - offset, 1)
            let rms = sqrt(energy / Double(count))
            let derivativeRMS = sqrt(differenceEnergy / Double(max(count - 1, 1)))
            result.append(Window(
                start: Double(offset) / sampleRate,
                end: Double(end) / sampleRate,
                rmsDB: 20 * log10(max(rms, 0.000_001)),
                derivativeRatio: derivativeRMS / max(rms, 0.000_001)
            ))
            offset = end
        }
        return result
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)
        return sorted[index]
    }
}
