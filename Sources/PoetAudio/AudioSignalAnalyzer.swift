import AVFoundation
import Foundation

struct VoiceAnalysis: Sendable, Equatable {
    let noiseFloorDB: Double
    let speechLevelDB: Double
    let dynamicRangeDB: Double
    let sibilanceScore: Double
    let presenceScore: Double

    static let sample = VoiceAnalysis(
        noiseFloorDB: -48,
        speechLevelDB: -20,
        dynamicRangeDB: 13,
        sibilanceScore: 0.44,
        presenceScore: 0.52
    )

    var backgroundScore: Double { normalized(noiseFloorDB, from: -65 ... -25) }
    var dynamicsScore: Double { normalized(dynamicRangeDB, from: 4 ... 24) }

    var backgroundDescription: String {
        switch noiseFloorDB {
        case ..<(-55): "Very quiet"
        case ..<(-45): "Low room tone"
        case ..<(-35): "Noticeable noise"
        default: "Strong background"
        }
    }

    var sibilanceDescription: String {
        switch sibilanceScore {
        case ..<0.32: "Soft"
        case ..<0.62: "Occasional"
        default: "Pronounced"
        }
    }

    var dynamicsDescription: String {
        switch dynamicRangeDB {
        case ..<8: "Even"
        case ..<17: "Moderate"
        default: "Wide"
        }
    }

    var presenceDescription: String {
        switch presenceScore {
        case ..<0.36: "Warm"
        case ..<0.66: "Balanced"
        default: "Bright"
        }
    }

    private func normalized(_ value: Double, from range: ClosedRange<Double>) -> Double {
        min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }
}

enum AudioSignalAnalyzer {
    static func analyze(url: URL) throws -> VoiceAnalysis {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 2_048
        var levels: [Double] = []
        var globalPeak: Float = 0
        var sampleEnergy = 0.0
        var differenceEnergy = 0.0
        var previous: Float?
        var energySamples = 0

        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw AudioRenderError.unsupportedPCMFormat
            }
            try file.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }

            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(format.channelCount)
            var windowEnergy = 0.0
            for frame in 0..<frameCount {
                var mono: Float = 0
                for channel in 0..<channelCount { mono += channels[channel][frame] }
                mono /= Float(max(channelCount, 1))
                globalPeak = max(globalPeak, abs(mono))
                let value = Double(mono)
                windowEnergy += value * value
                sampleEnergy += value * value
                if let previous {
                    let difference = Double(mono - previous)
                    differenceEnergy += difference * difference
                }
                previous = mono
                energySamples += 1
            }
            let rms = sqrt(windowEnergy / Double(max(frameCount, 1)))
            levels.append(decibels(rms))
        }

        guard !levels.isEmpty, energySamples > 0 else { throw AudioRenderError.renderFailed }
        levels.sort()
        let noiseFloor = percentile(levels, 0.18)
        let speechLevel = percentile(levels, 0.72)
        let dynamicRange = max(0, percentile(levels, 0.9) - percentile(levels, 0.25))
        let derivativeRatio = sqrt(differenceEnergy / Double(energySamples)) /
            max(sqrt(sampleEnergy / Double(energySamples)), 0.000_001)
        let sibilance = min(max((derivativeRatio - 0.32) / 0.9, 0), 1)
        let peakDB = decibels(Double(globalPeak))
        let crest = max(0, peakDB - speechLevel)
        let presence = min(max((derivativeRatio - 0.18) / 1.15 + crest / 80, 0), 1)

        return VoiceAnalysis(
            noiseFloorDB: noiseFloor,
            speechLevelDB: speechLevel,
            dynamicRangeDB: dynamicRange,
            sibilanceScore: sibilance,
            presenceScore: presence
        )
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let index = min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)
        return sorted[index]
    }

    private static func decibels(_ amplitude: Double) -> Double {
        20 * log10(max(amplitude, 0.000_001))
    }
}
