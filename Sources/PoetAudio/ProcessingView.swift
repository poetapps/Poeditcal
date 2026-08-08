import SwiftUI

struct ProcessingView: View {
    @EnvironmentObject private var model: AppModel

    private let stages = [
        "Preparing your recording",
        "Creating a clean first pass",
        "Transcribing every word",
        "Recovering natural speech",
        "Finding retakes and pauses",
        "Preparing your review"
    ]

    var body: some View {
        Group {
            if let error = model.processingError {
                VStack(spacing: 36) {
                    Spacer()
                errorState(error)
                    Spacer()
                }
                .padding(.horizontal, 40)
            } else {
                WorkflowProgressView(
                    title: "Preparing your edit",
                    stages: stages,
                    currentStage: stageIndex(for: model.processingLabel)
                )
            }
        }
    }

    private func stageIndex(for label: String) -> Int {
        let raw = label.lowercased()
        if raw.contains("review") { return 5 }
        if raw.contains("retake") || raw.contains("filler") || raw.contains("restart") || raw.contains("pause") || raw.contains("understanding") { return 4 }
        if raw.contains("recover") || raw.contains("um") || raw.contains("uh") { return 3 }
        if raw.contains("transcrib") || raw.contains("parakeet") || raw.contains("loading your recording") { return 2 }
        if raw.contains("clean first pass") { return 1 }
        return 0
    }

    @ViewBuilder
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 24) {
            ZStack {
                Circle().fill(PoetTheme.amberDark).frame(width: 82, height: 82)
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(PoetTheme.amber)
            }
            VStack(spacing: 9) {
                Text("The transcript needs a hand")
                    .font(PoetTheme.editorial(31))
                Text(message)
                    .font(PoetTheme.utility(13))
                    .foregroundStyle(PoetTheme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .lineSpacing(3)
            }
            HStack(spacing: 10) {
                Button("Choose another file") { model.cancelProcessing() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Try again") { model.retryTranscription() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            Button("Continue with the interface sample") { model.useDemoAudio() }
                .buttonStyle(.plain)
                .font(PoetTheme.utility(11, weight: .semibold))
                .foregroundStyle(PoetTheme.sage)
        }
    }
}
