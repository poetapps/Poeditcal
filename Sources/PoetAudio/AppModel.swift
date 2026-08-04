import AppKit
import AVFoundation
import Foundation
import SwiftUI

enum WorkflowPhase: String, Hashable, Codable, Sendable {
    case welcome
    case setup
    case processing
    case edit
    case polish
    case export
}

enum EditingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case autopilot = "Autopilot"
    case fullControl = "Full control"
    var id: String { rawValue }
}

enum PacingPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case natural = "Natural"
    case tighter = "Tighter"
    case untouched = "Untouched"
    var id: String { rawValue }

    var detail: String {
        switch self {
        case .natural: "Trim transcript edges and keep pauses up to 1.2 seconds"
        case .tighter: "Trim transcript edges and keep pauses up to 0.7 seconds"
        case .untouched: "Keep the recording’s original pacing"
        }
    }

    var maximumPause: TimeInterval? {
        switch self {
        case .natural: 1.2
        case .tighter: 0.7
        case .untouched: nil
        }
    }
}

enum PolishOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case noise = "Reduce noise"
    case eq = "Voice EQ"
    case deEss = "De-ess"
    case compression = "Compress"
    case forceMono = "Force mono"
    case breathControl = "Breath control"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .noise: "waveform.badge.minus"
        case .eq: "slider.horizontal.3"
        case .deEss: "wind"
        case .compression: "arrow.up.and.down.and.arrow.left.and.right"
        case .forceMono: "speaker.wave.2"
        case .breathControl: "lungs.fill"
        }
    }

    var detail: String {
        switch self {
        case .noise: "Locally remove room tone and fan noise, including underneath speech."
        case .eq: "Balance warmth and clarity for a more natural voice."
        case .deEss: "Soften sharp S and T sounds only where needed."
        case .compression: "Even out level changes without flattening expression."
        case .forceMono: "Combine every channel into one centered, upload-safe voice track."
        case .breathControl: "Gently tuck detected breaths without making the performance sound edited."
        }
    }
}

enum PolishIntensity: Int, CaseIterable, Identifiable, Codable, Sendable {
    case light = 0
    case balanced = 1
    case strong = 2
    case maximum = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .light: "Light"
        case .balanced: "Balanced"
        case .strong: "Strong"
        case .maximum: "Max"
        }
    }

    var amount: Double {
        switch self {
        case .light: 0.28
        case .balanced: 0.50
        case .strong: 0.74
        case .maximum: 1.0
        }
    }

    var breathAttenuationDB: Double {
        switch self {
        case .light: -0.9
        case .balanced: -1.6
        case .strong: -2.4
        case .maximum: -3.4
        }
    }
}

enum PolishPreviewMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case before = "Before"
    case polished = "Polished"
    var id: String { rawValue }
}

struct TranscriptWord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let reason: String?
    var isRemoved: Bool
    var wasSuggested: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: WorkflowPhase = .welcome
    @Published var editingMode: EditingMode = .autopilot
    @Published var autoEditConfiguration = AutoEditConfiguration()
    @Published var pacing: PacingPreset = .natural
    @Published var pauseDuration: Double = 0.7
    @Published var audioURL: URL?
    @Published var fileName = ""
    @Published var duration: TimeInterval = 0
    @Published var processingProgress = 0.0
    @Published var processingLabel = "Preparing your audio"
    @Published var processingTip = "A little room tone helps noise reduction sound more natural."
    @Published var processingError: String?
    @Published var isDemoTranscript = false
    @Published var words: [TranscriptWord] = []
    @Published var currentTime: TimeInterval = 0
    @Published var isPlaying = false
    @Published var polishSelections: Set<PolishOption> = Set(
        PolishOption.allCases.filter { $0 != .noise || DenoiseModelStore.installedModelIsValid() }
    )
    @Published var polishIntensities: [PolishOption: PolishIntensity] = AppModel.defaultPolishIntensities
    @Published var usePolish = true
    @Published var loudnessPreset: LoudnessPreset = .podcast
    @Published var exportAudio = true
    @Published var exportTXT = true
    @Published var exportSRT = true
    @Published var exportVTT = false
    @Published var exportStatus: String?
    @Published var isExporting = false
    @Published var exportProgress = 0.0
    @Published var voiceAnalysis: VoiceAnalysis?
    @Published var polishPreviewMode: PolishPreviewMode = .polished
    @Published var isPreparingPolishPreview = false
    @Published var isShowingPolishPreview = false
    @Published var polishPreviewError: String?
    @Published var sourceLoudness: LoudnessMeasurement?
    @Published var polishedLoudness: LoudnessMeasurement?
    @Published var polishQualityReport: PolishQualityReport?
    @Published var breathControlResult: BreathControlResult?
    @Published var polishCurrentStage: String?
    @Published var polishStageTimings: [PolishStageUpdate] = []
    @Published var projectName = "Untitled Project"
    @Published var projectURL: URL?
    @Published var projectStatus: String?
    @Published var isSavingProject = false
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordingLevel: Float = 0
    @Published var recordingError: String?
    @Published private(set) var selectedWordIDs: Set<UUID> = []
    @Published private(set) var canUndoRestoreAll = false

    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private let speechTranscriber = LocalSpeechTranscriber()
    private var securityScopedURL: URL?
    private var selectionAnchorID: UUID?
    private var polishPreviewTask: Task<Void, Never>?
    private var polishPreviewFolder: URL?
    private var dryPreviewURL: URL?
    private var polishedPreviewURL: URL?
    private var polishPreviewSignature: String?
    private var polishRenderID: UUID?
    private var playbackUsesEditedTimeline = false
    private var recorder: AVAudioRecorder?
    private var recordingTask: Task<Void, Never>?
    private var recordingURL: URL?
    private var restoreAllSnapshot: [Bool]?

    private static let defaultPolishIntensities: [PolishOption: PolishIntensity] = [
        .noise: .balanced,
        .eq: .balanced,
        .deEss: .balanced,
        .compression: .light,
        .breathControl: .balanced
    ]

    var activeStep: Int {
        switch phase {
        case .welcome, .setup, .processing, .edit: 0
        case .polish: 1
        case .export: 2
        }
    }

    var removedWords: Int { words.filter(\.isRemoved).count }
    var restoredWords: Int { words.filter { $0.wasSuggested && !$0.isRemoved }.count }
    var originalWordCount: Int { words.count }
    var editedWordCount: Int { words.filter { !$0.isRemoved }.count }
    var selectedWordCount: Int { selectedWordIDs.count }
    var estimatedEditedDuration: TimeInterval {
        AudioEditPlanner.editedDuration(for: currentKeptRanges)
    }

    var editedTranscript: String {
        words.filter { !$0.isRemoved }.map(\.text).joined(separator: " ")
    }

    var hasExportSelection: Bool { exportAudio || exportTXT || exportSRT || exportVTT }
    var enabledPolishCount: Int { usePolish ? polishSelections.count : 0 }
    var hasAppliedPolishPreview: Bool {
        polishPreviewSignature == currentPolishSignature && polishedPreviewURL != nil
    }
    var hasUnappliedPolishChanges: Bool { usePolish && !hasAppliedPolishPreview }

    private var currentKeptRanges: [AudioTimeRange] {
        AudioEditPlanner.keptRanges(words: words, duration: duration, maximumPause: pauseDuration)
    }

    func loadAudio(_ url: URL) {
        stopPlayback()
        discardPolishPreview()
        processingTask?.cancel()
        speechTranscriber.cancel()
        if let securityScopedURL { securityScopedURL.stopAccessingSecurityScopedResource() }
        if url.startAccessingSecurityScopedResource() { securityScopedURL = url }
        else { securityScopedURL = nil }
        audioURL = url
        projectURL = nil
        projectName = url.deletingPathExtension().lastPathComponent
        projectStatus = nil
        exportAudio = true
        fileName = url.lastPathComponent
        exportStatus = nil
        processingError = nil
        isDemoTranscript = false
        voiceAnalysis = nil
        sourceLoudness = nil
        polishedLoudness = nil
        polishQualityReport = nil
        breathControlResult = nil
        selectionAnchorID = nil
        selectedWordIDs = []
        playbackUsesEditedTimeline = false

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
        } catch {
            player = nil
            duration = 0
        }

        phase = .setup
    }

    func openURL(_ url: URL) {
        if url.pathExtension.lowercased() == "poe" { openProject(url) }
        else { loadAudio(url) }
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open a Poet project"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.poetProject]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }

    func openProject(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        projectStatus = "Opening project…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try PoetProjectStore.load(from: url)
                }.value
                installProject(loaded.snapshot, audioURL: loaded.audioURL, packageURL: url, accessed: accessed)
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                projectStatus = "Couldn’t open project: \(error.localizedDescription)"
            }
        }
    }

    func saveProject() {
        if let projectURL { saveProject(to: projectURL) }
        else { saveProjectAs() }
    }

    func saveProjectAs() {
        guard audioURL != nil else { return }
        let panel = NSSavePanel()
        panel.title = "Save Poet project"
        panel.prompt = "Save Project"
        panel.allowedContentTypes = [.poetProject]
        panel.canCreateDirectories = true
        let fallback = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = "\(fallback.isEmpty ? "Untitled Project" : fallback).poe"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveProject(to: url)
    }

    private func saveProject(to url: URL) {
        guard let sourceURL = audioURL, !isSavingProject else { return }
        let cleanName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        projectName = cleanName.isEmpty ? "Untitled Project" : cleanName
        let audioExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension.lowercased()
        let sourceAudioFile = "Source Audio.\(audioExtension)"
        let snapshot = PoetProjectSnapshot(
            projectName: projectName,
            sourceAudioFile: sourceAudioFile,
            sourceDisplayName: fileName,
            phase: phase,
            editingMode: editingMode,
            autoEditConfiguration: autoEditConfiguration,
            pacing: pacing,
            pauseDuration: pauseDuration,
            duration: duration,
            words: words,
            polishSelections: polishSelections,
            polishIntensities: polishIntensities,
            usePolish: usePolish,
            loudnessPreset: loudnessPreset,
            exportAudio: exportAudio,
            exportTXT: exportTXT,
            exportSRT: exportSRT,
            exportVTT: exportVTT
        )
        isSavingProject = true
        projectStatus = "Saving project…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let savedURL = try await Task.detached(priority: .userInitiated) {
                    try PoetProjectStore.save(snapshot: snapshot, sourceAudioURL: sourceURL, to: url)
                }.value
                let savedAudioURL = savedURL.appendingPathComponent(sourceAudioFile)
                if let securityScopedURL { securityScopedURL.stopAccessingSecurityScopedResource() }
                _ = savedURL.startAccessingSecurityScopedResource()
                securityScopedURL = savedURL
                projectURL = savedURL
                audioURL = savedAudioURL
                if phase == .setup || phase == .edit { loadPlayer(url: savedAudioURL, usesEditedTimeline: false) }
                projectStatus = "Saved \(savedURL.lastPathComponent)"
            } catch {
                projectStatus = "Couldn’t save project: \(error.localizedDescription)"
            }
            isSavingProject = false
        }
    }

    private func installProject(
        _ snapshot: PoetProjectSnapshot,
        audioURL loadedAudioURL: URL,
        packageURL: URL,
        accessed: Bool
    ) {
        stopPlayback()
        discardPolishPreview()
        processingTask?.cancel()
        speechTranscriber.cancel()
        if let securityScopedURL { securityScopedURL.stopAccessingSecurityScopedResource() }
        securityScopedURL = accessed ? packageURL : nil
        projectURL = packageURL
        projectName = snapshot.projectName
        audioURL = loadedAudioURL
        fileName = snapshot.sourceDisplayName
        duration = snapshot.duration
        editingMode = snapshot.editingMode
        autoEditConfiguration = snapshot.autoEditConfiguration
        pacing = snapshot.pacing
        pauseDuration = snapshot.pauseDuration ?? snapshot.pacing.maximumPause ?? 2.0
        words = snapshot.words
        polishSelections = snapshot.polishSelections
        polishIntensities = snapshot.polishIntensities ?? Self.defaultPolishIntensities
        usePolish = snapshot.usePolish
        loudnessPreset = snapshot.loudnessPreset
        exportAudio = snapshot.exportAudio
        exportTXT = snapshot.exportTXT
        exportSRT = snapshot.exportSRT
        exportVTT = snapshot.exportVTT
        isDemoTranscript = false
        processingError = nil
        exportStatus = nil
        voiceAnalysis = nil
        sourceLoudness = nil
        polishedLoudness = nil
        polishQualityReport = nil
        breathControlResult = nil
        selectionAnchorID = nil
        selectedWordIDs = []
        playbackUsesEditedTimeline = false
        phase = snapshot.words.isEmpty ? .setup : normalizedRestoredPhase(snapshot.phase)
        loadPlayer(url: loadedAudioURL, usesEditedTimeline: false)
        projectStatus = "Opened \(packageURL.lastPathComponent)"
    }

    private func normalizedRestoredPhase(_ savedPhase: WorkflowPhase) -> WorkflowPhase {
        switch savedPhase {
        case .welcome, .setup, .processing: .edit
        case .edit, .polish, .export: savedPhase
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        recordingError = nil
        Task { [weak self] in
            guard let self else { return }
            let permission = AVCaptureDevice.authorizationStatus(for: .audio)
            let granted: Bool
            if permission == .notDetermined {
                granted = await AVCaptureDevice.requestAccess(for: .audio)
            } else {
                granted = permission == .authorized
            }
            guard granted else {
                recordingError = "Microphone access is off. Enable it for Poet Audio in System Settings → Privacy & Security → Microphone."
                return
            }
            beginRecording()
        }
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Poet Recording \(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 192_000
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            guard recorder.record() else {
                throw CocoaError(.fileWriteUnknown)
            }
            self.recorder = recorder
            recordingURL = url
            recordingDuration = 0
            recordingLevel = 0
            isRecording = true
            recordingTask?.cancel()
            recordingTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled, let recorder = self.recorder, recorder.isRecording {
                    recorder.updateMeters()
                    recordingDuration = recorder.currentTime
                    let decibels = recorder.averagePower(forChannel: 0)
                    recordingLevel = max(0, min(1, (decibels + 55) / 55))
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        } catch {
            recordingError = "Couldn’t start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard let url = recordingURL else { return }
        recorder?.stop()
        recordingTask?.cancel()
        recorder = nil
        recordingTask = nil
        recordingURL = nil
        isRecording = false
        recordingLevel = 0
        loadAudio(url)
    }

    func cancelRecording() {
        recorder?.stop()
        recordingTask?.cancel()
        recorder = nil
        recordingTask = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        isRecording = false
        recordingDuration = 0
        recordingLevel = 0
        recordingError = nil
    }

    func beginProcessing() {
        guard let url = audioURL else { return }
        processingTask?.cancel()
        speechTranscriber.cancel()
        processingError = nil
        phase = .processing
        processingProgress = 0
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                processingLabel = "Reading the recording"
                processingTip = "Your audio stays on this Mac while the transcript is created."
                let tokens = try await speechTranscriber.transcribe(url: url) { fraction, label in
                    self.processingProgress = min(fraction * 0.78, 0.78)
                    self.processingLabel = label
                    if fraction > 0.45 {
                        self.processingTip = "Every recognized word keeps its original start and end time."
                    }
                }
                guard !Task.isCancelled else { return }
                applyTranscription(tokens)
                processingProgress = 0.8
                processingLabel = "Listening for room tone"
                async let analysis = Task.detached(priority: .userInitiated) {
                    try? AudioSignalAnalyzer.analyze(url: url)
                }.value
                async let loudness = Task.detached(priority: .userInitiated) {
                    try? LoudnessAnalyzer.measure(url: url)
                }.value
                voiceAnalysis = await analysis
                sourceLoudness = await loudness

                processingProgress = 1
                processingLabel = "Preparing your review"
                processingTip = "Nothing is permanently removed until you export."
                try? await Task.sleep(for: .milliseconds(180))
                phase = .edit
            } catch is CancellationError {
                return
            } catch {
                processingError = error.localizedDescription
            }
        }
    }

    func retryTranscription() {
        beginProcessing()
    }

    func cancelProcessing() {
        processingTask?.cancel()
        speechTranscriber.cancel()
        phase = .setup
    }

    func cancelSetup() {
        stopPlayback()
        if let securityScopedURL { securityScopedURL.stopAccessingSecurityScopedResource() }
        securityScopedURL = nil
        audioURL = nil
        fileName = ""
        duration = 0
        phase = .welcome
    }

    func selectEditingMode(_ mode: EditingMode) {
        editingMode = mode
        if mode == .autopilot { usePolish = true }
    }

    func useDemoAudio() {
        fileName = "Morning reflection.m4a"
        duration = 73
        audioURL = nil
        exportAudio = false
        processingError = nil
        isDemoTranscript = true
        voiceAnalysis = .sample
        phase = .processing
        processingProgress = 0
        processingTask = Task { [weak self] in
            guard let self else { return }
            for value in stride(from: 0.0, through: 1.0, by: 0.05) {
                try? await Task.sleep(for: .milliseconds(35))
                processingProgress = value
                if value > 0.25 { processingLabel = "Transcribing every word" }
                if value > 0.62 { processingLabel = "Looking for restarts" }
            }
            buildDemoTranscript()
            phase = .edit
        }
    }

    private func applyTranscription(_ tokens: [TranscribedToken]) {
        selectedWordIDs = []
        let suggestions = AutoEditAnalyzer.suggestions(
            for: tokens,
            configuration: autoEditConfiguration
        )
        var reasons: [Int: String] = [:]
        for suggestion in suggestions {
            for index in suggestion.range { reasons[index] = suggestion.reason.rawValue }
        }
        words = tokens.enumerated().map { index, token in
            let suggested = reasons[index] != nil
            return TranscriptWord(
                id: UUID(),
                text: token.text,
                startTime: token.startTime,
                endTime: token.startTime + max(token.duration, 0.04),
                reason: reasons[index],
                isRemoved: editingMode == .autopilot && suggested,
                wasSuggested: suggested
            )
        }
    }

    func buildDemoTranscript() {
        selectedWordIDs = []
        let script = "Today I want to share a small idea about recording your voice. Um I think the best tools should mostly disappear. Sorry let me take that again. The best tools should mostly disappear so you can stay focused on what you are trying to say. That is the whole point."
        let tokens = script.split(separator: " ").map(String.init)
        let safeDuration = duration > 0 ? duration : 73
        let interval = safeDuration / Double(tokens.count + 4)
        let suggestedRange = 13...26
        let fillerIndex = 12
        words = tokens.enumerated().map { index, token in
            let suggested = index == fillerIndex || suggestedRange.contains(index)
            let reason = index == fillerIndex ? "Filler word" : (suggestedRange.contains(index) ? "Earlier take" : nil)
            return TranscriptWord(
                id: UUID(),
                text: token,
                startTime: Double(index + 2) * interval,
                endTime: Double(index + 3) * interval - 0.04,
                reason: reason,
                isRemoved: editingMode == .autopilot && suggested,
                wasSuggested: suggested
            )
        }
    }

    func toggleWord(_ word: TranscriptWord) {
        guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }
        selectedWordIDs = []
        if NSEvent.modifierFlags.contains(.shift),
           let anchorID = selectionAnchorID,
           let anchor = words.firstIndex(where: { $0.id == anchorID }) {
            let range = min(anchor, index) ... max(anchor, index)
            let remove = !words[index].isRemoved
            for position in range { words[position].isRemoved = remove }
        } else {
            words[index].isRemoved.toggle()
            selectionAnchorID = word.id
        }
    }

    func selectWords(from startID: UUID, through endID: UUID) {
        guard let start = words.firstIndex(where: { $0.id == startID }),
              let end = words.firstIndex(where: { $0.id == endID }) else { return }
        selectedWordIDs = Set(words[min(start, end) ... max(start, end)].map(\.id))
    }

    func setSelectedWordsRemoved(_ removed: Bool) {
        guard !selectedWordIDs.isEmpty else { return }
        for index in words.indices where selectedWordIDs.contains(words[index].id) {
            words[index].isRemoved = removed
        }
        selectedWordIDs = []
    }

    func clearWordSelection() {
        selectedWordIDs = []
    }

    func restoreAll() {
        restoreAllSnapshot = words.map(\.isRemoved)
        for index in words.indices { words[index].isRemoved = false }
        selectedWordIDs = []
        canUndoRestoreAll = true
    }

    func undoRestoreAll() {
        guard let restoreAllSnapshot, restoreAllSnapshot.count == words.count else { return }
        for index in words.indices { words[index].isRemoved = restoreAllSnapshot[index] }
        self.restoreAllSnapshot = nil
        canUndoRestoreAll = false
    }

    func applySuggestions() {
        for index in words.indices where words[index].wasSuggested { words[index].isRemoved = true }
        selectedWordIDs = []
        restoreAllSnapshot = nil
        canUndoRestoreAll = false
    }

    func togglePlayback() {
        if isPlaying { pausePlayback() } else { startPlayback() }
    }

    func seek(to time: TimeInterval) {
        if playbackUsesEditedTimeline {
            let requested = min(max(time, 0), player?.duration ?? estimatedEditedDuration)
            currentTime = requested
            player?.currentTime = requested
            return
        }
        let requested = min(max(time, 0), duration)
        currentTime = AudioEditPlanner.playableTime(for: requested, keptRanges: currentKeptRanges) ?? duration
        player?.currentTime = currentTime
    }

    func startPlayback() {
        guard let player else {
            isPlaying = true
            startPlaybackClock()
            return
        }
        if player.currentTime >= player.duration { player.currentTime = 0 }
        if playbackUsesEditedTimeline {
            currentTime = player.currentTime
            player.play()
            isPlaying = true
            startPlaybackClock()
            return
        }
        guard let playable = AudioEditPlanner.playableTime(for: player.currentTime, keptRanges: currentKeptRanges) else {
            currentTime = 0
            return
        }
        player.currentTime = playable
        currentTime = playable
        player.play()
        isPlaying = true
        startPlaybackClock()
    }

    func pausePlayback() {
        player?.pause()
        isPlaying = false
        playbackTask?.cancel()
    }

    func stopPlayback() {
        player?.stop()
        playbackTask?.cancel()
        isPlaying = false
        currentTime = 0
    }

    private func startPlaybackClock() {
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && isPlaying {
                if let player {
                    var sourceTime = player.currentTime
                    if playbackUsesEditedTimeline {
                        currentTime = sourceTime
                        if !player.isPlaying {
                            isPlaying = false
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(33))
                    } else {
                        let ranges = currentKeptRanges
                        if let playable = AudioEditPlanner.playableTime(for: sourceTime, keptRanges: ranges),
                           playable > sourceTime + 0.002 {
                            player.currentTime = playable
                            sourceTime = playable
                        } else if playableTimeHasEnded(sourceTime, keptRanges: ranges) {
                            player.stop()
                            isPlaying = false
                            break
                        }
                        currentTime = sourceTime
                        if !player.isPlaying {
                            isPlaying = false
                            break
                        }

                        // Refresh the UI at roughly display cadence, but wake at
                        // an edit boundary sooner so the audio jump is not late.
                        let rangeEnd = ranges.first(where: {
                            sourceTime >= $0.start && sourceTime <= $0.end
                        })?.end
                        let secondsToBoundary = rangeEnd.map { max(0.003, $0 - sourceTime) } ?? 0.033
                        let sleepSeconds = min(0.033, secondsToBoundary)
                        try? await Task.sleep(for: .seconds(sleepSeconds))
                    }
                } else {
                    currentTime += 0.033
                    if currentTime >= duration {
                        currentTime = 0
                        isPlaying = false
                    }
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        }
    }

    private func playableTimeHasEnded(
        _ sourceTime: TimeInterval,
        keptRanges: [AudioTimeRange]
    ) -> Bool {
        guard let last = keptRanges.last else { return true }
        return sourceTime >= last.end
    }

    func goToPolish() {
        pausePlayback()
        phase = .polish
        polishPreviewMode = hasAppliedPolishPreview ? .polished : .before
        isShowingPolishPreview = hasAppliedPolishPreview
        if polishPreviewSignature == currentPolishSignature, let dryPreviewURL {
            loadPlayer(url: polishPreviewMode == .polished ? (polishedPreviewURL ?? dryPreviewURL) : dryPreviewURL, usesEditedTimeline: true)
        }
    }

    func goToExport() {
        pausePlayback()
        phase = .export
    }

    func goForward() {
        switch phase {
        case .edit: goToPolish()
        case .polish: goToExport()
        default: break
        }
    }

    func goToStep(_ step: Int) {
        switch step {
        case 0:
            if phase == .polish || phase == .export {
                restoreSourcePlayer()
                phase = .edit
            }
        case 1:
            if phase == .edit || phase == .export { goToPolish() }
        case 2:
            if phase == .edit || phase == .polish { goToExport() }
        default: break
        }
    }

    func goBack() {
        pausePlayback()
        switch phase {
        case .export: phase = .polish
        case .polish:
            restoreSourcePlayer()
            phase = .edit
        case .edit: phase = .setup
        default: break
        }
    }

    func togglePolish(_ option: PolishOption) {
        guard option != .noise || DenoiseModelStore.installedModelIsValid() else { return }
        if polishSelections.contains(option) { polishSelections.remove(option) }
        else { polishSelections.insert(option) }
        markPolishChangesPending()
    }

    func enableNoiseReductionIfAvailable() {
        guard DenoiseModelStore.installedModelIsValid(),
              !polishSelections.contains(.noise) else { return }
        polishSelections.insert(.noise)
        markPolishChangesPending()
    }

    func setPolishEnabled(_ enabled: Bool) {
        usePolish = enabled
        markPolishChangesPending()
    }

    func setLoudnessPreset(_ preset: LoudnessPreset) {
        loudnessPreset = preset
        markPolishChangesPending()
    }

    func polishIntensity(for option: PolishOption) -> PolishIntensity {
        polishIntensities[option] ?? Self.defaultPolishIntensities[option] ?? .balanced
    }

    func setPolishIntensity(_ intensity: PolishIntensity, for option: PolishOption) {
        polishIntensities[option] = intensity
        markPolishChangesPending()
    }

    func applyPolish() {
        guard usePolish else { return }
        isShowingPolishPreview = false
        polishPreviewMode = .polished
        preparePolishPreview()
    }

    func editPolishSettings() {
        pausePlayback()
        isShowingPolishPreview = false
    }

    private func markPolishChangesPending() {
        pausePlayback()
        isShowingPolishPreview = false
        polishPreviewMode = .before
        if let dryPreviewURL {
            loadPlayer(url: dryPreviewURL, usesEditedTimeline: true)
        }
    }

    func selectPolishPreview(_ mode: PolishPreviewMode) {
        polishPreviewMode = mode
        pausePlayback()
        let url = mode == .before ? dryPreviewURL : polishedPreviewURL
        guard let url else { return }
        loadPlayer(url: url, usesEditedTimeline: true)
    }

    private func currentRenderOptions() -> AudioRenderOptions {
        AudioRenderOptions(
            pacing: pacing,
            maximumPause: pauseDuration,
            reduceNoise: usePolish
                && polishSelections.contains(.noise)
                && DenoiseModelStore.installedModelIsValid(),
            voiceEQ: usePolish && polishSelections.contains(.eq),
            deEss: usePolish && polishSelections.contains(.deEss),
            compression: usePolish && polishSelections.contains(.compression),
            forceMono: usePolish && polishSelections.contains(.forceMono),
            breathControl: usePolish && polishSelections.contains(.breathControl),
            normalizeLoudness: usePolish,
            loudnessPreset: loudnessPreset,
            noiseIntensity: polishIntensity(for: .noise),
            eqIntensity: polishIntensity(for: .eq),
            deEssIntensity: polishIntensity(for: .deEss),
            compressionIntensity: polishIntensity(for: .compression),
            breathIntensity: polishIntensity(for: .breathControl)
        )
    }

    private var currentPolishSignature: String {
        let removed = words.enumerated().compactMap { $0.element.isRemoved ? String($0.offset) : nil }.joined(separator: ",")
        let options = polishSelections.map(\.rawValue).sorted().joined(separator: ",")
        let intensities = PolishOption.allCases.compactMap { option -> String? in
            guard option != .forceMono else { return nil }
            return "\(option.rawValue):\(polishIntensity(for: option).rawValue)"
        }.joined(separator: ",")
        return [removed, String(format: "%.2f", pauseDuration), String(usePolish), options, intensities, loudnessPreset.rawValue].joined(separator: "|")
    }

    private func preparePolishPreview() {
        guard phase == .polish, let sourceURL = audioURL else { return }
        pausePlayback()
        let selectedMode = usePolish ? polishPreviewMode : .before
        if polishPreviewSignature == currentPolishSignature,
           let dryPreviewURL,
           let polishedPreviewURL {
            loadPlayer(url: selectedMode == .before ? dryPreviewURL : polishedPreviewURL, usesEditedTimeline: true)
            isShowingPolishPreview = true
            return
        }
        polishPreviewTask?.cancel()
        isPreparingPolishPreview = true
        polishPreviewError = nil
        polishedLoudness = nil
        polishQualityReport = nil
        breathControlResult = nil
        polishCurrentStage = "Preparing edited audio"
        polishStageTimings = []

        let signature = currentPolishSignature
        polishPreviewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await renderPolishPreview(sourceURL: sourceURL)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: result.folder)
                    return
                }
                polishPreviewMode = selectedMode
                installPolishPreview(result, signature: signature, loadForPlayback: true)
            } catch is CancellationError {
            } catch {
                polishPreviewError = error.localizedDescription
            }
            isPreparingPolishPreview = false
        }
    }

    private func renderPolishPreview(sourceURL: URL) async throws -> (
        folder: URL,
        dry: URL,
        polished: URL,
        measurement: LoudnessMeasurement,
        quality: PolishQualityReport,
        breathControl: BreathControlResult?
    ) {
        let ranges = currentKeptRanges
        let options = currentRenderOptions()
        let renderID = UUID()
        polishRenderID = renderID
        let progressHandler: PolishProgressHandler = { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, polishRenderID == renderID else { return }
                switch update.state {
                case .started:
                    polishCurrentStage = update.name
                case .completed:
                    polishStageTimings.append(update)
                }
            }
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoetPreview-\(UUID().uuidString)", isDirectory: true)
        let renderTask = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let dry = folder.appendingPathComponent("before.wav")
                let polished = folder.appendingPathComponent("polished.wav")
                try EditedAudioRenderer.render(sourceURL: sourceURL, destinationURL: dry, keptRanges: ranges)
                try Task.checkCancellation()
                let report = try VoicePolisher.render(
                    sourceURL: dry,
                    destinationURL: polished,
                    options: options,
                    progress: progressHandler
                )
                let measurement: LoudnessMeasurement
                if let normalizedMeasurement = report.loudness?.after {
                    measurement = normalizedMeasurement
                } else {
                    measurement = try LoudnessAnalyzer.measure(url: polished)
                }
                return (folder, dry, polished, measurement, report.quality, report.breathControl)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }
    }

    private func installPolishPreview(
        _ result: (
            folder: URL,
            dry: URL,
            polished: URL,
            measurement: LoudnessMeasurement,
            quality: PolishQualityReport,
            breathControl: BreathControlResult?
        ),
        signature: String,
        loadForPlayback: Bool
    ) {
        if let oldFolder = polishPreviewFolder { try? FileManager.default.removeItem(at: oldFolder) }
        polishPreviewFolder = result.folder
        dryPreviewURL = result.dry
        polishedPreviewURL = result.polished
        polishedLoudness = result.measurement
        polishQualityReport = result.quality
        breathControlResult = result.breathControl
        polishCurrentStage = nil
        polishPreviewSignature = signature
        isShowingPolishPreview = true
        if loadForPlayback {
            let selectedURL = polishPreviewMode == .before ? result.dry : result.polished
            loadPlayer(url: selectedURL, usesEditedTimeline: true)
        }
    }

    private func restoreSourcePlayer() {
        guard let audioURL else { return }
        loadPlayer(url: audioURL, usesEditedTimeline: false)
    }

    private func loadPlayer(url: URL, usesEditedTimeline: Bool) {
        stopPlayback()
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            playbackUsesEditedTimeline = usesEditedTimeline
        } catch {
            player = nil
            playbackUsesEditedTimeline = false
        }
    }

    private func discardPolishPreview() {
        polishPreviewTask?.cancel()
        polishPreviewTask = nil
        if let polishPreviewFolder { try? FileManager.default.removeItem(at: polishPreviewFolder) }
        polishPreviewFolder = nil
        dryPreviewURL = nil
        polishedPreviewURL = nil
        polishPreviewSignature = nil
        polishRenderID = nil
        polishCurrentStage = nil
        isPreparingPolishPreview = false
        isShowingPolishPreview = false
        polishPreviewError = nil
        polishQualityReport = nil
        breathControlResult = nil
    }

    func exportPackage() {
        guard !isExporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an export folder"
        panel.prompt = "Export here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let base = fileName.isEmpty ? "Poet Audio" : URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let request = ExportPackageRequest(
            folder: folder,
            baseName: base,
            sourceURL: audioURL,
            words: words,
            duration: duration,
            renderOptions: currentRenderOptions(),
            includeAudio: exportAudio,
            includeTXT: exportTXT,
            includeSRT: exportSRT,
            includeVTT: exportVTT
        )

        isExporting = true
        exportProgress = 0.04
        exportStatus = "Preparing export…"
        let exportProgressHandler: PolishProgressHandler = { [weak self] update in
            guard update.state == .started else { return }
            Task { @MainActor [weak self] in
                guard let self, isExporting else { return }
                exportStatus = update.name
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try ExportPackageRenderer.render(request, progress: exportProgressHandler)
                }.value
                exportProgress = 1
                exportStatus = "Exported to \(base) — Poet Export"
            } catch {
                exportStatus = "Couldn’t export: \(error.localizedDescription)"
            }
            isExporting = false
        }
    }

}
