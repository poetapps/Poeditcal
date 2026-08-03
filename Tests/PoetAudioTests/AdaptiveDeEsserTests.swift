import AVFoundation
import XCTest
@testable import PoetAudio

final class AdaptiveDeEsserTests: XCTestCase {
    func testAdaptiveDeEsserReducesSibilantBurstsAndPreservesVoice() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetDeEsserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("sibilant.wav")
        let output = folder.appendingPathComponent("de-essed.wav")
        try makeFixture(at: source, includeSibilants: true)

        let result = try AdaptiveDeEsser.process(sourceURL: source, destinationURL: output)

        XCTAssertGreaterThanOrEqual(result.count, 2)
        XCTAssertGreaterThan(result.averageReductionDB, 1.0)
        XCTAssertLessThanOrEqual(result.peakReductionDB, 4.76)
        XCTAssertTrue(result.passedPostAnalysis)
        XCTAssertEqual(result.ordinaryVoiceChangeDB, 0, accuracy: 0.15)
        XCTAssertTrue((4_000 ... 10_500).contains(result.detectedFrequencyHz))

        let sibilantRanges = [AudioTimeRange(start: 0.45, end: 0.58), AudioTimeRange(start: 1.25, end: 1.38)]
        let beforeSibilance = try highBandLevel(url: source, ranges: sibilantRanges)
        let afterSibilance = try highBandLevel(url: output, ranges: sibilantRanges)
        XCTAssertLessThan(afterSibilance - beforeSibilance, -1.0)

        let ordinaryVoice = [AudioTimeRange(start: 0.75, end: 1.0)]
        let beforeVoice = try rmsLevel(url: source, ranges: ordinaryVoice)
        let afterVoice = try rmsLevel(url: output, ranges: ordinaryVoice)
        XCTAssertEqual(afterVoice, beforeVoice, accuracy: 0.15)

        let inputFile = try AVAudioFile(forReading: source)
        let outputFile = try AVAudioFile(forReading: output)
        XCTAssertEqual(outputFile.length, inputFile.length)
    }

    func testAdaptiveDeEsserLeavesNonsibilantVoiceAlone() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetDeEsserBypassTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("voice.wav")
        let output = folder.appendingPathComponent("untouched.wav")
        try makeFixture(at: source, includeSibilants: false)

        let result = try AdaptiveDeEsser.process(sourceURL: source, destinationURL: output)
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(try rmsLevel(url: output, ranges: [AudioTimeRange(start: 0, end: 2)]),
                       try rmsLevel(url: source, ranges: [AudioTimeRange(start: 0, end: 2)]),
                       accuracy: 0.01)
    }

    private func makeFixture(at url: URL, includeSibilants: Bool) throws {
        let sampleRate = 48_000.0
        let duration = 2.0
        let frameCount = Int(sampleRate * duration)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = buffer.floatChannelData![0]
        var seed: UInt64 = 0x1234_5678
        var noiseLowPass = 0.0

        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            let voice = 0.16 * sin(2 * Double.pi * 180 * time)
                + 0.055 * sin(2 * Double.pi * 900 * time)
                + 0.018 * sin(2 * Double.pi * 2_600 * time)
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let white = Double(Int64(bitPattern: seed) >> 32) / Double(Int32.max)
            noiseLowPass += 0.22 * (white - noiseLowPass)
            let highNoise = white - noiseLowPass
            let inBurst = (0.45 ... 0.58).contains(time) || (1.25 ... 1.38).contains(time)
            samples[frame] = Float(voice + (includeSibilants && inBurst ? highNoise * 0.24 : 0))
        }
        try file.write(from: buffer)
    }

    private func highBandLevel(url: URL, ranges: [AudioTimeRange]) throws -> Double {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let coefficient = 1 - exp(-2 * Double.pi * 4_000 / format.sampleRate)
        var low = 0.0
        var energy = 0.0
        var count = 0
        for frame in 0..<Int(buffer.frameLength) {
            let sample = Double(samples[frame])
            low += coefficient * (sample - low)
            let time = Double(frame) / format.sampleRate
            if ranges.contains(where: { time >= $0.start && time <= $0.end }) {
                let high = sample - low
                energy += high * high
                count += 1
            }
        }
        return decibels(sqrt(energy / Double(max(count, 1))))
    }

    private func rmsLevel(url: URL, ranges: [AudioTimeRange]) throws -> Double {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        var energy = 0.0
        var count = 0
        for frame in 0..<Int(buffer.frameLength) {
            let time = Double(frame) / format.sampleRate
            guard ranges.contains(where: { time >= $0.start && time <= $0.end }) else { continue }
            let sample = Double(samples[frame])
            energy += sample * sample
            count += 1
        }
        return decibels(sqrt(energy / Double(max(count, 1))))
    }

    private func decibels(_ amplitude: Double) -> Double {
        20 * log10(max(amplitude, 0.000_001))
    }
}
