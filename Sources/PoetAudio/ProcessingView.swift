import SwiftUI

struct ProcessingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 36) {
            Spacer()

            if let error = model.processingError {
                errorState(error)
                Spacer()
            } else {
                ZStack {
                    Circle().stroke(PoetTheme.elevated, lineWidth: 1).frame(width: 112, height: 112)
                    Circle()
                        .trim(from: 0, to: model.processingProgress)
                        .stroke(PoetTheme.sage, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 112, height: 112)
                        .animation(.easeOut(duration: 0.18), value: model.processingProgress)
                    VStack(spacing: 2) {
                        Text("\(Int(model.processingProgress * 100))%")
                            .font(PoetTheme.editorial(24))
                        Text("LOCAL")
                            .font(PoetTheme.utility(8, weight: .bold))
                            .tracking(1.3)
                            .foregroundStyle(PoetTheme.sage)
                    }
                }

                VStack(spacing: 10) {
                    Text(model.processingLabel)
                        .font(PoetTheme.editorial(34))
                    Text(model.fileName)
                        .font(PoetTheme.utility(13))
                        .foregroundStyle(PoetTheme.muted)
                }

                VStack(spacing: 0) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(PoetTheme.elevated)
                            Capsule().fill(PoetTheme.sage).frame(width: geometry.size.width * model.processingProgress)
                        }
                    }
                    .frame(height: 7)

                    HStack {
                        Text("IMPORT")
                        Spacer()
                        Text("TRANSCRIPT")
                        Spacer()
                        Text(model.editingMode == .autopilot && model.usePolish ? "POLISH" : "ROUGH CUT")
                    }
                    .font(PoetTheme.utility(9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(PoetTheme.faint)
                    .padding(.top, 12)
                }
                .frame(maxWidth: 560)

                PoetCard(padding: 18) {
                    HStack(spacing: 13) {
                        Image(systemName: "lightbulb.min")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(PoetTheme.sage)
                        Text(model.processingTip)
                            .font(PoetTheme.utility(12))
                            .foregroundStyle(PoetTheme.muted)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: 560)

                Spacer()
                Text("Your recording stays on this Mac.")
                    .font(PoetTheme.utility(11, weight: .medium))
                    .foregroundStyle(PoetTheme.faint)
                    .padding(.bottom, 28)
            }
        }
        .padding(.horizontal, 40)
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
