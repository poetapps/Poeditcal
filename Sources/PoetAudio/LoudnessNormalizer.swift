import AVFoundation
import Foundation

enum LoudnessPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case podcast = "Podcast"
    case audiobook = "Audiobook"
    case video = "Video"
    case broadcast = "Broadcast"

    var id: String { rawValue }

    var targetLUFS: Double {
        switch self {
        case .podcast: -16
        case .audiobook: -18
        case .video: -14
        case .broadcast: -23
        }
    }

    var peakCeilingDBFS: Double {
        switch self {
        case .broadcast: -2
        default: -1
        }
    }

    var detail: String {
        "\(Int(targetLUFS)) LUFS · \(Int(peakCeilingDBFS)) dB peak"
    }
}

struct LoudnessMeasurement: Sendable, Equatable {
    let integratedLUFS: Double
    let peakDBFS: Double
}

struct LoudnessNormalizationResult: Sendable, Equatable {
    let before: LoudnessMeasurement
    let after: LoudnessMeasurement
    let appliedGainDB: Double
}

enum LoudnessAnalyzer {
    static func measure(url: URL) throws -> LoudnessMeasurement {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { throw AudioRenderError.unsupportedPCMFormat }

        var shelves = (0..<channelCount).map { _ in Biquad.highShelf(sampleRate: format.sampleRate, frequency: 1_681.974, gainDB: 4, q: 0.707) }
        var highPasses = (0..<channelCount).map { _ in Biquad.highPass(sampleRate: format.sampleRate, frequency: 38.136, q: 0.5) }
        let stepFrames = max(1, Int(format.sampleRate * 0.1))
        let capacity: AVAudioFrameCount = 8_192
        var subblockEnergy = 0.0
        var subblockFrames = 0
        var recentSubblocks: [(energy: Double, frames: Int)] = []
        var blockEnergies: [Double] = []
        var totalEnergy = 0.0
        var totalFrames = 0
        var peak: Float = 0

        func finishSubblock() {
            guard subblockFrames > 0 else { return }
            recentSubblocks.append((subblockEnergy, subblockFrames))
            if recentSubblocks.count > 4 { recentSubblocks.removeFirst() }
            if recentSubblocks.count == 4 {
                let energy = recentSubblocks.reduce(0) { $0 + $1.energy }
                let frames = recentSubblocks.reduce(0) { $0 + $1.frames }
                blockEnergies.append(energy / Double(max(frames, 1)))
            }
            subblockEnergy = 0
            subblockFrames = 0
        }

        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
                  let channels = buffer.floatChannelData else {
                throw AudioRenderError.unsupportedPCMFormat
            }
            try file.read(into: buffer, frameCount: capacity)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }

            for frame in 0..<frameCount {
                var frameEnergy = 0.0
                for channel in 0..<channelCount {
                    let sample = channels[channel][frame]
                    peak = max(peak, abs(sample))
                    let weighted = highPasses[channel].process(shelves[channel].process(Double(sample)))
                    frameEnergy += weighted * weighted
                }
                subblockEnergy += frameEnergy
                subblockFrames += 1
                totalEnergy += frameEnergy
                totalFrames += 1
                if subblockFrames == stepFrames { finishSubblock() }
            }
        }
        finishSubblock()
        if blockEnergies.isEmpty, totalFrames > 0 {
            blockEnergies = [totalEnergy / Double(totalFrames)]
        }

        let absoluteGated = blockEnergies.filter { lufs(for: $0) >= -70 }
        let firstPass = mean(absoluteGated.isEmpty ? blockEnergies : absoluteGated)
        let relativeThreshold = lufs(for: firstPass) - 10
        let relativeGated = absoluteGated.filter { lufs(for: $0) >= relativeThreshold }
        let integratedEnergy = mean(relativeGated.isEmpty ? absoluteGated : relativeGated)

        return LoudnessMeasurement(
            integratedLUFS: lufs(for: integratedEnergy),
            peakDBFS: decibels(Double(peak))
        )
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.000_000_000_001 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func lufs(for energy: Double) -> Double {
        -0.691 + 10 * log10(max(energy, 0.000_000_000_001))
    }

    private static func decibels(_ amplitude: Double) -> Double {
        20 * log10(max(amplitude, 0.000_001))
    }
}

enum LoudnessNormalizer {
    static func normalize(
        sourceURL: URL,
        destinationURL: URL,
        preset: LoudnessPreset
    ) throws -> LoudnessNormalizationResult {
        let before = try LoudnessAnalyzer.measure(url: sourceURL)
        var gainDB = min(max(preset.targetLUFS - before.integratedLUFS, -30), 36)
        var after = before

        // The limiter changes integrated loudness when a recording has isolated high
        // peaks. Re-measure and correct a few times so the delivered file lands on the
        // requested target instead of becoming quietly peak-limited.
        for _ in 0..<4 {
            try render(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                gainDB: gainDB,
                ceilingDBFS: preset.peakCeilingDBFS
            )
            after = try LoudnessAnalyzer.measure(url: destinationURL)
            let correction = preset.targetLUFS - after.integratedLUFS
            if abs(correction) < 0.15 { break }
            gainDB = min(max(gainDB + correction, -30), 42)
        }

        return LoudnessNormalizationResult(before: before, after: after, appliedGainDB: gainDB)
    }

    private static func render(
        sourceURL: URL,
        destinationURL: URL,
        gainDB: Double,
        ceilingDBFS: Double
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
        let gain = Float(pow(10, gainDB / 20))
        let ceiling = Float(pow(10, ceilingDBFS / 20))
        let knee = ceiling * 0.72
        let kneeRange = max(ceiling - knee, 0.000_001)
        let capacity: AVAudioFrameCount = 8_192

        while input.framePosition < input.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
                  let channels = buffer.floatChannelData else {
                throw AudioRenderError.unsupportedPCMFormat
            }
            try input.read(into: buffer, frameCount: capacity)
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<frames {
                    let amplified = channels[channel][frame] * gain
                    let magnitude = abs(amplified)
                    if magnitude <= knee {
                        channels[channel][frame] = amplified
                    } else {
                        let compressed = knee + kneeRange * (1 - exp(-(magnitude - knee) / kneeRange))
                        channels[channel][frame] = amplified.sign == .minus ? -compressed : compressed
                    }
                }
            }
            try output.write(from: buffer)
        }
    }
}

private struct Biquad {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double
    var z1 = 0.0
    var z2 = 0.0

    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }

    static func highPass(sampleRate: Double, frequency: Double, q: Double) -> Biquad {
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosine = cos(omega)
        let a0 = 1 + alpha
        return Biquad(
            b0: ((1 + cosine) / 2) / a0,
            b1: (-(1 + cosine)) / a0,
            b2: ((1 + cosine) / 2) / a0,
            a1: (-2 * cosine) / a0,
            a2: (1 - alpha) / a0
        )
    }

    static func highShelf(sampleRate: Double, frequency: Double, gainDB: Double, q: Double) -> Biquad {
        let amplitude = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(omega)
        let sine = sin(omega)
        let alpha = sine / (2 * q)
        let rootTerm = 2 * sqrt(amplitude) * alpha
        let a0 = (amplitude + 1) - (amplitude - 1) * cosine + rootTerm
        return Biquad(
            b0: amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + rootTerm) / a0,
            b1: -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine) / a0,
            b2: amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - rootTerm) / a0,
            a1: 2 * ((amplitude - 1) - (amplitude + 1) * cosine) / a0,
            a2: ((amplitude + 1) - (amplitude - 1) * cosine - rootTerm) / a0
        )
    }
}
