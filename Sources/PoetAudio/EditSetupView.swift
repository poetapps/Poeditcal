import SwiftUI

struct EditSetupView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var smartEditModel: SmartEditModelStore
    @State private var step = 0

    private let stepNames = ["Control", "Intensity", "Pacing", "First pass"]

    var body: some View {
        VStack(spacing: 0) {
            SetupProgress(step: step, labels: stepNames)
                .padding(.top, 28)

            Group {
                switch step {
                case 0: controlStep
                case 1: intensityStep
                case 2: pacingStep
                default: polishStep
                }
            }
            .frame(maxWidth: 760, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .trailing)),
                removal: .opacity.combined(with: .move(edge: .leading))
            ))

            setupNavigation
                .frame(maxWidth: 760)
                .padding(.bottom, 30)
        }
        .padding(.horizontal, 42)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.44, dampingFraction: 0.86), value: step)
    }

    private var controlStep: some View {
        SetupPage(
            title: "How should Poet shape this take?",
            detail: "Choose how much help you want. You can restore any suggested cut later."
        ) {
            HStack(spacing: 14) {
                ModeChoice(
                    title: "Autopilot",
                    detail: "Poet marks likely cleanups for you.",
                    icon: "sparkles",
                    selected: model.editingMode == .autopilot
                ) { model.selectEditingMode(.autopilot) }
                ModeChoice(
                    title: "Full control",
                    detail: "Start with every word untouched.",
                    icon: "hand.raised",
                    selected: model.editingMode == .fullControl
                ) { model.selectEditingMode(.fullControl) }
            }
        }
    }

    private var intensityStep: some View {
        SetupPage(
            title: "How much should Poet shape the edit?",
            detail: model.editingMode == .fullControl
                ? "These preferences are saved if you switch to Autopilot later."
                : model.autoEditConfiguration.intensity.detail
        ) {
            VStack(spacing: 22) {
                ThreeStopSlider(selection: $model.autoEditConfiguration.intensity)

                VStack(spacing: 8) {
                    SetupRow(
                        title: "Filler words",
                        detail: "Clear hesitations and repeated acknowledgements. Contextual phrases stay protected.",
                        icon: "text.badge.minus",
                        isOn: $model.autoEditConfiguration.removeFillers
                    )
                    SetupRow(
                        title: "Repeated takes",
                        detail: "Keep the later version of a clearly repeated phrase.",
                        icon: "arrow.uturn.forward",
                        isOn: $model.autoEditConfiguration.detectRetakes
                    )
                    SetupRow(
                        title: "Restart cues",
                        detail: "Listen for cues such as “sorry,” “redo,” or “again.”",
                        icon: "arrow.counterclockwise",
                        isOn: $model.autoEditConfiguration.detectRestarts
                    )
                }
                .opacity(model.editingMode == .autopilot ? 1 : 0.4)
                .allowsHitTesting(model.editingMode == .autopilot)

                SmartEditModelPicker()
                    .opacity(model.editingMode == .autopilot ? 1 : 0.4)
                    .allowsHitTesting(model.editingMode == .autopilot)
            }
        }
    }

    private var pacingStep: some View {
        SetupPage(
            title: "How much room should pauses have?",
            detail: "Longer silences are shortened to this length. Short, expressive pauses stay untouched."
        ) {
            VStack(spacing: 26) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Maximum pause")
                        .font(PoetTheme.utility(14, weight: .semibold))
                    Spacer()
                    Text(String(format: "%.1f seconds", model.pauseDuration))
                        .font(PoetTheme.utility(14, weight: .semibold))
                        .foregroundStyle(PoetTheme.sage)
                        .monospacedDigit()
                }
                Slider(value: $model.pauseDuration, in: 0.2...2.0, step: 0.1)
                    .tint(PoetTheme.sage)
                    .controlSize(.large)
                    .accessibilityLabel("Maximum pause duration")
                HStack {
                    Text("0.2s · tight")
                    Spacer()
                    Text("1.0s · natural")
                    Spacer()
                    Text("2.0s · spacious")
                }
                .font(PoetTheme.utility(10))
                .foregroundStyle(PoetTheme.faint)
            }
            .padding(24)
            .background(PoetTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var polishStep: some View {
        SetupPage(
            title: "Polish the first pass?",
            detail: "Poet can prepare a finished-sounding version after the transcript. You’ll choose exactly what it changes before anything renders."
        ) {
            Button { model.usePolish.toggle() } label: {
                HStack(spacing: 18) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(model.usePolish ? PoetTheme.sage : PoetTheme.muted)
                        .frame(width: 48, height: 48)
                        .background(model.usePolish ? PoetTheme.sageDark : PoetTheme.elevated)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.usePolish ? "Include a polished first pass" : "Keep this pass unpolished")
                            .font(PoetTheme.utility(15, weight: .semibold))
                        Text("Noise, tone, dynamics, breath control, and loudness remain adjustable on the next screen.")
                            .font(PoetTheme.utility(11))
                            .foregroundStyle(PoetTheme.muted)
                    }
                    Spacer()
                    Image(systemName: model.usePolish ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(model.usePolish ? PoetTheme.sage : PoetTheme.faint)
                }
                .padding(22)
                .background(PoetTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var setupNavigation: some View {
        HStack {
            Button(step == 0 ? "Choose another file" : "Back") {
                if step == 0 { model.cancelSetup() } else { step -= 1 }
            }
            .buttonStyle(SecondaryButtonStyle())

            Spacer()

            FileSummary(name: model.fileName, duration: model.duration)

            Spacer()

            Button(step == stepNames.count - 1 ? "Transcribe & prepare" : "Continue") {
                if step == stepNames.count - 1 { model.beginProcessing() } else { step += 1 }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

private struct SmartEditModelPicker: View {
    @EnvironmentObject private var smartEditModel: SmartEditModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Smart Edit model")
                        .font(PoetTheme.utility(12, weight: .semibold))
                    Text("Optional · runs locally · choose one or install both")
                        .font(PoetTheme.utility(9))
                        .foregroundStyle(PoetTheme.muted)
                }
                Spacer()
                if smartEditModel.isInstalled(smartEditModel.selectedChoice) {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(PoetTheme.utility(9, weight: .semibold))
                        .foregroundStyle(PoetTheme.sage)
                }
            }

            HStack(spacing: 10) {
                ForEach(SmartEditModelChoice.allCases) { choice in
                    modelCard(choice)
                }
            }

            if let error = smartEditModel.errorMessage {
                Text(error)
                    .font(PoetTheme.utility(9, weight: .medium))
                    .foregroundStyle(PoetTheme.error)
                    .lineLimit(2)
            }
        }
        .padding(15)
        .background(PoetTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func modelCard(_ choice: SmartEditModelChoice) -> some View {
        let selected = smartEditModel.selectedChoice == choice
        let installed = smartEditModel.isInstalled(choice)
        let downloading = smartEditModel.downloadingChoice == choice

        return Button {
            if installed {
                smartEditModel.select(choice)
            } else {
                Task { await smartEditModel.install(choice) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(choice.title)
                        .font(PoetTheme.utility(11, weight: .semibold))
                    Spacer()
                    if downloading {
                        ProgressView(value: smartEditModel.downloadProgress)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        Image(systemName: selected ? "checkmark.circle.fill" : (installed ? "checkmark.circle" : "arrow.down.circle"))
                            .foregroundStyle(selected ? PoetTheme.sage : PoetTheme.muted)
                    }
                }
                Text(choice.modelName)
                    .font(PoetTheme.utility(9, weight: .medium))
                    .foregroundStyle(PoetTheme.cream)
                Text(choice.detail)
                    .font(PoetTheme.utility(9))
                    .foregroundStyle(PoetTheme.muted)
                    .lineLimit(2)
                Text(installed ? (selected ? "Selected" : "Use this model") : (downloading ? "Downloading \(Int(smartEditModel.downloadProgress * 100))%" : "Download"))
                    .font(PoetTheme.utility(8, weight: .semibold))
                    .foregroundStyle(installed || downloading ? PoetTheme.sage : PoetTheme.amber)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .background(selected ? PoetTheme.sageDark.opacity(0.7) : PoetTheme.elevated)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? PoetTheme.sage.opacity(0.55) : Color.clear, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(smartEditModel.downloadingChoice != nil)
    }
}

private struct SetupPage<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(PoetTheme.editorial(34, weight: .regular))
                Text(detail)
                    .font(PoetTheme.utility(13))
                    .foregroundStyle(PoetTheme.muted)
                    .frame(maxWidth: 590, alignment: .leading)
                    .lineSpacing(3)
            }
            content
            Spacer(minLength: 20)
        }
    }
}

private struct SetupProgress: View {
    let step: Int
    let labels: [String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(labels.indices, id: \.self) { index in
                VStack(spacing: 7) {
                    HStack(spacing: 0) {
                        if index > 0 { Rectangle().fill(index <= step ? PoetTheme.sage : PoetTheme.elevated).frame(height: 1) }
                        Circle().fill(index <= step ? PoetTheme.sage : PoetTheme.elevated).frame(width: 7, height: 7)
                        if index < labels.count - 1 { Rectangle().fill(index < step ? PoetTheme.sage : PoetTheme.elevated).frame(height: 1) }
                    }
                    Text(labels[index])
                        .font(PoetTheme.utility(9, weight: index == step ? .semibold : .regular))
                        .foregroundStyle(index == step ? PoetTheme.cream : PoetTheme.faint)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: 620)
    }
}

private struct ModeChoice: View {
    let title: String
    let detail: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(selected ? PoetTheme.sage : PoetTheme.muted)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? PoetTheme.sage : PoetTheme.faint)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(PoetTheme.utility(17, weight: .semibold))
                    Text(detail).font(PoetTheme.utility(11)).foregroundStyle(PoetTheme.muted)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .background(selected ? PoetTheme.elevated : PoetTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ThreeStopSlider: View {
    @Binding var selection: AutoEditIntensity
    private let values = AutoEditIntensity.allCases

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                ForEach(values) { value in
                    Text(value.rawValue)
                        .frame(maxWidth: .infinity, alignment: value == .conservative ? .leading : (value == .thorough ? .trailing : .center))
                }
            }
            .font(PoetTheme.utility(10, weight: .semibold))
            MagneticStepSlider(
                stepCount: values.count,
                selectedIndex: Binding(
                    get: { values.firstIndex(of: selection) ?? 1 },
                    set: { selection = values[min(max($0, 0), values.count - 1)] }
                )
            )
        }
        .padding(.horizontal, 4)
    }
}

private struct SetupRow: View {
    let title: String
    let detail: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isOn ? PoetTheme.sage : PoetTheme.muted)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(PoetTheme.utility(13, weight: .semibold))
                Text(detail).font(PoetTheme.utility(10)).foregroundStyle(PoetTheme.muted)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(PoetTheme.sage)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 66)
        .background(PoetTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct FileSummary: View {
    let name: String
    let duration: TimeInterval

    var body: some View {
        VStack(spacing: 2) {
            Text(name).lineLimit(1)
            Text(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)).foregroundStyle(PoetTheme.faint)
        }
        .font(PoetTheme.utility(10, weight: .semibold))
        .frame(maxWidth: 190)
    }
}
