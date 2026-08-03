import AVFoundation
import Foundation

struct BreathControlResult: Sendable, Equatable {
    let regions: [AudioTimeRange]
    var count: Int { regions.count }
    var totalDuration: TimeInterval { regions.reduce(0) { $0 + ($1.end - $1.start) } }
}

struct PolishQualityReport: Sendable, Equatable {
    let breathLiftDB: Double
    let dynamicRangeRetention: Double
    let analyzedBreaths: Int
    let passed: Bool
    let usedGentleCompression: Bool
    let bypassedCompression: Bool

    var summary: String {
        if passed {
            return analyzedBreaths > 0
                ? String(format: "Breaths balanced · dynamics %.0f%% preserved", dynamicRangeRetention * 100)
                : String(format: "Dynamics %.0f%% preserved · no prominent breaths found", dynamicRangeRetention * 100)
        }
        return String(format: "Breath lift %+.1f dB · dynamics %.0f%% preserved", breathLiftDB, dynamicRangeRetention * 100)
    }
}

struct PolishRenderReport: Sendable, Equatable {
    let loudness: LoudnessNormalizationResult?
    let quality: PolishQualityReport
    let breathControl: BreathControlResult?
    let deEssing: DeEssingResult?
}

struct AudioWindowSignature: Sendable {
    let range: AudioTimeRange
    let rmsDB: Double
    let derivativeRatio: Double
}

enum BreathDetector {
    static func regions(in url: URL) throws -> [AudioTimeRange] {
        let windows = try signatures(for: url)
        guard !windows.isEmpty else { return [] }
        let analysis = try AudioSignalAnalyzer.analyze(url: url)
        let quiet = windows.filter {
            $0.rmsDB > analysis.noiseFloorDB + 5 &&
            $0.rmsDB < analysis.speechLevelDB - 6
        }
        guard !quiet.isEmpty else { return [] }
        let spectralThreshold = percentile(quiet.map(\.derivativeRatio).sorted(), 0.58)
        let candidates = quiet
            .filter { $0.derivativeRatio >= max(0.34, spectralThreshold) }
            .map(\.range)
        return merge(candidates)
            .filter { $0.end - $0.start >= 0.035 && $0.end - $0.start <= 0.75 }
            .map { AudioTimeRange(start: max(0, $0.start - 0.015), end: $0.end + 0.02) }
    }

    static func signatures(for url: URL) throws -> [AudioWindowSignature] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 2_048
        var result: [AudioWindowSignature] = []

        while file.framePosition < file.length {
            let startFrame = file.framePosition
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
                  let channels = buffer.floatChannelData else {
                throw AudioRenderError.unsupportedPCMFormat
            }
            try file.read(into: buffer, frameCount: capacity)
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            let channelCount = Int(format.channelCount)
            var energy = 0.0
            var differenceEnergy = 0.0
            var previous: Float?
            for frame in 0..<frames {
                var mono: Float = 0
                for channel in 0..<channelCount { mono += channels[channel][frame] }
                mono /= Float(max(channelCount, 1))
                let value = Double(mono)
                energy += value * value
                if let previous {
                    let difference = Double(mono - previous)
                    differenceEnergy += difference * difference
                }
                previous = mono
            }
            let rms = sqrt(energy / Double(frames))
            let differenceRMS = sqrt(differenceEnergy / Double(max(frames - 1, 1)))
            let start = Double(startFrame) / format.sampleRate
            let end = Double(startFrame + AVAudioFramePosition(frames)) / format.sampleRate
            result.append(AudioWindowSignature(
                range: AudioTimeRange(start: start, end: end),
                rmsDB: decibels(rms),
                derivativeRatio: differenceRMS / max(rms, 0.000_001)
            ))
        }
        return result
    }

    private static func merge(_ ranges: [AudioTimeRange]) -> [AudioTimeRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [AudioTimeRange] = []
        for range in sorted {
            guard var last = merged.popLast() else {
                merged.append(range)
                continue
            }
            if range.start <= last.end + 0.055 {
                last.end = max(last.end, range.end)
                merged.append(last)
            } else {
                merged.append(last)
                merged.append(range)
            }
        }
        return merged
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)]
    }

    private static func decibels(_ amplitude: Double) -> Double {
        20 * log10(max(amplitude, 0.000_001))
    }
}

enum BreathController {
    static func process(
        dryReferenceURL: URL,
        sourceURL: URL,
        destinationURL: URL,
        attenuationDB: Double = -2.25
    ) throws -> BreathControlResult {
        let regions = try BreathDetector.regions(in: dryReferenceURL)
        let result = BreathControlResult(regions: regions)
        guard !regions.isEmpty else {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return result
        }

        let input = try AVAudioFile(forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        try? FileManager.default.removeItem(at: destinationURL)
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let targetGain = Float(pow(10, attenuationDB / 20))
        let fadeDuration = 0.025
        let capacity: AVAudioFrameCount = 8_192
        var regionIndex = 0

        while input.framePosition < input.length {
            let startFrame = input.framePosition
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
                  let channels = buffer.floatChannelData else {
                throw AudioRenderError.unsupportedPCMFormat
            }
            try input.read(into: buffer, frameCount: capacity)
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }

            for frame in 0..<frames {
                let time = Double(startFrame + AVAudioFramePosition(frame)) / format.sampleRate
                while regionIndex < regions.count && time > regions[regionIndex].end { regionIndex += 1 }
                guard regionIndex < regions.count else { continue }
                let region = regions[regionIndex]
                guard time >= region.start && time <= region.end else { continue }
                let fadeIn = min(max((time - region.start) / fadeDuration, 0), 1)
                let fadeOut = min(max((region.end - time) / fadeDuration, 0), 1)
                let mix = Float(min(fadeIn, fadeOut))
                let gain = 1 + (targetGain - 1) * mix
                for channel in 0..<Int(format.channelCount) { channels[channel][frame] *= gain }
            }
            try output.write(from: buffer)
        }
        return result
    }
}

enum PolishQualityAnalyzer {
    static func compare(
        dryURL: URL,
        polishedURL: URL,
        usedGentleCompression: Bool,
        bypassedCompression: Bool = false
    ) throws -> PolishQualityReport {
        let dryWindows = try BreathDetector.signatures(for: dryURL)
        let polishedWindows = try BreathDetector.signatures(for: polishedURL)
        let breathRegions = try BreathDetector.regions(in: dryURL)
        let dryAnalysis = try AudioSignalAnalyzer.analyze(url: dryURL)
        let polishedAnalysis = try AudioSignalAnalyzer.analyze(url: polishedURL)
        let count = min(dryWindows.count, polishedWindows.count)

        var breathGains: [Double] = []
        var speechGains: [Double] = []
        for index in 0..<count {
            let dry = dryWindows[index]
            let midpoint = (dry.range.start + dry.range.end) / 2
            let gain = polishedWindows[index].rmsDB - dry.rmsDB
            if breathRegions.contains(where: { midpoint >= $0.start && midpoint <= $0.end }) {
                breathGains.append(gain)
            } else if dry.rmsDB >= dryAnalysis.speechLevelDB - 4 {
                speechGains.append(gain)
            }
        }

        let breathLift = average(breathGains) - average(speechGains)
        let retention = min(max(polishedAnalysis.dynamicRangeDB / max(dryAnalysis.dynamicRangeDB, 0.5), 0), 2)
        let passed = breathLift <= 2.5 && retention >= 0.58
        return PolishQualityReport(
            breathLiftDB: breathGains.isEmpty ? 0 : breathLift,
            dynamicRangeRetention: retention,
            analyzedBreaths: breathRegions.count,
            passed: passed,
            usedGentleCompression: usedGentleCompression,
            bypassedCompression: bypassedCompression
        )
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
