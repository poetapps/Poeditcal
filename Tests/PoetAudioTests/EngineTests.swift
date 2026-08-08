import AVFoundation
import XCTest
@testable import PoetAudio

final class EngineTests: XCTestCase {
    func testPoetProjectRoundTripKeepsAudioAndEditDecisions() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("take.wav")
        let firstPass = folder.appendingPathComponent("first-pass.wav")
        try makeTone(at: source, duration: 0.2)
        try makeTone(at: firstPass, duration: 0.2)
        let pauseDecision = PauseEditDecision(
            sourceStart: 0.1,
            sourceEnd: 0.18,
            confidence: 0.94,
            reason: "Confirmed silent pause"
        )
        let snapshot = PoetProjectSnapshot(
            projectName: "First draft",
            sourceAudioFile: "Source Audio.wav",
            firstPassAudioFile: "Analysis First Pass.wav",
            sourceDisplayName: "take.wav",
            phase: .edit,
            editingMode: .autopilot,
            autoEditConfiguration: AutoEditConfiguration(),
            pacing: .natural,
            duration: 0.2,
            words: [word("Keep", 0, 0.1), word("cut", 0.1, 0.2, removed: true)],
            pauseDecisions: [pauseDecision],
            polishSelections: Set(PolishOption.allCases),
            polishIntensities: [
                .noise: .strong,
                .eq: .light,
                .deEss: .balanced,
                .compression: .light,
                .breathControl: .maximum
            ],
            usePolish: true,
            loudnessPreset: .podcast,
            exportAudio: true,
            exportOriginal: true,
            exportTXT: true,
            exportSRT: false,
            exportVTT: false
        )

        let package = try PoetProjectStore.save(
            snapshot: snapshot,
            sourceAudioURL: source,
            firstPassAudioURL: firstPass,
            to: folder.appendingPathComponent("First draft.poe")
        )
        let loaded = try PoetProjectStore.load(from: package)

        XCTAssertEqual(loaded.snapshot, snapshot)
        XCTAssertEqual(loaded.snapshot.polishIntensities?[.compression], .light)
        XCTAssertEqual(loaded.snapshot.polishIntensities?[.breathControl], .maximum)
        XCTAssertTrue(FileManager.default.fileExists(atPath: loaded.audioURL.path))
        XCTAssertNotNil(loaded.firstPassAudioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: loaded.firstPassAudioURL!.path))
        XCTAssertEqual(loaded.audioURL.lastPathComponent, "Source Audio.wav")

        var revised = snapshot
        revised.projectName = "Second draft"
        _ = try PoetProjectStore.save(
            snapshot: revised,
            sourceAudioURL: loaded.audioURL,
            firstPassAudioURL: loaded.firstPassAudioURL,
            to: package
        )
        XCTAssertEqual(try PoetProjectStore.load(from: package).snapshot.projectName, "Second draft")
    }

    func testPoetProjectRoundTripKeepsSourceVideoAndTimelineSettings() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetVideoProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceAudio = folder.appendingPathComponent("source.m4a")
        let sourceVideo = folder.appendingPathComponent("source.mov")
        try Data("audio".utf8).write(to: sourceAudio)
        try Data("video".utf8).write(to: sourceVideo)
        let snapshot = PoetProjectSnapshot(
            projectName: "Talking head",
            sourceAudioFile: "Source Audio.m4a",
            sourceVideoFile: "Source Video.mov",
            videoFrameRate: 29.97,
            videoWidth: 1920,
            videoHeight: 1080,
            sourceDisplayName: "source.mov",
            phase: .edit,
            editingMode: .autopilot,
            autoEditConfiguration: AutoEditConfiguration(),
            pacing: .natural,
            duration: 12,
            words: [word("Hello", 1, 1.4)],
            polishSelections: [],
            usePolish: true,
            loudnessPreset: .video,
            exportAudio: false,
            exportTXT: false,
            exportSRT: false,
            exportVTT: false,
            exportEditableTimelines: true,
            exportFinishedVideo: false
        )

        let package = try PoetProjectStore.save(
            snapshot: snapshot,
            sourceAudioURL: sourceAudio,
            sourceVideoURL: sourceVideo,
            to: folder.appendingPathComponent("Talking head.poe")
        )
        let loaded = try PoetProjectStore.load(from: package)
        XCTAssertEqual(loaded.snapshot, snapshot)
        XCTAssertEqual(loaded.videoURL?.lastPathComponent, "Source Video.mov")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(loaded.videoURL)), Data("video".utf8))
    }

    func testLaunchArgumentsIgnoreNonAudioValuesLikeYES() {
        XCTAssertNil(PoetAppDelegate.launchAudioURL(
            arguments: ["PoetAudio", "YES"],
            fileExists: { _ in true }
        ))

        let audio = PoetAppDelegate.launchAudioURL(
            arguments: ["PoetAudio", "-NSDocumentRevisionsDebugMode", "YES", "/tmp/take.m4a"],
            fileExists: { $0 == "/tmp/take.m4a" }
        )
        XCTAssertEqual(audio?.path, "/tmp/take.m4a")
    }

    func testEditableTimelineUsesFullLengthSourcesAndReversibleClipRanges() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetTimelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("Camera Take.mov")
        let polished = folder.appendingPathComponent("Camera Take-polished-full.wav")
        try Data().write(to: video)
        try Data().write(to: polished)
        let request = EditableTimelineRequest(
            name: "Camera Take",
            videoURL: video,
            polishedAudioURL: polished,
            originalAudioURL: nil,
            keptRanges: [
                AudioTimeRange(start: 0.5, end: 2.0),
                AudioTimeRange(start: 4.0, end: 7.25)
            ],
            sourceDuration: 10,
            frameRate: 30,
            width: 1920,
            height: 1080
        )

        try EditableTimelineRenderer.render(request, to: folder)

        let xml = try String(contentsOf: folder.appendingPathComponent("Camera Take-Premiere.xml"), encoding: .utf8)
        XCTAssertTrue(xml.contains("<duration>300</duration>"), "Media must remain full-length in the timeline project.")
        XCTAssertTrue(xml.contains("<in>15</in><out>60</out>"))
        XCTAssertTrue(xml.contains("<in>120</in><out>218</out>"))
        XCTAssertTrue(xml.contains("Camera%20Take-polished-full.wav"))

        let otioData = try Data(contentsOf: folder.appendingPathComponent("Camera Take-Resolve.otio"))
        let otio = try XCTUnwrap(JSONSerialization.jsonObject(with: otioData) as? [String: Any])
        let tracks = try XCTUnwrap(otio["tracks"] as? [String: Any])
        let children = try XCTUnwrap(tracks["children"] as? [[String: Any]])
        XCTAssertEqual(children.count, 3)
        let polishedTrack = children[2]
        let polishedClips = try XCTUnwrap(polishedTrack["children"] as? [[String: Any]])
        XCTAssertEqual(polishedClips.count, 2)
        XCTAssertNil(polishedClips[0]["media_reference"], "Clip.2 must not use the removed singular media_reference field.")
        XCTAssertEqual(polishedClips[0]["active_media_reference_key"] as? String, "DEFAULT_MEDIA")
        let references = try XCTUnwrap(polishedClips[0]["media_references"] as? [String: Any])
        let reference = try XCTUnwrap(references["DEFAULT_MEDIA"] as? [String: Any])
        let availableRange = try XCTUnwrap(reference["available_range"] as? [String: Any])
        let availableDuration = try XCTUnwrap(availableRange["duration"] as? [String: Any])
        XCTAssertEqual(availableDuration["value"] as? Double, 300)
    }

    func testEditedTimelineMapsBackToSourceVideoAcrossCuts() {
        let ranges = [
            AudioTimeRange(start: 1, end: 3),
            AudioTimeRange(start: 6, end: 9)
        ]

        XCTAssertEqual(AudioEditPlanner.sourceTime(forEditedTime: 0, keptRanges: ranges), 1, accuracy: 0.001)
        XCTAssertEqual(AudioEditPlanner.sourceTime(forEditedTime: 1.5, keptRanges: ranges), 2.5, accuracy: 0.001)
        XCTAssertEqual(AudioEditPlanner.sourceTime(forEditedTime: 2.1, keptRanges: ranges), 6.1, accuracy: 0.001)
        XCTAssertEqual(AudioEditPlanner.sourceTime(forEditedTime: 5, keptRanges: ranges), 9, accuracy: 0.001)
    }

    func testClipTimelineSnapsNearCutsWithoutDraggingDistantTimes() {
        let ranges = [
            AudioTimeRange(start: 1, end: 3),
            AudioTimeRange(start: 6, end: 9)
        ]
        let boundaries = ClipTimelineMath.boundaries(for: ranges)
        XCTAssertEqual(boundaries, [0, 2, 5])

        let snapped = ClipTimelineMath.snappedTime(
            2.04,
            duration: 5,
            boundaries: boundaries,
            trackWidth: 500
        )
        XCTAssertEqual(snapped.time, 2, accuracy: 0.001)
        XCTAssertEqual(snapped.boundary, 2)

        let free = ClipTimelineMath.snappedTime(
            2.5,
            duration: 5,
            boundaries: boundaries,
            trackWidth: 500
        )
        XCTAssertEqual(free.time, 2.5, accuracy: 0.001)
        XCTAssertNil(free.boundary)
    }

    func testTalkingHeadVideoInspectionAndFullLengthAudioExtraction() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetVideoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("talking-head.mov")
        try await makeTalkingHeadFixture(at: video, duration: 1)

        XCTAssertEqual(SourceMediaInspector.kind(for: video), .video)
        let info = try await SourceMediaInspector.inspectVideo(at: video)
        XCTAssertEqual(info.duration, 1, accuracy: 0.08)
        XCTAssertEqual(info.frameRate, 30, accuracy: 0.1)
        XCTAssertEqual(info.width, 64)
        XCTAssertEqual(info.height, 64)

        let extracted = folder.appendingPathComponent("full-source.m4a")
        try await VideoAudioExtractor.extractFullLengthAudio(from: video, to: extracted)
        let audio = try AVAudioFile(forReading: extracted)
        XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, 1, accuracy: 0.08)

        let finished = folder.appendingPathComponent("finished.mov")
        try await EditedVideoRenderer.render(
            sourceVideoURL: video,
            polishedAudioURL: extracted,
            destinationURL: finished,
            keptRanges: [
                AudioTimeRange(start: 0, end: 0.3),
                AudioTimeRange(start: 0.6, end: 1.0)
            ]
        )
        let finishedAsset = AVURLAsset(url: finished)
        let finishedDuration = try await finishedAsset.load(.duration).seconds
        let finishedVideoTracks = try await finishedAsset.loadTracks(withMediaType: .video)
        let finishedAudioTracks = try await finishedAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(finishedDuration, 0.7, accuracy: 0.08)
        XCTAssertEqual(finishedVideoTracks.count, 1)
        XCTAssertEqual(finishedAudioTracks.count, 1)

        let words = [
            word("Keep", 0, 0.3),
            word("remove", 0.3, 0.6, removed: true),
            word("this", 0.6, 1.0)
        ]
        let package = try await ExportPackageRenderer.render(
            ExportPackageRequest(
                folder: folder,
                baseName: "talking-head",
                sourceURL: extracted,
                sourceVideoURL: video,
                videoInfo: info,
                words: words,
                duration: 1,
                renderOptions: AudioRenderOptions(
                    pacing: .untouched,
                    reduceNoise: false,
                    voiceEQ: false,
                    deEss: false,
                    compression: false,
                    forceMono: false,
                    breathControl: false,
                    normalizeLoudness: false,
                    loudnessPreset: .video
                ),
                includeAudio: false,
                includeTXT: false,
                includeSRT: false,
                includeVTT: false,
                includeEditableTimelines: true,
                includeFinishedVideo: true
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("talking-head-source.mov").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("talking-head-polished-full.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("talking-head-Premiere.xml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("talking-head-Resolve.otio").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("talking-head-finished.mov").path))
        _ = try AVAudioFile(forReading: package.appendingPathComponent("talking-head-polished-full.wav"))
    }

    func testDenoiseModelDownloadConfigurationIsPinnedAndVerifiable() throws {
        XCTAssertEqual(DenoiseModelStore.remoteURL.scheme, "https")
        XCTAssertTrue(DenoiseModelStore.remoteURL.path.contains("8e67a45bbd269bb530ff88a5c0fb69a7fd43db15"))
        XCTAssertEqual(DenoiseModelStore.expectedSHA256.count, 64)

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetChecksum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data("abc".utf8).write(to: fixture)
        XCTAssertEqual(
            try DenoiseModelStore.sha256Digest(of: fixture),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @MainActor
    func testDenoiseModelCanBeUninstalled() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetDenoiseUninstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let modelURL = folder.appendingPathComponent(DenoiseModelStore.modelFileName)
        try Data("abc".utf8).write(to: modelURL)
        let store = DenoiseModelStore(
            installationDirectoryURL: folder,
            requiredSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )

        XCTAssertTrue(store.isInstalled)
        XCTAssertTrue(store.uninstall())
        XCTAssertFalse(store.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelURL.path))
    }

    @MainActor
    func testSmartEditModelCanBeUninstalledWithoutTouchingOtherChoice() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetSmartEditUninstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for choice in SmartEditModelChoice.allCases {
            let choiceFolder = folder.appendingPathComponent(choice.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: choiceFolder, withIntermediateDirectories: true)
            try Data(choice.repoID.utf8).write(to: choiceFolder.appendingPathComponent(".installed"))
            try Data("cached weights".utf8).write(to: choiceFolder.appendingPathComponent("weights.bin"))
        }
        let store = SmartEditModelStore(modelsDirectoryURL: folder)

        XCTAssertTrue(store.isInstalled(.fast))
        XCTAssertTrue(store.isInstalled(.reliable))
        XCTAssertTrue(store.uninstall(.fast))
        XCTAssertFalse(store.isInstalled(.fast))
        XCTAssertTrue(store.isInstalled(.reliable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("fast").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("reliable").path))
    }

    func testAutoEditFindsEarlierRepeatedTakeAndFiller() {
        let text = "Today we start. Um I think the best tools disappear. Sorry try again. The best tools disappear quickly."
        let tokens = text.split(separator: " ").enumerated().map { index, word in
            TranscribedToken(text: String(word), startTime: Double(index) * 0.3, duration: 0.22, confidence: 0.9)
        }

        let suggestions = AutoEditAnalyzer.suggestions(for: tokens)
        let removed = Set(suggestions.flatMap { Array($0.range) })
        let normalized = tokens.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let filler = normalized.firstIndex(of: "um")!
        let firstTake = normalized.firstIndex(of: "think")!
        let secondTake = normalized.lastIndex(of: "the")!

        XCTAssertTrue(removed.contains(filler))
        XCTAssertTrue(removed.contains(firstTake))
        XCTAssertFalse(removed.contains(secondTake))
    }

    func testBalancedEditProtectsOpeningAndFindsConversationalFillers() {
        let text = "So I just wanted to test this. I mean I just wanted to see if this works. You know yeah yeah"
        let tokens = text.split(separator: " ").enumerated().map { index, word in
            TranscribedToken(text: String(word), startTime: Double(index) * 0.28, duration: 0.2, confidence: 0.9)
        }
        let suggestions = AutoEditAnalyzer.suggestions(for: tokens)
        let removed = Set(suggestions.flatMap { Array($0.range) })
        let words = tokens.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }

        XCTAssertFalse(removed.contains(0), "A partial repeated opening should stay protected.")
        XCTAssertFalse(removed.contains(words.firstIndex(of: "mean")!), "Contextual phrases must not be removed by the fallback rules.")
        XCTAssertTrue(removed.contains(words.firstIndex(of: "you")!))
        XCTAssertTrue(removed.contains(words.lastIndex(of: "yeah")!))
    }

    func testFallbackAnalyzerProtectsIntentionalIMean() {
        let text = "I mean what am I supposed to do right?"
        let tokens = text.split(separator: " ").enumerated().map { index, word in
            TranscribedToken(text: String(word), startTime: Double(index) * 0.25, duration: 0.19, confidence: 0.94)
        }

        let removed = Set(AutoEditAnalyzer.suggestions(for: tokens).flatMap { Array($0.range) })

        XCTAssertFalse(removed.contains(0))
        XCTAssertFalse(removed.contains(1))
    }

    func testAutoEditRemovesInterruptedAdjacentRepeat() {
        let words = ["it", "is", "um", "it", "is", "about", "seven"]
        let tokens = words.enumerated().map { index, word in
            TranscribedToken(text: word, startTime: Double(index) * 0.25, duration: 0.18, confidence: 0.94)
        }

        let suggestions = AutoEditAnalyzer.suggestions(for: tokens)
        let repetition = suggestions.first { $0.reason == .repetition }

        XCTAssertEqual(repetition?.range, 0...2)
    }

    func testSmartEditValidatorAcceptsHighConfidenceCorrection() {
        let deletion = ContextualEditDeletion(
            startToken: 0,
            endToken: 4,
            kind: "correction",
            reason: "The speaker replaced the earlier time.",
            confidence: 0.97
        )

        let suggestions = SmartEditModelStore.validatedSuggestions(
            [deletion],
            tokenCount: 8,
            configuration: AutoEditConfiguration()
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.range, 0...4)
        XCTAssertEqual(suggestions.first?.reason, .correction)
    }

    func testSmartEditValidatorRejectsUnsafeAndDisabledRanges() {
        let candidates = [
            ContextualEditDeletion(startToken: 0, endToken: 7, kind: "correction", reason: "Deletes everything", confidence: 0.99),
            ContextualEditDeletion(startToken: 1, endToken: 2, kind: "correction", reason: "Too uncertain", confidence: 0.4),
            ContextualEditDeletion(startToken: 2, endToken: 3, kind: "filler", reason: "Disabled category", confidence: 0.99)
        ]
        var configuration = AutoEditConfiguration()
        configuration.removeFillers = false

        let suggestions = SmartEditModelStore.validatedSuggestions(
            candidates,
            tokenCount: 8,
            configuration: configuration
        )

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testSmartEditModelChoicesUseSeparateLocalModels() {
        XCTAssertEqual(SmartEditModelChoice.fast.repoID, "mlx-community/Qwen3-0.6B-4bit")
        XCTAssertEqual(SmartEditModelChoice.reliable.repoID, "mlx-community/Qwen3-1.7B-4bit")
        XCTAssertNotEqual(SmartEditModelChoice.fast.repoID, SmartEditModelChoice.reliable.repoID)
    }

    @MainActor
    func testReliableSmartEditHandlesExplicitTimeCorrection() async throws {
        guard SmartEditModelStore.shared.isInstalled(.reliable) else {
            throw XCTSkip("The Reliable Smart Edit model is not installed on this test Mac.")
        }
        let words = "Alright so um this is just another test. It is about eight PM nope sorry I mean it is um it is about seven forty two p.m. and I just wanted to uh you know test this out see how it sounds."
            .split(separator: " ")
            .map(String.init)
        let tokens = words.enumerated().map { index, word in
            TranscribedToken(
                text: word,
                startTime: Double(index) * 0.35,
                duration: 0.24,
                confidence: 0.94
            )
        }
        let store = SmartEditModelStore.shared
        store.select(.reliable)

        let contextual = try await store.contextualSuggestions(
            for: tokens,
            configuration: AutoEditConfiguration()
        )
        let suggestions = AutoEditAnalyzer.suggestions(for: tokens) + contextual
        let correction = suggestions.first { $0.reason == .correction }
        if correction == nil {
            print("SMART_EDIT_RAW=\((store.lastRawResponse ?? "nil").replacingOccurrences(of: "\n", with: "\\n"))")
            print("SMART_EDIT_SUGGESTIONS=\(suggestions.map { "\($0.range):\($0.reason.rawValue):\($0.confidence)" })")
        }

        XCTAssertNotNil(correction)
        XCTAssertEqual(correction?.range.lowerBound, words.firstIndex(of: "It"))
        XCTAssertTrue(correction?.range.contains(words.firstIndex(of: "mean")!) == true)
        XCTAssertFalse(correction?.range.contains(words.lastIndex(of: "it")!) == true)
    }

    func testAutoEditCategoryTogglesAreHonored() {
        let text = "Um keep this. Sorry redo this. Keep this sentence now. Keep this sentence now."
        let tokens = text.split(separator: " ").enumerated().map { index, word in
            TranscribedToken(text: String(word), startTime: Double(index) * 0.3, duration: 0.22, confidence: 0.9)
        }
        let configuration = AutoEditConfiguration(
            intensity: .thorough,
            removeFillers: false,
            detectRetakes: false,
            detectRestarts: true,
            protectOpening: false
        )
        let suggestions = AutoEditAnalyzer.suggestions(for: tokens, configuration: configuration)

        XCTAssertFalse(suggestions.contains { $0.reason == .filler })
        XCTAssertFalse(suggestions.contains { $0.reason == .earlierTake })
        XCTAssertTrue(suggestions.contains { $0.reason == .restart })
    }

    func testAutoEditFindsFuzzyRetakeWithOneInsertedWord() {
        let text = "I wanted to explain the simple idea clearly. Sorry let me try again. I wanted to explain this simple idea clearly."
        let tokens = text.split(separator: " ").enumerated().map { index, word in
            TranscribedToken(text: String(word), startTime: Double(index) * 0.28, duration: 0.2, confidence: 0.91)
        }

        let suggestions = AutoEditAnalyzer.suggestions(for: tokens)
        let removed = Set(suggestions.flatMap { Array($0.range) })
        let normalized = tokens.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let firstTake = normalized.firstIndex(of: "wanted")!
        let secondTake = normalized.lastIndex(of: "wanted")!

        XCTAssertTrue(removed.contains(firstTake), "The interrupted fuzzy match should be suggested.")
        XCTAssertFalse(removed.contains(secondTake), "The complete later take should remain.")
        XCTAssertTrue(suggestions.contains { $0.reason == .earlierTake && $0.confidence >= 0.8 })
    }

    func testLegitimateAgainAtSentenceOpeningIsNotARestart() {
        let text = "Again, this distinction matters for the final result."
        let tokens = text.split(separator: " ").enumerated().map { index, word in
            TranscribedToken(text: String(word), startTime: Double(index) * 0.3, duration: 0.22, confidence: 0.9)
        }

        let suggestions = AutoEditAnalyzer.suggestions(for: tokens)

        XCTAssertFalse(suggestions.contains { $0.reason == .restart })
    }

    func testEditPlannerRemovesWordsAndShortensLongPauses() {
        let words = [
            word("Keep", 0.2, 0.5),
            word("remove", 0.55, 0.9, removed: true),
            word("this", 0.92, 1.2, removed: true),
            word("Then", 3.8, 4.1),
            word("finish", 4.2, 4.6)
        ]
        let kept = AudioEditPlanner.keptRanges(words: words, duration: 5, pacing: .natural)
        let keptDuration = kept.reduce(0) { $0 + ($1.end - $1.start) }

        XCTAssertGreaterThan(kept.count, 1)
        XCTAssertLessThan(keptDuration, 3.8)
        XCTAssertFalse(kept.contains { $0.start < 0.7 && $0.end > 1.0 })
    }

    func testEditPlannerCapsWordEndToNextWordStartAtExactMaximum() {
        let words = [
            word("First", 0.2, 0.5),
            word("next", 0.75, 1.0)
        ]

        let kept = AudioEditPlanner.keptRanges(words: words, duration: 1.2, maximumPause: 0.2)
        let editedFirstEnd = AudioEditPlanner.editedTime(for: words[0].endTime, keptRanges: kept)
        let editedNextStart = AudioEditPlanner.editedTime(for: words[1].startTime, keptRanges: kept)

        XCTAssertEqual(editedNextStart - editedFirstEnd, 0.2, accuracy: 0.001)
    }

    func testEditPlannerCapsPauseAcrossRemovedWordsUsingRetainedWordBoundaries() {
        let words = [
            word("Keep", 0.2, 0.5),
            word("discard", 0.65, 1.0, removed: true),
            word("Then", 1.8, 2.1)
        ]

        let kept = AudioEditPlanner.keptRanges(words: words, duration: 2.4, maximumPause: 0.2)
        let editedKeepEnd = AudioEditPlanner.editedTime(for: words[0].endTime, keptRanges: kept)
        let editedThenStart = AudioEditPlanner.editedTime(for: words[2].startTime, keptRanges: kept)

        XCTAssertEqual(editedThenStart - editedKeepEnd, 0.2, accuracy: 0.001)
        XCTAssertFalse(kept.contains { $0.start < 0.8 && $0.end > 0.9 })
    }

    func testExplicitEmptyPauseAnalysisDoesNotBlindlyTrimTranscriptGap() {
        let words = [
            word("First", 0.2, 0.5),
            word("Next", 2.0, 2.3)
        ]

        let kept = AudioEditPlanner.keptRanges(
            words: words,
            duration: 2.5,
            maximumPause: 0.7,
            pauseDecisions: []
        )
        let firstEnd = AudioEditPlanner.editedTime(for: words[0].endTime, keptRanges: kept)
        let nextStart = AudioEditPlanner.editedTime(for: words[1].startTime, keptRanges: kept)

        XCTAssertEqual(nextStart - firstEnd, 1.5, accuracy: 0.001)
    }

    func testTightPauseSettingHonorsCapWhenAcousticAnalysisIsInconclusive() {
        let words = [word("First", 0.2, 0.5), word("Next", 2.0, 2.3)]

        let kept = AudioEditPlanner.keptRanges(
            words: words,
            duration: 2.5,
            maximumPause: 0.2,
            pauseDecisions: []
        )
        let firstEnd = AudioEditPlanner.editedTime(for: 0.5, keptRanges: kept)
        let nextStart = AudioEditPlanner.editedTime(for: 2.0, keptRanges: kept)

        XCTAssertEqual(nextStart - firstEnd, 0.2, accuracy: 0.001)
    }

    func testRemovedPhraseRecomputesRetainedBoundaryWithExplicitPauseAnalysis() {
        let words = [
            word("Keep", 0.2, 0.5),
            word("remove", 0.8, 1.2, removed: true),
            word("this", 1.4, 1.8, removed: true),
            word("Next", 3.0, 3.3)
        ]

        let kept = AudioEditPlanner.keptRanges(
            words: words,
            duration: 3.5,
            maximumPause: 0.7,
            pauseDecisions: []
        )
        let keepEnd = AudioEditPlanner.editedTime(for: 0.5, keptRanges: kept)
        let nextStart = AudioEditPlanner.editedTime(for: 3.0, keptRanges: kept)

        XCTAssertLessThanOrEqual(nextStart - keepEnd, 0.7 + 0.001)
        XCTAssertGreaterThan(nextStart - keepEnd, 0)
    }

    func testPauseAnalyzerConfirmsSilenceAndRejectsUntranscribedAudio() {
        let sampleRate = 16_000.0
        let words = [
            word("First.", 0.1, 0.6),
            word("Next", 2.0, 2.5)
        ]
        var quietSamples = [Float](repeating: 0.002, count: Int(sampleRate * 2.6))
        addSine(to: &quietSamples, sampleRate: sampleRate, range: 0.1..<0.6, amplitude: 0.2)
        addSine(to: &quietSamples, sampleRate: sampleRate, range: 2.0..<2.5, amplitude: 0.2)

        let confirmed = PauseAnalyzer.analyze(
            samples: quietSamples,
            sampleRate: sampleRate,
            words: words,
            maximumPause: 0.7
        )
        XCTAssertEqual(confirmed.count, 1)
        XCTAssertGreaterThanOrEqual(confirmed[0].confidence, 0.8)

        var eventSamples = quietSamples
        addSine(to: &eventSamples, sampleRate: sampleRate, range: 1.05..<1.35, amplitude: 0.12)
        let rejected = PauseAnalyzer.analyze(
            samples: eventSamples,
            sampleRate: sampleRate,
            words: words,
            maximumPause: 0.7
        )
        XCTAssertTrue(rejected.isEmpty, "A missed word, laugh, or other event must protect the gap.")
    }

    func testProtectedPauseStaysAtOriginalDuration() {
        let words = [word("First", 0.2, 0.5), word("Next", 2.0, 2.3)]
        let pause = PauseEditDecision(
            sourceStart: 0.5,
            sourceEnd: 2.0,
            confidence: 0.95,
            reason: "Confirmed silent pause",
            isProtected: true
        )
        let kept = AudioEditPlanner.keptRanges(
            words: words,
            duration: 2.5,
            maximumPause: 0.7,
            pauseDecisions: [pause]
        )

        let firstEnd = AudioEditPlanner.editedTime(for: 0.5, keptRanges: kept)
        let nextStart = AudioEditPlanner.editedTime(for: 2.0, keptRanges: kept)
        XCTAssertEqual(nextStart - firstEnd, 1.5, accuracy: 0.001)
    }

    func testAnalysisFirstPassIsExactlyTimelineAligned() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetFirstPassTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.wav")
        let firstPass = folder.appendingPathComponent("first-pass.wav")
        try makeTone(at: source, duration: 0.8)

        let report = try AnalysisFirstPassRenderer.render(sourceURL: source, destinationURL: firstPass)
        let original = try AVAudioFile(forReading: source)
        let processed = try AVAudioFile(forReading: firstPass)

        XCTAssertEqual(processed.processingFormat.sampleRate, original.processingFormat.sampleRate)
        XCTAssertEqual(processed.length, original.length)
        XCTAssertEqual(report.frameAlignmentError, 0, accuracy: 1 / original.processingFormat.sampleRate)
    }

    func testSpeechTimingRefinerRemovesDecoderBlankFramesFromWordEnd() {
        let sampleRate = 16_000.0
        var samples = [Float](repeating: 0.002, count: Int(sampleRate * 1.4))
        addSine(to: &samples, sampleRate: sampleRate, range: 0.1..<0.38, amplitude: 0.2)
        addSine(to: &samples, sampleRate: sampleRate, range: 1.0..<1.3, amplitude: 0.2)
        let tokens = [
            TranscribedToken(text: "First", startTime: 0.1, duration: 0.9, confidence: 0.9),
            TranscribedToken(text: "Next", startTime: 1.0, duration: 0.3, confidence: 0.9)
        ]

        let refined = SpeechTimingRefiner.refine(tokens, samples: samples, sampleRate: sampleRate)
        let refinedEnd = refined[0].startTime + refined[0].duration

        XCTAssertEqual(refinedEnd, 0.42, accuracy: 0.04)
        XCTAssertGreaterThan(tokens[0].duration - refined[0].duration, 0.5)
    }

    func testSpeechTimingRefinerDoesNotTreatBreathLikeNoiseAsWordTail() {
        let sampleRate = 16_000.0
        var samples = [Float](repeating: 0.002, count: Int(sampleRate * 1.4))
        addSine(to: &samples, sampleRate: sampleRate, range: 0.1..<0.38, amplitude: 0.2)
        addAlternatingNoise(to: &samples, sampleRate: sampleRate, range: 0.58..<0.82, amplitude: 0.025)
        addSine(to: &samples, sampleRate: sampleRate, range: 1.0..<1.3, amplitude: 0.2)
        let tokens = [
            TranscribedToken(text: "First", startTime: 0.1, duration: 0.9, confidence: 0.9),
            TranscribedToken(text: "Next", startTime: 1.0, duration: 0.3, confidence: 0.9)
        ]

        let refined = SpeechTimingRefiner.refine(tokens, samples: samples, sampleRate: sampleRate)

        XCTAssertLessThan(refined[0].startTime + refined[0].duration, 0.5)
    }

    func testSpeechTimingRefinerRemovesTrailingBlankFramesFromFinalWord() {
        let sampleRate = 16_000.0
        var samples = [Float](repeating: 0.002, count: Int(sampleRate * 1.4))
        addSine(to: &samples, sampleRate: sampleRate, range: 0.15..<0.48, amplitude: 0.2)
        let token = TranscribedToken(text: "Finally", startTime: 0.15, duration: 1.0, confidence: 0.9)

        let refined = SpeechTimingRefiner.refine([token], samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(refined[0].startTime + refined[0].duration, 0.52, accuracy: 0.05)
    }

    func testDiskBackedSpeechTimingRefinerMatchesInMemoryResult() throws {
        let sampleRate = 16_000.0
        var samples = [Float](repeating: 0.002, count: Int(sampleRate * 1.4))
        addSine(to: &samples, sampleRate: sampleRate, range: 0.1..<0.38, amplitude: 0.2)
        addAlternatingNoise(to: &samples, sampleRate: sampleRate, range: 0.58..<0.82, amplitude: 0.025)
        addSine(to: &samples, sampleRate: sampleRate, range: 1.0..<1.3, amplitude: 0.2)
        let tokens = [
            TranscribedToken(text: "First", startTime: 0.1, duration: 0.9, confidence: 0.9),
            TranscribedToken(text: "Next", startTime: 1.0, duration: 0.3, confidence: 0.9)
        ]
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetTimingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audioURL = folder.appendingPathComponent("timing.wav")
        try write(samples: samples, sampleRate: sampleRate, to: audioURL)

        let memoryResult = SpeechTimingRefiner.refine(tokens, samples: samples, sampleRate: sampleRate)
        let diskResult = try SpeechTimingRefiner.refine(tokens, audioURL: audioURL)

        XCTAssertEqual(diskResult.map(\.startTime), memoryResult.map(\.startTime))
        XCTAssertEqual(diskResult.map(\.duration), memoryResult.map(\.duration))
    }

    func testTranscriptionMergerRecoversOnlyMissingHesitations() {
        let primary = [
            TranscribedToken(text: "This", startTime: 0.1, duration: 0.3, confidence: 0.9),
            TranscribedToken(text: "works", startTime: 1.0, duration: 0.3, confidence: 0.9)
        ]
        let original = [
            TranscribedToken(text: "This", startTime: 0.1, duration: 0.3, confidence: 0.88),
            TranscribedToken(text: "um", startTime: 0.58, duration: 0.24, confidence: 0.88),
            TranscribedToken(text: "works", startTime: 1.0, duration: 0.3, confidence: 0.88)
        ]

        let merged = TranscriptionMerger.recoverHesitations(primary: primary, original: original)

        XCTAssertEqual(merged.map(\.text), ["This", "um", "works"])
    }

    func testTranscriptionMergerDoesNotDuplicateExistingHesitation() {
        let primary = [TranscribedToken(text: "Um", startTime: 0.5, duration: 0.2, confidence: 0.9)]
        let original = [TranscribedToken(text: "um", startTime: 0.54, duration: 0.22, confidence: 0.85)]

        XCTAssertEqual(
            TranscriptionMerger.recoverHesitations(primary: primary, original: original).count,
            1
        )
    }

    func testEditPlannerTrimsRecordingEdgesFromTranscriptWithSafetyBuffer() {
        let words = [
            word("First", 1.0, 1.4),
            word("last", 3.0, 3.5)
        ]

        let kept = AudioEditPlanner.keptRanges(words: words, duration: 5, pacing: .natural)

        XCTAssertFalse(kept.isEmpty)
        XCTAssertEqual(kept[0].start, 0.85, accuracy: 0.001)
        XCTAssertEqual(kept[kept.count - 1].end, 3.65, accuracy: 0.001)
    }

    func testEditPlannerUsesFirstRetainedWordForLeadingTrim() {
        let words = [
            word("Discard", 0.5, 1.1, removed: true),
            word("Begin", 2.0, 2.5),
            word("here", 2.6, 3.0)
        ]

        let kept = AudioEditPlanner.keptRanges(words: words, duration: 4, pacing: .tighter)

        XCTAssertFalse(kept.isEmpty)
        XCTAssertEqual(kept[0].start, 1.85, accuracy: 0.001)
    }

    func testUntouchedPacingPreservesRecordingEdges() {
        let words = [word("Middle", 1.0, 2.0)]

        let kept = AudioEditPlanner.keptRanges(words: words, duration: 3, pacing: .untouched)

        XCTAssertEqual(kept, [AudioTimeRange(start: 0, end: 3)])
    }

    func testEditPlannerReturnsNoAudioWhenEveryTranscriptWordIsRemoved() {
        let words = [
            word("Remove", 0.5, 1.0, removed: true),
            word("everything", 1.1, 1.8, removed: true)
        ]

        XCTAssertTrue(AudioEditPlanner.keptRanges(words: words, duration: 3, pacing: .natural).isEmpty)
        XCTAssertTrue(AudioEditPlanner.keptRanges(words: words, duration: 3, pacing: .untouched).isEmpty)
    }

    func testEditedAudioRendererProducesShorterPlayableWave() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.wav")
        let edited = folder.appendingPathComponent("edited.wav")
        try makeTone(at: source, duration: 2)

        try EditedAudioRenderer.render(
            sourceURL: source,
            destinationURL: edited,
            keptRanges: [
                AudioTimeRange(start: 0, end: 0.55),
                AudioTimeRange(start: 1.25, end: 2)
            ]
        )

        let input = try AVAudioFile(forReading: source)
        let output = try AVAudioFile(forReading: edited)
        XCTAssertGreaterThan(output.length, 0)
        XCTAssertLessThan(output.length, input.length * 3 / 4)
    }

    func testEditedAudioRendererToleratesTruncatedFinalCompressedPacket() throws {
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("test_42.m4a")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("test_42.m4a is not available in this checkout.")
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetTruncatedPacketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let input = try AVAudioFile(forReading: source)
        let duration = Double(input.length) / input.processingFormat.sampleRate
        let edited = folder.appendingPathComponent("edited.wav")
        try EditedAudioRenderer.render(
            sourceURL: source,
            destinationURL: edited,
            keptRanges: [AudioTimeRange(start: 0, end: duration)]
        )

        let output = try AVAudioFile(forReading: edited)
        XCTAssertGreaterThan(output.length, input.length - 32_768)
        XCTAssertLessThanOrEqual(output.length, input.length)
    }

    func testNativePolishChainRendersPlayableAudio() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetPolishTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.wav")
        let finished = folder.appendingPathComponent("finished.wav")
        try makeTone(at: source, duration: 1.2)
        try await VoicePolisher.render(
            sourceURL: source,
            destinationURL: finished,
            options: AudioRenderOptions(
                pacing: .natural,
                reduceNoise: false,
                voiceEQ: true,
                deEss: true,
                compression: true,
                forceMono: false,
                breathControl: true,
                normalizeLoudness: true,
                loudnessPreset: .podcast
            )
        )

        let output = try AVAudioFile(forReading: finished)
        XCTAssertGreaterThan(output.length, 40_000)
        let loudness = try LoudnessAnalyzer.measure(url: finished)
        XCTAssertEqual(loudness.integratedLUFS, LoudnessPreset.podcast.targetLUFS, accuracy: 1.0)
        XCTAssertLessThanOrEqual(loudness.peakDBFS, LoudnessPreset.podcast.peakCeilingDBFS + 0.1)
    }

    func testBreathControlGentlyAttenuatesDetectedBreath() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetBreathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("breath-source.wav")
        let controlled = folder.appendingPathComponent("breath-controlled.wav")
        try makeBreathFixture(at: source)

        let result = try BreathController.process(
            dryReferenceURL: source,
            sourceURL: source,
            destinationURL: controlled
        )
        XCTAssertGreaterThan(result.count, 0)

        let inputWindows = try BreathDetector.signatures(for: source)
        let outputWindows = try BreathDetector.signatures(for: controlled)
        let breathGains = zip(inputWindows, outputWindows).compactMap { input, output -> Double? in
            let midpoint = (input.range.start + input.range.end) / 2
            guard result.regions.contains(where: { midpoint >= $0.start && midpoint <= $0.end }) else { return nil }
            return output.rmsDB - input.rmsDB
        }
        XCTAssertFalse(breathGains.isEmpty)
        XCTAssertLessThan(breathGains.reduce(0, +) / Double(breathGains.count), -0.5)
    }

    func testSubtitleTimestampsFollowTheEditedTimeline() {
        let words = [
            word("First", 0.2, 0.7),
            word("discarded", 1.0, 2.8, removed: true),
            word("Second", 3.2, 3.8)
        ]
        let ranges = AudioEditPlanner.keptRanges(words: words, duration: 4, pacing: .untouched)
        let srt = SubtitleRenderer.srt(words: words.filter { !$0.isRemoved }, keptRanges: ranges)

        XCTAssertTrue(srt.contains("First Second"))
        XCTAssertFalse(srt.contains("discarded"))
        XCTAssertEqual(AudioEditPlanner.editedTime(for: 3.2, keptRanges: ranges), 1.35, accuracy: 0.001)
        XCTAssertTrue(srt.contains("00:00:01,950"), srt)
        XCTAssertEqual(AudioEditPlanner.editedDuration(for: ranges), 2.15, accuracy: 0.001)
    }

    func testRealRecordingExportsSynchronizedPackage() async throws {
        let workspaceSource = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("short_Test Recording.m4a")
        let source = FileManager.default.fileExists(atPath: workspaceSource.path)
            ? workspaceSource
            : Bundle(for: Self.self).url(forResource: "short_Test Recording", withExtension: "m4a")
        guard let source else {
            throw XCTSkip("The supplied recording fixture is not present.")
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetPackageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let sourceFile = try AVAudioFile(forReading: source)
        let sourceDuration = Double(sourceFile.length) / sourceFile.processingFormat.sampleRate
        let analysis = try AudioSignalAnalyzer.analyze(url: source)
        XCTAssertTrue((-120 ... 0).contains(analysis.noiseFloorDB))
        XCTAssertTrue((-120 ... 0).contains(analysis.speechLevelDB))
        XCTAssertTrue((0 ... 1).contains(analysis.sibilanceScore))
        XCTAssertTrue((0 ... 1).contains(analysis.presenceScore))
        let words = [
            word("Keep", 0.4, 1.0),
            word("remove", 4.0, 5.0, removed: true),
            word("this", 5.1, 5.6, removed: true),
            word("Finish", 8.0, 8.7)
        ]
        let renderOptions = AudioRenderOptions(
            pacing: .natural,
            reduceNoise: false,
            voiceEQ: true,
            deEss: true,
            compression: true,
            forceMono: true,
            breathControl: true,
            normalizeLoudness: true,
            loudnessPreset: .podcast
        )
        let request = ExportPackageRequest(
            folder: folder,
            baseName: "integration",
            sourceURL: source,
            words: words,
            duration: sourceDuration,
            renderOptions: renderOptions,
            includeAudio: true,
            includeOriginal: true,
            includeTXT: true,
            includeSRT: true,
            includeVTT: true
        )

        let exported = try await ExportPackageRenderer.render(request)
        let finishedAudio = exported.appendingPathComponent("integration-finished.wav")
        let originalAudio = exported.appendingPathComponent("integration-original.m4a")
        let output = try AVAudioFile(forReading: finishedAudio)
        let outputDuration = Double(output.length) / output.processingFormat.sampleRate
        let sourceLoudness = try LoudnessAnalyzer.measure(url: source)
        let outputLoudness = try LoudnessAnalyzer.measure(url: finishedAudio)
        print(String(format: "Real recording loudness: %.2f LUFS / %.2f dB peak → %.2f LUFS / %.2f dB peak", sourceLoudness.integratedLUFS, sourceLoudness.peakDBFS, outputLoudness.integratedLUFS, outputLoudness.peakDBFS))
        let transcript = try String(contentsOf: exported.appendingPathComponent("integration.txt"), encoding: .utf8)
        let subtitles = try String(contentsOf: exported.appendingPathComponent("integration.srt"), encoding: .utf8)
        let webVTT = try String(contentsOf: exported.appendingPathComponent("integration.vtt"), encoding: .utf8)

        XCTAssertEqual(transcript, "Keep Finish")
        XCTAssertEqual(try Data(contentsOf: originalAudio), try Data(contentsOf: source))
        XCTAssertFalse(subtitles.contains("remove"))
        XCTAssertTrue(webVTT.hasPrefix("WEBVTT\n\n"))
        XCTAssertGreaterThan(outputDuration, 0)
        XCTAssertLessThan(outputDuration, sourceDuration)
        XCTAssertEqual(output.processingFormat.channelCount, 1)
        XCTAssertGreaterThan(outputLoudness.integratedLUFS, sourceLoudness.integratedLUFS)
        XCTAssertEqual(outputLoudness.integratedLUFS, LoudnessPreset.podcast.targetLUFS, accuracy: 1.5)
        XCTAssertLessThanOrEqual(outputLoudness.peakDBFS, LoudnessPreset.podcast.peakCeilingDBFS + 0.1)

        let dry = folder.appendingPathComponent("quality-dry.wav")
        let qualityOutput = folder.appendingPathComponent("quality-polished.wav")
        let ranges = AudioEditPlanner.keptRanges(words: words, duration: sourceDuration, pacing: .natural)
        try EditedAudioRenderer.render(sourceURL: source, destinationURL: dry, keptRanges: ranges)
        let report = try await VoicePolisher.render(
            sourceURL: dry,
            destinationURL: qualityOutput,
            options: renderOptions
        )
        print("Real recording post-check: \(report.quality.summary); gentle retry: \(report.quality.usedGentleCompression); controlled breaths: \(report.breathControl?.count ?? 0)")
        XCTAssertTrue(report.quality.passed, report.quality.summary)
        XCTAssertLessThanOrEqual(report.quality.breathLiftDB, 2.5)
    }

    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval, removed: Bool = false) -> TranscriptWord {
        TranscriptWord(
            id: UUID(),
            text: text,
            startTime: start,
            endTime: end,
            reason: removed ? "Test" : nil,
            isRemoved: removed,
            wasSuggested: removed
        )
    }

    private func makeTone(at url: URL, duration: TimeInterval) throws {
        let sampleRate = 48_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let blockSize: AVAudioFrameCount = 4096
        var written: AVAudioFrameCount = 0
        while written < frameCount {
            let count = min(blockSize, frameCount - written)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            let samples = buffer.floatChannelData![0]
            for index in 0..<Int(count) {
                let absolute = Double(written + AVAudioFrameCount(index))
                samples[index] = Float(sin(2 * .pi * 220 * absolute / sampleRate) * 0.2)
            }
            try file.write(from: buffer)
            written += count
        }
    }

    private func addSine(
        to samples: inout [Float],
        sampleRate: Double,
        range: Range<TimeInterval>,
        amplitude: Float
    ) {
        let start = max(0, Int(range.lowerBound * sampleRate))
        let end = min(samples.count, Int(range.upperBound * sampleRate))
        for index in start..<end {
            samples[index] += amplitude * Float(sin(2 * .pi * 180 * Double(index) / sampleRate))
        }
    }

    private func addAlternatingNoise(
        to samples: inout [Float],
        sampleRate: Double,
        range: Range<TimeInterval>,
        amplitude: Float
    ) {
        let start = max(0, Int(range.lowerBound * sampleRate))
        let end = min(samples.count, Int(range.upperBound * sampleRate))
        for index in start..<end {
            samples[index] += index.isMultiple(of: 2) ? amplitude : -amplitude
        }
    }

    private func write(samples: [Float], sampleRate: Double, to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let capacity = AVAudioFrameCount(samples.count)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        buffer.frameLength = capacity
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData!.pointee.update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    private func makeTalkingHeadFixture(at destination: URL, duration: TimeInterval) async throws {
        let folder = destination.deletingLastPathComponent()
        let videoOnly = folder.appendingPathComponent("video-only.mov")
        let audioOnly = folder.appendingPathComponent("audio-only.wav")
        try makeTone(at: audioOnly, duration: duration)

        let writer = try AVAssetWriter(outputURL: videoOnly, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(duration * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
                &pixel
            )
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, frame % 2 == 0 ? 32 : 48, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }

        let videoAsset = AVURLAsset(url: videoOnly)
        let audioAsset = AVURLAsset(url: audioOnly)
        let composition = AVMutableComposition()
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        let compositionVideo = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let compositionAudio = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try compositionVideo.insertTimeRange(range, of: videoTrack, at: .zero)
        try compositionAudio.insertTimeRange(range, of: audioTrack, at: .zero)
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        try await exporter.export(to: destination, as: .mov)
    }

    private func makeBreathFixture(at url: URL) throws {
        let sampleRate = 48_000.0
        let duration = 2.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let blockSize: AVAudioFrameCount = 4_096
        var written: AVAudioFrameCount = 0
        var randomState: UInt64 = 0x1234_5678

        while written < frameCount {
            let count = min(blockSize, frameCount - written)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            let samples = buffer.floatChannelData![0]
            for index in 0..<Int(count) {
                let absolute = Double(written + AVAudioFrameCount(index))
                let time = absolute / sampleRate
                if (0.15 ... 0.70).contains(time) || (1.10 ... 1.75).contains(time) {
                    samples[index] = Float(sin(2 * .pi * 190 * absolute / sampleRate) * 0.20)
                } else if (0.76 ... 0.98).contains(time) {
                    randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
                    let noise = Double(Int32(truncatingIfNeeded: randomState >> 32)) / Double(Int32.max)
                    samples[index] = Float(noise * 0.035)
                } else {
                    samples[index] = 0
                }
            }
            try file.write(from: buffer)
            written += count
        }
    }
}
