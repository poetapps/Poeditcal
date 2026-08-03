import AVFoundation
import AudioToolbox
import Foundation

struct AudioTimeRange: Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
}

struct AudioRenderOptions: Sendable {
    let pacing: PacingPreset
    let maximumPause: TimeInterval
    let reduceNoise: Bool
    let voiceEQ: Bool
    let deEss: Bool
    let compression: Bool
    let forceMono: Bool
    let breathControl: Bool
    let normalizeLoudness: Bool
    let loudnessPreset: LoudnessPreset
    let noiseIntensity: PolishIntensity
    let eqIntensity: PolishIntensity
    let deEssIntensity: PolishIntensity
    let compressionIntensity: PolishIntensity
    let breathIntensity: PolishIntensity

    init(
        pacing: PacingPreset,
        maximumPause: TimeInterval? = nil,
        reduceNoise: Bool,
        voiceEQ: Bool,
        deEss: Bool,
        compression: Bool,
        forceMono: Bool,
        breathControl: Bool,
        normalizeLoudness: Bool,
        loudnessPreset: LoudnessPreset,
        noiseIntensity: PolishIntensity = .balanced,
        eqIntensity: PolishIntensity = .balanced,
        deEssIntensity: PolishIntensity = .balanced,
        compressionIntensity: PolishIntensity = .light,
        breathIntensity: PolishIntensity = .balanced
    ) {
        self.pacing = pacing
        self.maximumPause = maximumPause ?? pacing.maximumPause ?? 2.0
        self.reduceNoise = reduceNoise
        self.voiceEQ = voiceEQ
        self.deEss = deEss
        self.compression = compression
        self.forceMono = forceMono
        self.breathControl = breathControl
        self.normalizeLoudness = normalizeLoudness
        self.loudnessPreset = loudnessPreset
        self.noiseIntensity = noiseIntensity
        self.eqIntensity = eqIntensity
        self.deEssIntensity = deEssIntensity
        self.compressionIntensity = compressionIntensity
        self.breathIntensity = breathIntensity
    }
}

struct PolishStageUpdate: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case started
        case completed
    }

    let name: String
    let state: State
    let elapsed: TimeInterval?
}

typealias PolishProgressHandler = @Sendable (PolishStageUpdate) -> Void

enum AudioRenderError: LocalizedError {
    case unsupportedPCMFormat
    case emptyEdit
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedPCMFormat: "This recording’s PCM format couldn’t be prepared for editing."
        case .emptyEdit: "The current edit removes the entire recording. Restore at least one word before exporting."
        case .renderFailed: "The audio engine couldn’t finish rendering this recording."
        }
    }
}

enum AudioEditPlanner {
    /// Keeps a small, natural lead-in/out around the transcript while removing
    /// unbounded room tone at the edges of the recording.
    static let transcriptEdgeBuffer: TimeInterval = 0.15

    static func keptRanges(words: [TranscriptWord], duration: TimeInterval, pacing: PacingPreset) -> [AudioTimeRange] {
        keptRanges(words: words, duration: duration, maximumPause: pacing.maximumPause)
    }

    static func keptRanges(words: [TranscriptWord], duration: TimeInterval, maximumPause: TimeInterval?) -> [AudioTimeRange] {
        guard duration > 0 else { return [] }
        let sorted = words.sorted { $0.startTime < $1.startTime }
        if !sorted.isEmpty, sorted.allSatisfy(\.isRemoved) { return [] }
        var cuts: [AudioTimeRange] = []

        var currentCut: AudioTimeRange?
        for word in sorted {
            if word.isRemoved {
                let paddedStart = max(0, word.startTime - 0.025)
                let paddedEnd = min(duration, word.endTime + 0.025)
                if var existing = currentCut, paddedStart <= existing.end + 0.08 {
                    existing.end = max(existing.end, paddedEnd)
                    currentCut = existing
                } else {
                    if let currentCut { cuts.append(currentCut) }
                    currentCut = AudioTimeRange(start: paddedStart, end: paddedEnd)
                }
            } else if let completedCut = currentCut {
                cuts.append(completedCut)
                currentCut = nil
            }
        }
        if let currentCut { cuts.append(currentCut) }

        if let maximumPause {
            let retained = sorted.filter { !$0.isRemoved }
            if let firstWord = retained.first {
                let spokenStart = max(0, firstWord.startTime - transcriptEdgeBuffer)
                if spokenStart > 0.002 {
                    cuts.append(AudioTimeRange(start: 0, end: spokenStart))
                }
            }
            if let lastWord = retained.last {
                let spokenEnd = min(duration, lastWord.endTime + transcriptEdgeBuffer)
                if spokenEnd < duration - 0.002 {
                    cuts.append(AudioTimeRange(start: spokenEnd, end: duration))
                }
            }

            // Measure pauses only from the end timestamp of one retained word to
            // the start timestamp of the next. This also intentionally spans any
            // transcript words removed between them. Splitting the kept pause
            // evenly around the edit preserves a little room on both sides while
            // guaranteeing that the edited end-to-start gap is `maximumPause`.
            let cappedPause = max(0, maximumPause)
            for pair in zip(retained, retained.dropFirst()) {
                let gapStart = min(duration, max(0, pair.0.endTime))
                let gapEnd = min(duration, max(0, pair.1.startTime))
                let gap = gapEnd - gapStart
                guard gap > cappedPause else { continue }
                let halfPause = cappedPause / 2
                cuts.append(AudioTimeRange(start: gapStart + halfPause, end: gapEnd - halfPause))
            }
        }

        let mergedCuts = merge(cuts, duration: duration)
        var kept: [AudioTimeRange] = []
        var cursor: TimeInterval = 0
        for cut in mergedCuts {
            if cut.start > cursor + 0.002 { kept.append(AudioTimeRange(start: cursor, end: cut.start)) }
            cursor = max(cursor, cut.end)
        }
        if cursor < duration - 0.002 { kept.append(AudioTimeRange(start: cursor, end: duration)) }
        return kept
    }

    static func editedDuration(for ranges: [AudioTimeRange]) -> TimeInterval {
        ranges.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    /// Maps a timestamp on the source recording onto the compacted export timeline.
    /// Times inside removed material collapse to the nearest edit boundary.
    static func editedTime(for sourceTime: TimeInterval, keptRanges: [AudioTimeRange]) -> TimeInterval {
        guard !keptRanges.isEmpty else { return 0 }
        var accumulated: TimeInterval = 0
        for range in keptRanges {
            if sourceTime < range.start { return accumulated }
            if sourceTime <= range.end {
                return accumulated + max(0, sourceTime - range.start)
            }
            accumulated += max(0, range.end - range.start)
        }
        return accumulated
    }

    static func playableTime(for requestedTime: TimeInterval, keptRanges: [AudioTimeRange]) -> TimeInterval? {
        for range in keptRanges {
            if requestedTime < range.start { return range.start }
            if requestedTime <= range.end { return requestedTime }
        }
        return nil
    }

    private static func merge(_ ranges: [AudioTimeRange], duration: TimeInterval) -> [AudioTimeRange] {
        let normalized = ranges
            .map { AudioTimeRange(start: max(0, min($0.start, duration)), end: max(0, min($0.end, duration))) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var result: [AudioTimeRange] = []
        for range in normalized {
            guard var last = result.popLast() else {
                result.append(range)
                continue
            }
            if range.start <= last.end + 0.01 {
                last.end = max(last.end, range.end)
                result.append(last)
            } else {
                result.append(last)
                result.append(range)
            }
        }
        return result
    }
}

enum EditedAudioRenderer {
    static func render(sourceURL: URL, destinationURL: URL, keptRanges: [AudioTimeRange]) throws {
        guard !keptRanges.isEmpty else { throw AudioRenderError.emptyEdit }
        let input = try AVAudioFile(forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw AudioRenderError.unsupportedPCMFormat
        }

        try? FileManager.default.removeItem(at: destinationURL)
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let capacity: AVAudioFrameCount = 16_384
        let edgeFrames = AVAudioFramePosition(format.sampleRate * 0.008)

        for (segmentIndex, range) in keptRanges.enumerated() {
            let startFrame = max(0, AVAudioFramePosition(range.start * format.sampleRate))
            let endFrame = min(input.length, AVAudioFramePosition(range.end * format.sampleRate))
            let segmentLength = endFrame - startFrame
            guard segmentLength > 0 else { continue }
            input.framePosition = startFrame
            var segmentPosition: AVAudioFramePosition = 0

            while segmentPosition < segmentLength {
                let count = AVAudioFrameCount(min(AVAudioFramePosition(capacity), segmentLength - segmentPosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                    throw AudioRenderError.unsupportedPCMFormat
                }
                do {
                    try input.read(into: buffer, frameCount: count)
                } catch let error as NSError {
                    let isTruncatedFinalPacket = error.domain == NSOSStatusErrorDomain &&
                        error.code == Int(kAudioFileEndOfFileError) &&
                        input.length - endFrame <= 1 &&
                        segmentPosition + AVAudioFramePosition(count) >= segmentLength
                    guard isTruncatedFinalPacket else { throw error }
                    // Some compressed recordings advertise a final packet that their decoder
                    // cannot read. Keep any frames Core Audio recovered and stop at the last
                    // decodable packet rather than failing the entire preview/export.
                }
                guard buffer.frameLength > 0 else { break }
                applyBoundaryFades(
                    to: buffer,
                    segmentPosition: segmentPosition,
                    segmentLength: segmentLength,
                    fadeFrames: min(edgeFrames, segmentLength / 3),
                    fadeIn: segmentIndex > 0,
                    fadeOut: segmentIndex < keptRanges.count - 1
                )
                try output.write(from: buffer)
                segmentPosition += AVAudioFramePosition(buffer.frameLength)
            }
        }
    }

    private static func applyBoundaryFades(
        to buffer: AVAudioPCMBuffer,
        segmentPosition: AVAudioFramePosition,
        segmentLength: AVAudioFramePosition,
        fadeFrames: AVAudioFramePosition,
        fadeIn: Bool,
        fadeOut: Bool
    ) {
        guard fadeFrames > 0, let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        for frame in 0..<frameCount {
            let absolute = segmentPosition + AVAudioFramePosition(frame)
            var gain: Float = 1
            if fadeIn && absolute < fadeFrames {
                gain *= Float(absolute) / Float(fadeFrames)
            }
            let framesFromEnd = segmentLength - absolute - 1
            if fadeOut && framesFromEnd < fadeFrames {
                gain *= Float(max(framesFromEnd, 0)) / Float(fadeFrames)
            }
            if gain < 1 {
                for channel in 0..<channelCount { channels[channel][frame] *= gain }
            }
        }
    }
}

enum VoicePolisher {
    @discardableResult
    static func render(
        sourceURL: URL,
        destinationURL: URL,
        options: AudioRenderOptions,
        progress: PolishProgressHandler? = nil
    ) throws -> PolishRenderReport {
        func measured<T>(_ name: String, _ operation: () throws -> T) throws -> T {
            try Task.checkCancellation()
            progress?(PolishStageUpdate(name: name, state: .started, elapsed: nil))
            let started = CFAbsoluteTimeGetCurrent()
            let result = try operation()
            try Task.checkCancellation()
            progress?(PolishStageUpdate(
                name: name,
                state: .completed,
                elapsed: CFAbsoluteTimeGetCurrent() - started
            ))
            return result
        }

        let needsEffects = options.voiceEQ || options.deEss || options.compression || options.forceMono
        guard needsEffects || options.breathControl || options.normalizeLoudness else {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            let quality = try PolishQualityAnalyzer.compare(
                dryURL: sourceURL,
                polishedURL: destinationURL,
                usedGentleCompression: false
            )
            return PolishRenderReport(loudness: nil, quality: quality, breathControl: nil, deEssing: nil)
        }

        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetPolish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }
        let processedURL = tempFolder.appendingPathComponent("processed.wav")
        let denoisedURL = tempFolder.appendingPathComponent("ai-denoised.wav")
        let deEssedURL = tempFolder.appendingPathComponent("adaptive-de-essed.wav")
        let breathURL = tempFolder.appendingPathComponent("breath-controlled.wav")
        let baselineURL = tempFolder.appendingPathComponent("compression-baseline.wav")

        let polishSourceURL: URL
        if options.reduceNoise {
            _ = try measured("AI noise reduction") {
                try AIDenoiser.render(
                    sourceURL: sourceURL,
                    destinationURL: denoisedURL,
                    intensity: options.noiseIntensity.amount
                )
            }
            polishSourceURL = denoisedURL
        } else {
            polishSourceURL = sourceURL
        }

        func runPass(
            destination passDestinationURL: URL,
            gentleCompression: Bool,
            bypassCompression: Bool = false,
            label: String
        ) throws -> PolishRenderReport {
            let needsEngineEffects = options.voiceEQ || options.compression || options.forceMono
            if needsEngineEffects {
                var engineStages: [String] = []
                if options.voiceEQ { engineStages.append("EQ") }
                if options.forceMono { engineStages.append("mono") }
                if options.compression && !bypassCompression { engineStages.append("compression") }
                let engineLabel = engineStages.isEmpty ? "format render" : engineStages.joined(separator: ", ")
                try measured("\(label) · \(engineLabel)") {
                    try renderEffects(
                        sourceURL: polishSourceURL,
                        destinationURL: processedURL,
                        options: options,
                        gentleCompression: gentleCompression,
                        bypassCompression: bypassCompression
                    )
                }
            } else {
                try? FileManager.default.removeItem(at: processedURL)
                try FileManager.default.copyItem(at: polishSourceURL, to: processedURL)
            }

            let deEssingResult: DeEssingResult?
            let breathSourceURL: URL
            if options.deEss {
                deEssingResult = try measured("\(label) · adaptive de-essing") {
                    try AdaptiveDeEsser.process(
                        sourceURL: processedURL,
                        destinationURL: deEssedURL,
                        intensity: options.deEssIntensity.amount
                    )
                }
                breathSourceURL = deEssedURL
            } else {
                deEssingResult = nil
                breathSourceURL = processedURL
            }

            let breathResult: BreathControlResult?
            let masteringSource: URL
            if options.breathControl {
                breathResult = try measured("\(label) · breath control") {
                    try BreathController.process(
                        dryReferenceURL: sourceURL,
                        sourceURL: breathSourceURL,
                        destinationURL: breathURL,
                        attenuationDB: options.breathIntensity.breathAttenuationDB
                    )
                }
                masteringSource = breathURL
            } else {
                breathResult = nil
                masteringSource = breathSourceURL
            }

            let normalization: LoudnessNormalizationResult?
            if options.normalizeLoudness {
                normalization = try measured("\(label) · loudness & peak limiting") {
                    try LoudnessNormalizer.normalize(
                        sourceURL: masteringSource,
                        destinationURL: passDestinationURL,
                        preset: options.loudnessPreset
                    )
                }
            } else {
                try? FileManager.default.removeItem(at: passDestinationURL)
                try FileManager.default.copyItem(at: masteringSource, to: passDestinationURL)
                normalization = nil
            }
            let quality = try measured("\(label) · quality measurement") {
                try PolishQualityAnalyzer.compare(
                    dryURL: sourceURL,
                    polishedURL: passDestinationURL,
                    usedGentleCompression: gentleCompression,
                    bypassedCompression: bypassCompression
                )
            }
            return PolishRenderReport(
                loudness: normalization,
                quality: quality,
                breathControl: breathResult,
                deEssing: deEssingResult
            )
        }

        guard options.compression else {
            return try runPass(destination: destinationURL, gentleCompression: false, label: "Main pass")
        }

        // Establish how the same polish chain behaves without compression. Comparing
        // against this baseline isolates compressor-induced breath lift from intended
        // changes made by EQ, noise reduction, breath control, and normalization.
        let baseline = try runPass(
            destination: baselineURL,
            gentleCompression: true,
            bypassCompression: true,
            label: "Baseline (compression bypassed)"
        )

        func checked(_ candidate: PolishRenderReport, gentle: Bool) throws -> PolishRenderReport {
            let quality = try measured("\(gentle ? "Gentle" : "Standard") · compare with baseline") {
                try PolishQualityAnalyzer.compare(
                    dryURL: baselineURL,
                    polishedURL: destinationURL,
                    usedGentleCompression: gentle
                )
            }
            return PolishRenderReport(
                loudness: candidate.loudness,
                quality: quality,
                breathControl: candidate.breathControl,
                deEssing: candidate.deEssing
            )
        }

        var candidate = try runPass(destination: destinationURL, gentleCompression: false, label: "Standard compression")
        var report = try checked(candidate, gentle: false)
        if report.quality.passed { return report }

        candidate = try runPass(destination: destinationURL, gentleCompression: true, label: "Gentle compression retry")
        report = try checked(candidate, gentle: true)
        if report.quality.passed { return report }

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.copyItem(at: baselineURL, to: destinationURL)
        let quality = try PolishQualityAnalyzer.compare(
            dryURL: baselineURL,
            polishedURL: baselineURL,
            usedGentleCompression: true,
            bypassedCompression: true
        )
        return PolishRenderReport(
            loudness: baseline.loudness,
            quality: quality,
            breathControl: baseline.breathControl,
            deEssing: baseline.deEssing
        )
    }

    private static func renderEffects(
        sourceURL: URL,
        destinationURL: URL,
        options: AudioRenderOptions,
        gentleCompression: Bool,
        bypassCompression: Bool
    ) throws {

        let source = try AVAudioFile(forReading: sourceURL)
        let format = source.processingFormat
        let renderFormat: AVAudioFormat
        if options.forceMono {
            guard let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: 1,
                interleaved: false
            ) else { throw AudioRenderError.unsupportedPCMFormat }
            renderFormat = mono
        } else {
            renderFormat = format
        }
        let analysis = try? AudioSignalAnalyzer.analyze(url: sourceURL)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        var chain: [AVAudioNode] = []
        if options.voiceEQ {
            let bandCount = 3
            let eq = AVAudioUnitEQ(numberOfBands: bandCount)
            var band = 0
            if options.voiceEQ {
                eq.bands[band].filterType = .highPass
                eq.bands[band].frequency = Float(55 + 20 * options.eqIntensity.amount)
                eq.bands[band].bandwidth = 0.55
                eq.bands[band].bypass = false
                band += 1

                eq.bands[band].filterType = .parametric
                eq.bands[band].frequency = 240
                eq.bands[band].bandwidth = 0.9
                eq.bands[band].gain = Float(-1.2 * options.eqIntensity.amount)
                eq.bands[band].bypass = false
                band += 1

                eq.bands[band].filterType = .parametric
                eq.bands[band].frequency = 3_200
                eq.bands[band].bandwidth = 0.8
                eq.bands[band].gain = Float((2.0 - (analysis?.presenceScore ?? 0.5) * 1.8) * options.eqIntensity.amount)
                eq.bands[band].bypass = false
                band += 1
            }
            chain.append(eq)
        }

        if options.compression && !bypassCompression {
            let speechLevel = Float(analysis?.speechLevelDB ?? -24)
            let strength = Float(options.compressionIntensity.amount) * (gentleCompression ? 0.62 : 1)
            let compressor = makeDynamicsProcessor(
                threshold: min(max(speechLevel + 13 - 6 * strength, -22), -8),
                headRoom: 17 - 8 * strength,
                expansionRatio: 1,
                expansionThreshold: -70,
                attackTime: 0.028 - 0.016 * strength,
                releaseTime: 0.30 - 0.12 * strength,
                gain: 0
            )
            chain.append(compressor)
        }

        var previous: AVAudioNode = player
        for node in chain {
            engine.attach(node)
            engine.connect(previous, to: node, format: format)
            previous = node
        }
        engine.connect(previous, to: engine.mainMixerNode, format: format)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: maxFrames)
        try? FileManager.default.removeItem(at: destinationURL)
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: renderFormat.settings,
            commonFormat: renderFormat.commonFormat,
            interleaved: renderFormat.isInterleaved
        )
        guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            throw AudioRenderError.unsupportedPCMFormat
        }

        player.scheduleFile(source, at: nil)
        try engine.start()
        player.play()
        defer {
            player.stop()
            engine.stop()
        }

        while engine.manualRenderingSampleTime < source.length {
            let remaining = source.length - engine.manualRenderingSampleTime
            let requested = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), remaining))
            let status = try engine.renderOffline(requested, to: renderBuffer)
            switch status {
            case .success:
                try output.write(from: renderBuffer)
            case .insufficientDataFromInputNode:
                continue
            case .cannotDoInCurrentContext:
                continue
            case .error:
                throw AudioRenderError.renderFailed
            @unknown default:
                throw AudioRenderError.renderFailed
            }
        }
    }

    private static func makeDynamicsProcessor(
        threshold: Float,
        headRoom: Float,
        expansionRatio: Float,
        expansionThreshold: Float,
        attackTime: Float,
        releaseTime: Float,
        gain: Float
    ) -> AVAudioUnitEffect {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let unit = AVAudioUnitEffect(audioComponentDescription: description)
        let parameters: [(AudioUnitParameterID, Float)] = [
            (AudioUnitParameterID(kDynamicsProcessorParam_Threshold), threshold),
            (AudioUnitParameterID(kDynamicsProcessorParam_HeadRoom), headRoom),
            (AudioUnitParameterID(kDynamicsProcessorParam_ExpansionRatio), expansionRatio),
            (AudioUnitParameterID(kDynamicsProcessorParam_ExpansionThreshold), expansionThreshold),
            (AudioUnitParameterID(kDynamicsProcessorParam_AttackTime), attackTime),
            (AudioUnitParameterID(kDynamicsProcessorParam_ReleaseTime), releaseTime),
            (AudioUnitParameterID(kDynamicsProcessorParam_OverallGain), gain)
        ]
        for (parameter, value) in parameters {
            AudioUnitSetParameter(unit.audioUnit, parameter, kAudioUnitScope_Global, 0, value, 0)
        }
        return unit
    }
}
