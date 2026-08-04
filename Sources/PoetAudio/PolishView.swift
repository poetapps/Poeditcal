import SwiftUI

struct PolishView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.isPreparingPolishPreview {
                PolishingProgressView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if model.isShowingPolishPreview && model.hasAppliedPolishPreview {
                PolishPreviewPage()
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                polishSettings
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.88), value: model.isPreparingPolishPreview)
        .animation(.spring(response: 0.5, dampingFraction: 0.88), value: model.isShowingPolishPreview)
    }

    private var polishSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .center, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Polish your voice")
                            .font(PoetTheme.editorial(34, weight: .regular))
                        Text("Shape the sound with subtle, local processing. Nothing renders until you apply it.")
                            .font(PoetTheme.utility(12))
                            .foregroundStyle(PoetTheme.muted)
                    }

                    Spacer(minLength: 16)

                    Toggle("Polish audio", isOn: Binding(
                        get: { model.usePolish },
                        set: { model.setPolishEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .tint(PoetTheme.sage)
                    .font(PoetTheme.utility(11, weight: .semibold))
                    .fixedSize()
                }

                LoudnessSelector()

                VStack(spacing: 8) {
                    ForEach(PolishOption.allCases) { option in
                        PolishOptionRow(option: option)
                    }
                }
                .opacity(model.usePolish ? 1 : 0.38)
                .allowsHitTesting(model.usePolish)

                if let error = model.polishPreviewError {
                    Text(error)
                        .font(PoetTheme.utility(11, weight: .medium))
                        .foregroundStyle(PoetTheme.error)
                }

            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 74)
            .padding(.bottom, 100)
        }
    }
}

private struct LoudnessSelector: View {
    @EnvironmentObject private var model: AppModel
    private let presets = LoudnessPreset.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Delivery loudness")
                    .font(PoetTheme.utility(14, weight: .semibold))
                Spacer()
                Text("\(Int(model.loudnessPreset.targetLUFS)) LUFS")
                    .font(PoetTheme.utility(11, weight: .semibold))
                    .foregroundStyle(PoetTheme.sage)
            }

            HStack {
                ForEach(presets) { preset in
                    Text(preset.rawValue)
                        .frame(maxWidth: .infinity, alignment: alignment(for: preset))
                }
            }
            .font(PoetTheme.utility(10, weight: .semibold))

            MagneticStepSlider(
                stepCount: presets.count,
                selectedIndex: Binding(
                    get: { presets.firstIndex(of: model.loudnessPreset) ?? 0 },
                    set: { model.setLoudnessPreset(presets[min(max($0, 0), presets.count - 1)]) }
                )
            )
        }
        .padding(22)
        .background(PoetTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .disabled(!model.usePolish)
    }

    private func alignment(for preset: LoudnessPreset) -> Alignment {
        if preset == presets.first { return .leading }
        if preset == presets.last { return .trailing }
        return .center
    }
}

private struct PolishOptionRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var denoiseModel: DenoiseModelStore
    let option: PolishOption

    private var selected: Bool { model.polishSelections.contains(option) }
    private var supportsIntensity: Bool { option != .forceMono }
    private var isAvailable: Bool { option != .noise || denoiseModel.isInstalled }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: option.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? PoetTheme.sage : PoetTheme.muted)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(option.rawValue)
                    .font(PoetTheme.utility(12, weight: .semibold))
                Text(option == .noise && !isAvailable ? "Download required · 10.6 MB" : shortDetail)
                    .font(PoetTheme.utility(9))
                    .foregroundStyle(PoetTheme.muted)
            }
            .frame(width: 210, alignment: .leading)

            Spacer(minLength: 10)

            if supportsIntensity {
                HStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { Double(model.polishIntensity(for: option).rawValue) },
                            set: { value in
                                guard let intensity = PolishIntensity(rawValue: Int(value.rounded())) else { return }
                                model.setPolishIntensity(intensity, for: option)
                            }
                        ),
                        in: 0...3,
                        step: 1
                    )
                    .tint(PoetTheme.sage)
                    .controlSize(.large)
                    .frame(width: 130)
                    .disabled(!selected || !isAvailable)
                    Text(model.polishIntensity(for: option).label)
                        .font(PoetTheme.utility(9, weight: .semibold))
                        .foregroundStyle(selected ? PoetTheme.sage : PoetTheme.faint)
                        .frame(width: 52, alignment: .leading)
                }
            }

            if option == .noise && !isAvailable {
                Button {
                    Task { await denoiseModel.install() }
                } label: {
                    if denoiseModel.isDownloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(denoiseModel.errorMessage == nil ? "Download" : "Retry")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(denoiseModel.isDownloading)
                .help(denoiseModel.errorMessage ?? "Install AI noise reduction")
            } else {
                Toggle("", isOn: Binding(
                    get: { selected },
                    set: { _ in model.togglePolish(option) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(PoetTheme.sage)
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 68)
        .background(PoetTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var shortDetail: String {
        switch option {
        case .noise: "Remove steady room noise."
        case .eq: "Balance tone and clarity."
        case .deEss: "Tame sharp S sounds."
        case .compression: "Even out dynamics."
        case .forceMono: "Center every channel."
        case .breathControl: "Gently tuck heavy breaths."
        }
    }
}

private struct PolishPreviewPage: View {
    @EnvironmentObject private var model: AppModel

    private let levels: [CGFloat] = [0.22, 0.48, 0.74, 0.38, 0.58, 0.88, 0.44, 0.68, 0.32, 0.8, 0.52, 0.7, 0.4, 0.86, 0.3, 0.62, 0.78, 0.46, 0.66, 0.36, 0.82, 0.54, 0.72, 0.42, 0.64, 0.34, 0.76, 0.5]

    var body: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 56)

            VStack(spacing: 8) {
                Text("Hear the difference")
                    .font(PoetTheme.editorial(34, weight: .regular))
                Text("Switch between the clean edit and the polished finish while it plays.")
                    .font(PoetTheme.utility(12))
                    .foregroundStyle(PoetTheme.muted)
            }

            HStack(spacing: 4) {
                ForEach(PolishPreviewMode.allCases) { mode in
                    Button(mode.rawValue) { model.selectPolishPreview(mode) }
                        .buttonStyle(PreviewChoiceStyle(selected: model.polishPreviewMode == mode))
                }
            }
            .padding(4)
            .background(PoetTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(width: 270)

            VStack(spacing: 22) {
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(PoetTheme.background)
                        .frame(width: 62, height: 62)
                        .background(PoetTheme.sage)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                GeometryReader { geometry in
                    let playbackProgress = min(max(model.currentTime / max(model.estimatedEditedDuration, 0.01), 0), 1)
                    HStack(alignment: .center, spacing: 4) {
                        ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                            Capsule()
                                .fill(Double(index) / Double(levels.count) <= playbackProgress ? PoetTheme.sage : PoetTheme.faint.opacity(0.42))
                                .frame(maxWidth: .infinity)
                                .frame(height: 5 + level * 38)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let ratio = min(max(value.location.x / geometry.size.width, 0), 1)
                        model.seek(to: ratio * model.estimatedEditedDuration)
                    })
                }
                .frame(height: 48)

                HStack {
                    Text(clock(model.currentTime))
                    Spacer()
                    Text(clock(model.estimatedEditedDuration))
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PoetTheme.muted)
            }
            .padding(26)
            .frame(maxWidth: 700)
            .background(PoetTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            HStack(spacing: 18) {
                PreviewFact(label: "Finish", value: model.loudnessPreset.rawValue)
                PreviewFact(label: "Target", value: "\(Int(model.loudnessPreset.targetLUFS)) LUFS")
                PreviewFact(label: "Processes", value: "\(model.enabledPolishCount) enabled")
            }

            HStack(spacing: 10) {
                Button("Adjust polish") { model.editPolishSettings() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Continue to export") { model.goToExport() }
                    .buttonStyle(PrimaryButtonStyle())
            }

            Spacer(minLength: 84)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clock(_ value: TimeInterval) -> String {
        String(format: "%d:%02d", max(0, Int(value)) / 60, max(0, Int(value)) % 60)
    }
}

private struct PreviewFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(label.uppercased())
                .font(PoetTheme.utility(8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(PoetTheme.faint)
            Text(value)
                .font(PoetTheme.utility(11, weight: .semibold))
        }
        .frame(width: 110)
    }
}

private struct PreviewChoiceStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PoetTheme.utility(11, weight: .semibold))
            .foregroundStyle(selected ? PoetTheme.background : PoetTheme.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(selected ? PoetTheme.sage : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct PolishingProgressView: View {
    @EnvironmentObject private var model: AppModel

    @State private var visibleStage = 0

    private let stages = [
        "Preparing the edit",
        "Reducing room noise",
        "Balancing the voice",
        "Softening sharp sounds",
        "Controlling dynamics",
        "Finishing the level"
    ]

    var body: some View {
        VStack(spacing: 38) {
            Spacer()
            Text("Polishing your take")
                .font(PoetTheme.editorial(34, weight: .regular))

            VStack(spacing: 15) {
                ForEach(stages.indices, id: \.self) { index in
                    PolishingStageText(
                        text: stages[index],
                        isActive: index == visibleStage,
                        inactiveOpacity: distanceOpacity(index)
                    )
                        .scaleEffect(index == visibleStage ? 1 : 0.625)
                        .offset(y: CGFloat(index - visibleStage) * 2)
                        .frame(height: index == visibleStage ? 29 : 18)
                }
            }
            .frame(height: 220)
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: visibleStage)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(PoetTheme.elevated).frame(height: 3)
                    Capsule().fill(PoetTheme.sage)
                        .frame(width: geometry.size.width * progress, height: 3)
                        .animation(.easeInOut(duration: 0.45), value: visibleStage)
                }
            }
            .frame(width: 420, height: 3)

            Text("Your recording stays on this Mac.")
                .font(PoetTheme.utility(11))
                .foregroundStyle(PoetTheme.faint)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { advance(to: stageIndex(for: model.polishCurrentStage)) }
        .onChange(of: model.polishCurrentStage) { _, stage in
            advance(to: stageIndex(for: stage))
        }
    }

    private var progress: Double { Double(visibleStage + 1) / Double(stages.count) }

    private func distanceOpacity(_ index: Int) -> Double {
        max(0.22, 0.72 - Double(abs(index - visibleStage)) * 0.18)
    }

    private func advance(to next: Int) {
        guard next > visibleStage else { return }
        visibleStage = next
    }

    private func stageIndex(for stage: String?) -> Int {
        let raw = (stage ?? "").lowercased()
        if raw.contains("noise") || raw.contains("denois") { return 1 }
        if raw.contains("baseline") { return 2 }
        if raw.contains("loudness") || raw.contains("normal") || raw.contains("quality") { return 5 }
        if raw.contains("de-ess") || raw.contains("sibil") { return 3 }
        if raw.contains("breath") { return 4 }
        if raw.contains("eq") || raw.contains("voice") { return 2 }
        if raw.contains("compare") || raw.contains("gentle") || raw.contains("compression") { return 4 }
        return 0
    }
}

private struct PolishingStageText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    let isActive: Bool
    let inactiveOpacity: Double

    private let cycleDuration = 3.2
    private let shimmerColors = [
        PoetTheme.cream,
        Color(hex: 0xF1BFD2),
        Color(hex: 0xCDBFEF),
        Color(hex: 0xB8D8F0),
        Color(hex: 0xBFE5D0),
        PoetTheme.cream
    ]

    var body: some View {
        Group {
            if isActive {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
                    let phase = reduceMotion ? 0.5 : shimmerPhase(at: context.date)
                    Text(text)
                        .foregroundStyle(
                            LinearGradient(
                                colors: shimmerColors,
                                startPoint: UnitPoint(x: phase * 2.2 - 1.2, y: 0.5),
                                endPoint: UnitPoint(x: phase * 2.2 + 0.8, y: 0.5)
                            )
                        )
                        .shadow(color: Color(hex: 0xCDBFEF).opacity(0.2), radius: 5)
                        .shadow(color: Color(hex: 0xBFE5D0).opacity(0.12), radius: 9)
                }
            } else {
                Text(text)
                    .foregroundStyle(PoetTheme.muted.opacity(inactiveOpacity))
            }
        }
        // Keep one weight throughout the scale animation so the active line
        // arrives bold instead of snapping to bold after it finishes growing.
        .font(PoetTheme.utility(24, weight: .semibold))
    }

    private func shimmerPhase(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
    }
}
