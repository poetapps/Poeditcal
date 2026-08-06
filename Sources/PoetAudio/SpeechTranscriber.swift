import AVFoundation
import FluidAudio
import Foundation
import os

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

    func prepare(
        progress: @escaping @MainActor @Sendable (_ fraction: Double, _ label: String) -> Void
    ) async throws {
        _ = try await preparedManager(progress: progress)
    }

    func transcribe(
        url: URL,
        progress: @escaping @MainActor @Sendable (_ fraction: Double, _ label: String) -> Void
    ) async throws -> [TranscribedToken] {
        try Task.checkCancellation()
        progress(0.04, manager == nil ? "Preparing local Parakeet" : "Loading your recording")

        let asr = try await preparedManager(progress: progress)

        try Task.checkCancellation()
        progress(0.44, "Preparing your recording")
        let preparedFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetTranscription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: preparedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: preparedFolder) }
        let preparedURL = preparedFolder.appendingPathComponent("prepared-16k-mono.wav")
        try await Task.detached(priority: .userInitiated) {
            try Self.prepare16kMonoAudio(from: url, destinationURL: preparedURL)
        }.value

        try Task.checkCancellation()
        progress(0.52, "Transcribing every word")
        var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        // FluidAudio automatically selects its constant-memory, four-worker
        // disk-backed path for long files. Supplying a canonical WAV also keeps
        // Voice Memo ALAC decoding under AVFoundation's reliable reader.
        let result = try await asr.transcribe(preparedURL, decoderState: &decoderState)
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
        let tokens = try await Task.detached(priority: .userInitiated) {
            try SpeechTimingRefiner.refine(rawTokens, audioURL: preparedURL)
        }.value

        guard !tokens.isEmpty else { throw TranscriptionError.noSpeechFound }
        return tokens
    }

    private func preparedManager(
        progress: @escaping @MainActor @Sendable (_ fraction: Double, _ label: String) -> Void
    ) async throws -> AsrManager {
        if let manager {
            return manager
        }
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
            return loaded
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
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

    /// Stream-decodes through AVFoundation so even hour-long Voice Memo ALAC
    /// recordings stay at constant memory. Parakeet expects mono Float32 at 16 kHz.
    nonisolated private static func prepare16kMonoAudio(
        from url: URL,
        destinationURL: URL
    ) throws {
        let source = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let sourceFormat = source.processingFormat
        guard source.length > 0 else {
            throw TranscriptionError.unsupportedAudio
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw TranscriptionError.unsupportedAudio
        }

        try? FileManager.default.removeItem(at: destinationURL)
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let inputCapacity: AVAudioFrameCount = 16_384
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(inputCapacity) * outputFormat.sampleRate / sourceFormat.sampleRate) + 512
        )
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputCapacity),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw TranscriptionError.unsupportedAudio
        }

        nonisolated(unsafe) let capturedInput = inputBuffer
        let reachedEnd = OSAllocatedUnfairLock(initialState: false)
        let readError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if reachedEnd.withLock({ $0 }) {
                status.pointee = .endOfStream
                return nil
            }
            do {
                let remaining = max(0, source.length - source.framePosition)
                let count = AVAudioFrameCount(min(AVAudioFramePosition(inputCapacity), remaining))
                if count > 0 {
                    try source.read(into: capturedInput, frameCount: count)
                } else {
                    capturedInput.frameLength = 0
                }
            } catch {
                readError.withLock { $0 = error }
                capturedInput.frameLength = 0
            }
            guard capturedInput.frameLength > 0 else {
                reachedEnd.withLock { $0 = true }
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return capturedInput
        }

        while true {
            try Task.checkCancellation()
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
            if let readError = readError.withLock({ $0 }) { throw readError }
            guard status != .error, conversionError == nil else {
                throw conversionError ?? TranscriptionError.unsupportedAudio
            }
            if outputBuffer.frameLength > 0 { try output.write(from: outputBuffer) }
            if status == .endOfStream { break }
        }
        guard output.length > 0 else { throw TranscriptionError.unsupportedAudio }
    }
}

/// The cleaned analysis pass can occasionally make a quiet hesitation less
/// salient to ASR. Keep its generally clearer transcript, then merge only the
/// high-value disfluency tokens recovered from a second pass over the untouched
/// recording. Timeline proximity prevents ordinary duplicate words.
enum TranscriptionMerger {
    private static let hesitationWords: Set<String> = [
        "um", "umm", "uh", "uhh", "erm", "er", "hmm"
    ]

    static func recoverHesitations(
        primary: [TranscribedToken],
        original: [TranscribedToken]
    ) -> [TranscribedToken] {
        guard !primary.isEmpty, !original.isEmpty else { return primary }
        var merged = primary

        for candidate in original where hesitationWords.contains(normalize(candidate.text)) {
            let midpoint = candidate.startTime + candidate.duration / 2
            let alreadyPresent = merged.contains { token in
                hesitationWords.contains(normalize(token.text)) &&
                    abs(token.startTime - candidate.startTime) <= 0.32
            }
            guard !alreadyPresent else { continue }

            // Do not insert a hesitation on top of a confidently timestamped
            // primary word. Genuine missing fillers normally occupy an exposed
            // gap between neighboring primary tokens.
            let collidesWithPrimaryWord = merged.contains { token in
                !hesitationWords.contains(normalize(token.text)) &&
                    midpoint >= token.startTime + 0.03 &&
                    midpoint <= token.startTime + token.duration - 0.03
            }
            guard !collidesWithPrimaryWord else { continue }
            merged.append(candidate)
        }

        return merged.sorted {
            if abs($0.startTime - $1.startTime) < 0.001 {
                return $0.duration < $1.duration
            }
            return $0.startTime < $1.startTime
        }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(
            in: .punctuationCharacters.union(.whitespacesAndNewlines)
        )
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
        guard !tokens.isEmpty, !samples.isEmpty, sampleRate > 0 else { return tokens }
        let windows = analyze(samples: samples, sampleRate: sampleRate)
        return refine(tokens, windows: windows, duration: Double(samples.count) / sampleRate)
    }

    static func refine(
        _ tokens: [TranscribedToken],
        audioURL: URL
    ) throws -> [TranscribedToken] {
        guard !tokens.isEmpty else { return tokens }
        let file = try AVAudioFile(
            forReading: audioURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.processingFormat.channelCount == 1 else { return tokens }
        let windows = try analyze(file: file)
        return refine(
            tokens,
            windows: windows,
            duration: Double(file.length) / sampleRate
        )
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

    private static func analyze(file: AVAudioFile) throws -> [Window] {
        let sampleRate = file.processingFormat.sampleRate
        let windowSize = max(1, Int(sampleRate * windowDuration))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(windowSize)
        ) else { throw TranscriptionError.unsupportedAudio }
        var result: [Window] = []
        result.reserveCapacity(Int(ceil(Double(file.length) / Double(windowSize))))
        var offset: AVAudioFramePosition = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(windowSize))
            let count = Int(buffer.frameLength)
            guard count > 0, let samples = buffer.floatChannelData?.pointee else { break }
            var energy = 0.0
            var differenceEnergy = 0.0
            var previous: Float?
            for index in 0..<count {
                let sample = samples[index]
                energy += Double(sample) * Double(sample)
                if let previous {
                    let difference = Double(sample - previous)
                    differenceEnergy += difference * difference
                }
                previous = sample
            }
            let rms = sqrt(energy / Double(count))
            let derivativeRMS = sqrt(differenceEnergy / Double(max(count - 1, 1)))
            result.append(Window(
                start: Double(offset) / sampleRate,
                end: Double(offset + AVAudioFramePosition(count)) / sampleRate,
                rmsDB: 20 * log10(max(rms, 0.000_001)),
                derivativeRatio: derivativeRMS / max(rms, 0.000_001)
            ))
            offset += AVAudioFramePosition(count)
        }
        return result
    }

    private static func refine(
        _ tokens: [TranscribedToken],
        windows: [Window],
        duration: TimeInterval
    ) -> [TranscribedToken] {
        guard !tokens.isEmpty, !windows.isEmpty else { return tokens }
        let levels = windows.map(\.rmsDB).sorted()
        let noiseFloor = percentile(levels, 0.15)
        let speechLevel = percentile(levels, 0.78)
        guard speechLevel > noiseFloor + 4 else { return tokens }

        return tokens.enumerated().map { index, token in
            let intervalEnd = index + 1 < tokens.count
                ? tokens[index + 1].startTime
                : min(duration, token.startTime + token.duration)
            guard intervalEnd > token.startTime + 0.04 else { return token }
            let firstWindow = min(windows.count, max(0, Int(floor(token.startTime / windowDuration))))
            let windowAfterInterval = min(
                windows.count,
                max(firstWindow, Int(ceil(intervalEnd / windowDuration)))
            )
            let candidates = windows[firstWindow..<windowAfterInterval]
            let activityGate = noiseFloor + min(10, max(5, (speechLevel - noiseFloor) * 0.38))
            let breathCeiling = speechLevel - 5
            let lastSpeechEnd = candidates.last(where: { window in
                let breathLike = window.rmsDB < breathCeiling && window.derivativeRatio >= 0.55
                return window.rmsDB >= activityGate && !breathLike
            })?.end
            guard let lastSpeechEnd else { return token }
            let acousticEnd = min(intervalEnd, max(token.startTime + 0.04, lastSpeechEnd + 0.04))
            return TranscribedToken(
                text: token.text,
                startTime: token.startTime,
                duration: acousticEnd - token.startTime,
                confidence: token.confidence
            )
        }
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)
        return sorted[index]
    }
}
