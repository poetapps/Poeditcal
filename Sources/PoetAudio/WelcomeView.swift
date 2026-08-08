import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingImporter = false
    @State private var showingRecorder = false
    @State private var isDropTarget = false

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(spacing: 18) {
                    PoeditcalWordmark()
                    Text("Make the take feel finished.")
                        .font(PoetTheme.editorial(42, weight: .regular))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(PoetTheme.cream)
                    Text("Bring in a recording or talking-head video. Poeditcal helps shape the edit, polish the voice, and keeps every decision reversible.")
                        .font(PoetTheme.utility(13))
                        .foregroundStyle(PoetTheme.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 600)
                        .lineSpacing(3)
                }

                VStack(spacing: 18) {
                    Button { showingImporter = true } label: {
                        VStack(spacing: 15) {
                            ZStack {
                                Circle().fill(PoetTheme.sageDark).frame(width: 64, height: 64)
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(PoetTheme.sage)
                            }
                            VStack(spacing: 5) {
                                Text("Drop a recording or video here")
                                    .font(PoetTheme.utility(17, weight: .semibold))
                                    .foregroundStyle(PoetTheme.cream)
                                Text("or choose one from your Mac")
                                    .font(PoetTheme.utility(13))
                                    .foregroundStyle(PoetTheme.muted)
                            }
                            Text("WAV · M4A · MP3 · AIFF · FLAC · MOV · MP4 · M4V")
                                .font(PoetTheme.utility(10, weight: .bold))
                                .tracking(1.1)
                                .foregroundStyle(PoetTheme.faint)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .background(isDropTarget ? PoetTheme.sageDark.opacity(0.7) : PoetTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first else { return false }
                        model.loadMedia(url)
                        return true
                    } isTargeted: { isDropTarget = $0 }

                    HStack(spacing: 12) {
                        Button { showingImporter = true } label: {
                            Label("Choose media", systemImage: "folder")
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        Button { showingRecorder = true } label: {
                            Label("Record a new take", systemImage: "mic.fill")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.top, 6)

                    HStack(spacing: 18) {
                        Button("Open project") { model.openProjectPanel() }
                        Button("Try a sample") { model.useDemoAudio() }
                    }
                    .buttonStyle(.plain)
                    .font(PoetTheme.utility(11, weight: .semibold))
                    .foregroundStyle(PoetTheme.muted)
                }
                .frame(maxWidth: 720)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 42)
            .padding(.bottom, 60)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first { model.loadMedia(url) }
        }
        .sheet(isPresented: $showingRecorder) {
            RecordingView()
                .environmentObject(model)
        }
    }
}

private struct RecordingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "New recording")
                    Text(model.isRecording ? "Recording your take" : "Ready when you are")
                        .font(PoetTheme.editorial(28))
                }
                Spacer()
                Button {
                    model.cancelRecording()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(PoetTheme.elevated)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 15) {
                ZStack {
                    Circle()
                        .fill(model.isRecording ? PoetTheme.error.opacity(0.16) : PoetTheme.sageDark)
                        .frame(width: 108, height: 108)
                    Circle()
                        .stroke(model.isRecording ? PoetTheme.error.opacity(0.35) : PoetTheme.sage.opacity(0.3), lineWidth: 2)
                        .frame(width: 88 + CGFloat(model.recordingLevel) * 18, height: 88 + CGFloat(model.recordingLevel) * 18)
                    Image(systemName: model.isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(model.isRecording ? PoetTheme.error : PoetTheme.sage)
                }
                .animation(.easeOut(duration: 0.08), value: model.recordingLevel)

                Text(time(model.recordingDuration))
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                    .foregroundStyle(PoetTheme.cream)
                Text(model.isRecording ? "Speak naturally. Your recording stays on this Mac." : "Poeditcal records a high-quality mono M4A file.")
                    .font(PoetTheme.utility(12))
                    .foregroundStyle(PoetTheme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            if let error = model.recordingError {
                Text(error)
                    .font(PoetTheme.utility(11, weight: .medium))
                    .foregroundStyle(PoetTheme.error)
                    .multilineTextAlignment(.center)
            }

            if model.isRecording {
                Button {
                    model.stopRecording()
                    dismiss()
                } label: {
                    Label("Stop & use recording", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            } else {
                Button { model.startRecording() } label: {
                    Label("Start recording", systemImage: "record.circle")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520, height: 470)
        .background(PoetTheme.background)
        .interactiveDismissDisabled(model.isRecording)
    }

    private func time(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
