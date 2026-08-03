import AVFoundation
import Foundation

struct DeEssingResult: Sendable, Equatable {
    let regions: [AudioTimeRange]
    let detectedFrequencyHz: Double
    let averageReductionDB: Double
    let peakReductionDB: Double
    let ordinaryVoiceChangeDB: Double
    let passedPostAnalysis: Bool

    var count: Int { regions.count }
}

/// Offline, program-dependent split-band de-essing for spoken voice.
///
/// The first pass finds short windows whose high-frequency energy rises well
/// above that recording's normal high/mid balance. The second pass smoothly
/// turns down only the high-band component during those windows. Ordinary
/// brightness is therefore left alone instead of receiving a permanent EQ cut.
enum AdaptiveDeEsser {
    private struct Window {
        let range: AudioTimeRange
        let levelDB: Double
        let highDB: Double
        let ratioDB: Double
        let bandEnergy: [Double]
        var reductionDB: Double = 0
    }

    private static let windowDuration = 0.010
    static func process(
        sourceURL: URL,
        destinationURL: URL,
        intensity: Double = 1
    ) throws -> DeEssingResult {
        let analysis = try AudioSignalAnalyzer.analyze(url: sourceURL)
        var windows = try analyzeWindows(url: sourceURL)
        guard !windows.isEmpty else { throw AudioRenderError.renderFailed }

        // Some recordings have no true pauses. In that case the low percentile
        // called "noise floor" is still voiced audio, so also anchor activity to
        // the measured speech level rather than requiring a fixed 7 dB gap.
        let activityGate = min(analysis.noiseFloorDB + 7, analysis.speechLevelDB - 10)
        let active = windows.filter { $0.levelDB >= activityGate }
        guard active.count >= 3 else {
            try copy(sourceURL, to: destinationURL)
            return bypassResult()
        }

        let ratios = active.map(\.ratioDB).sorted()
        let highLevels = active.map(\.highDB).sorted()
        // A file-relative threshold prevents constant fan hiss or an unusually
        // bright microphone from being mistaken for every S in the recording.
        let ratioThreshold = min(max(percentile(ratios, 0.72), -11.0), -2.5)
        let highGate = percentile(highLevels, 0.58)

        for index in windows.indices {
            let window = windows[index]
            guard window.levelDB >= activityGate,
                  window.highDB >= highGate,
                  window.ratioDB > ratioThreshold else { continue }
            let spectralStrength = min(max((window.ratioDB - ratioThreshold) / 8.0, 0), 1)
            let levelStrength = min(max((window.highDB - highGate) / 8.0, 0), 1)
            let strength = sqrt(spectralStrength * levelStrength)
            let maximumReductionDB = 5.25 * min(max(intensity, 0.15), 1)
            windows[index].reductionDB = -maximumReductionDB * strength
        }

        suppressImplausibleRuns(in: &windows)
        let activeWindows = windows.filter { $0.reductionDB < -0.35 }
        guard !activeWindows.isEmpty else {
            try copy(sourceURL, to: destinationURL)
            return bypassResult()
        }

        let frequency = dominantSibilanceFrequency(in: activeWindows)
        try render(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            windows: windows,
            crossoverFrequency: crossoverFrequency(for: frequency)
        )

        // Verify the rendered signal rather than trusting the requested gain.
        // Windows well away from a detected consonant provide the preservation
        // control: their broadband level should remain effectively unchanged.
        let renderedWindows = try analyzeWindows(url: destinationURL)
        let activeIndices = windows.indices.filter { windows[$0].reductionDB < -0.35 }
        let reductions = activeIndices.compactMap { index -> Double? in
            guard index < renderedWindows.count else { return nil }
            return max(0, windows[index].highDB - renderedWindows[index].highDB)
        }
        let protectedIndices = windows.indices.filter { index in
            guard windows[index].levelDB >= activityGate else { return false }
            let lower = max(0, index - 10)
            let upper = min(windows.count - 1, index + 10)
            return !windows[lower...upper].contains { $0.reductionDB < -0.35 }
        }
        let voiceChanges = protectedIndices.compactMap { index -> Double? in
            guard index < renderedWindows.count else { return nil }
            return renderedWindows[index].levelDB - windows[index].levelDB
        }
        let averageReduction = average(reductions)
        let voiceChange = average(voiceChanges)
        return DeEssingResult(
            regions: merge(activeWindows.map(\.range)),
            detectedFrequencyHz: frequency,
            averageReductionDB: averageReduction,
            peakReductionDB: reductions.max() ?? 0,
            ordinaryVoiceChangeDB: voiceChange,
            passedPostAnalysis: averageReduction >= 0.5 && abs(voiceChange) <= 0.35
        )
    }

    private static func analyzeWindows(url: URL) throws -> [Window] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let windowFrames = max(Int(format.sampleRate * windowDuration), 64)
        let boundaries = [250.0, 4_000, 5_500, 7_000, 9_000, min(12_000, format.sampleRate * 0.46)]
        var filters = boundaries.map { OnePoleLowPass(sampleRate: format.sampleRate, frequency: $0) }
        var result: [Window] = []
        var startFrame: AVAudioFramePosition = 0

        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(windowFrames)
            ), let channels = buffer.floatChannelData else {
                throw AudioRenderError.unsupportedPCMFormat
            }
            try file.read(into: buffer, frameCount: AVAudioFrameCount(windowFrames))
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            var totalEnergy = 0.0
            var highEnergy = 0.0
            var midEnergy = 0.0
            var bandEnergy = Array(repeating: 0.0, count: 4)

            for frame in 0..<frameCount {
                var mono = 0.0
                for channel in 0..<Int(format.channelCount) {
                    mono += Double(channels[channel][frame])
                }
                mono /= Double(max(Int(format.channelCount), 1))
                let lows = filters.indices.map { filters[$0].process(mono) }
                let mid = lows[1] - lows[0]
                let high = mono - lows[1]
                totalEnergy += mono * mono
                midEnergy += mid * mid
                highEnergy += high * high
                for band in 0..<4 {
                    let value = lows[band + 2] - lows[band + 1]
                    bandEnergy[band] += value * value
                }
            }

            let start = Double(startFrame) / format.sampleRate
            let end = Double(startFrame + AVAudioFramePosition(frameCount)) / format.sampleRate
            let fullRMS = sqrt(totalEnergy / Double(frameCount))
            let highRMS = sqrt(highEnergy / Double(frameCount))
            let midRMS = sqrt(midEnergy / Double(frameCount))
            result.append(Window(
                range: AudioTimeRange(start: start, end: end),
                levelDB: decibels(fullRMS),
                highDB: decibels(highRMS),
                ratioDB: decibels(highRMS) - decibels(midRMS),
                bandEnergy: bandEnergy
            ))
            startFrame += AVAudioFramePosition(frameCount)
        }
        return result
    }

    private static func suppressImplausibleRuns(in windows: inout [Window]) {
        var start: Int?
        for index in 0...windows.count {
            let active = index < windows.count && windows[index].reductionDB < -0.35
            if active, start == nil { start = index }
            guard !active, let runStart = start else { continue }
            let count = index - runStart
            // Single-window spikes are usually clicks. Long, stationary runs are
            // more likely hiss or general brightness than a spoken consonant.
            if count < 2 || count > 42 {
                for runIndex in runStart..<index { windows[runIndex].reductionDB = 0 }
            }
            start = nil
        }
    }

    private static func dominantSibilanceFrequency(in windows: [Window]) -> Double {
        let centers = [4_750.0, 6_250, 8_000, 10_500]
        let bandwidths = [1_500.0, 1_500, 2_000, 3_000]
        var energies = Array(repeating: 0.0, count: centers.count)
        for window in windows {
            let weight = abs(window.reductionDB)
            for band in energies.indices {
                energies[band] += window.bandEnergy[band] * weight / bandwidths[band]
            }
        }
        let strongest = energies.indices.max(by: { energies[$0] < energies[$1] }) ?? 1
        return centers[strongest]
    }

    private static func crossoverFrequency(for detectedFrequency: Double) -> Double {
        switch detectedFrequency {
        case ..<5_500: 4_000
        case ..<7_000: 4_800
        case ..<9_500: 5_800
        default: 7_200
        }
    }

    private static func render(
        sourceURL: URL,
        destinationURL: URL,
        windows: [Window],
        crossoverFrequency: Double
    ) throws {
        let input = try AVAudioFile(forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        try? FileManager.default.removeItem(at: destinationURL)
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        var crossovers = (0..<Int(format.channelCount)).map { _ in
            OnePoleLowPass(sampleRate: format.sampleRate, frequency: crossoverFrequency)
        }
        let attack = smoothingCoefficient(milliseconds: 1.5, sampleRate: format.sampleRate)
        let release = smoothingCoefficient(milliseconds: 65, sampleRate: format.sampleRate)
        let windowFrames = max(Int(format.sampleRate * windowDuration), 64)
        let capacity: AVAudioFrameCount = 8_192
        var renderedFrames = 0
        var gain = 1.0

        while input.framePosition < input.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
                  let channels = buffer.floatChannelData else {
                throw AudioRenderError.unsupportedPCMFormat
            }
            try input.read(into: buffer, frameCount: capacity)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            for frame in 0..<frameCount {
                let absoluteFrame = renderedFrames + frame
                let windowIndex = min(absoluteFrame / windowFrames, windows.count - 1)
                let targetGain = pow(10, windows[windowIndex].reductionDB / 20)
                let coefficient = targetGain < gain ? attack : release
                gain = targetGain + coefficient * (gain - targetGain)
                for channel in 0..<Int(format.channelCount) {
                    let dry = Double(channels[channel][frame])
                    let low = crossovers[channel].process(dry)
                    let high = dry - low
                    channels[channel][frame] = Float(low + high * gain)
                }
            }
            try output.write(from: buffer)
            renderedFrames += frameCount
        }
    }

    private static func merge(_ ranges: [AudioTimeRange]) -> [AudioTimeRange] {
        var merged: [AudioTimeRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            guard var previous = merged.popLast() else {
                merged.append(range)
                continue
            }
            if range.start <= previous.end + windowDuration * 1.5 {
                previous.end = max(previous.end, range.end)
                merged.append(previous)
            } else {
                merged.append(previous)
                merged.append(range)
            }
        }
        return merged
    }

    private static func copy(_ source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func bypassResult() -> DeEssingResult {
        DeEssingResult(
            regions: [],
            detectedFrequencyHz: 6_500,
            averageReductionDB: 0,
            peakReductionDB: 0,
            ordinaryVoiceChangeDB: 0,
            passedPostAnalysis: true
        )
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func smoothingCoefficient(milliseconds: Double, sampleRate: Double) -> Double {
        exp(-1 / (sampleRate * milliseconds / 1_000))
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)]
    }

    private static func decibels(_ amplitude: Double) -> Double {
        20 * log10(max(amplitude, 0.000_001))
    }
}

private struct OnePoleLowPass {
    private let coefficient: Double
    private var state = 0.0

    init(sampleRate: Double, frequency: Double) {
        coefficient = 1 - exp(-2 * Double.pi * min(frequency, sampleRate * 0.48) / sampleRate)
    }

    mutating func process(_ input: Double) -> Double {
        state += coefficient * (input - state)
        return state
    }
}
