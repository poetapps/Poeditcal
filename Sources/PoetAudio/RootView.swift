import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appDelegate: PoetAppDelegate
    @EnvironmentObject private var denoiseModel: DenoiseModelStore
    @AppStorage("hasSeenDenoiseModelOfferV1") private var hasSeenDenoiseModelOffer = false
    @State private var showingDenoiseModelSetup = false

    private var showsWorkflowDock: Bool {
        (model.phase == .edit || model.phase == .polish || model.phase == .export) && !model.isPreparingPolishPreview
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PoetTheme.background.ignoresSafeArea()

            Group {
                switch model.phase {
                case .welcome: WelcomeView()
                case .setup: EditSetupView()
                case .processing: ProcessingView()
                case .edit: TranscriptEditView()
                case .polish: PolishView()
                case .export: ExportView()
                }
            }
            .id(model.phase)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.975)).combined(with: .move(edge: .trailing)),
                removal: .opacity.combined(with: .scale(scale: 1.015)).combined(with: .move(edge: .leading))
            ))

            if model.phase != .welcome {
                AppMark()
                    .padding(.leading, 24)
                    .padding(.top, 18)
            }

            if showsWorkflowDock {
                ProjectControls()
                    .padding(.trailing, 24)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsWorkflowDock {
                WorkflowDock()
                    .padding(.horizontal, 26)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .foregroundStyle(PoetTheme.cream)
        .animation(.spring(response: 0.52, dampingFraction: 0.86), value: model.phase)
        .onOpenURL { model.openURL($0) }
        .task {
            if let url = appDelegate.pendingOpenURL { model.openURL(url) }
            if !hasSeenDenoiseModelOffer && !denoiseModel.isInstalled {
                showingDenoiseModelSetup = true
            }
        }
        .onChange(of: appDelegate.pendingOpenURL) { _, url in
            if let url { model.openURL(url) }
        }
        .onChange(of: denoiseModel.isInstalled) { _, installed in
            guard installed else { return }
            model.enableNoiseReductionIfAvailable()
            showingDenoiseModelSetup = false
        }
        .sheet(isPresented: $showingDenoiseModelSetup, onDismiss: {
            hasSeenDenoiseModelOffer = true
        }) {
            DenoiseModelSetupView()
                .environmentObject(denoiseModel)
        }
    }
}

private struct ProjectControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let status = model.projectStatus {
                Text(status)
                    .font(PoetTheme.utility(10))
                    .foregroundStyle(status.hasPrefix("Couldn’t") ? PoetTheme.error : PoetTheme.muted)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            TextField("Project name", text: $model.projectName)
                .textFieldStyle(.plain)
                .font(PoetTheme.utility(12, weight: .semibold))
                .multilineTextAlignment(.trailing)
                .frame(width: 180)
                .padding(.horizontal, 13)
                .frame(height: 36)
                .background(PoetTheme.card.opacity(0.94))
                .clipShape(Capsule())

            Button { model.saveProject() } label: {
                Label(model.isSavingProject ? "Saving" : "Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(PrimaryButtonStyle(compact: true))
            .disabled(model.isSavingProject || model.audioURL == nil)
        }
    }
}

private struct AppMark: View {
    var body: some View {
        ZStack {
            Circle().fill(PoetTheme.sageDark)
            PoeditcalMark()
                .frame(width: 10, height: 19)
        }
        .frame(width: 34, height: 34)
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
        .accessibilityLabel(PoeditcalBrand.name)
    }
}

private struct WorkflowDock: View {
    @EnvironmentObject private var model: AppModel
    private let labels = ["Edit", "Polish", "Export"]

    var body: some View {
        HStack(spacing: 18) {
            Button { model.goBack() } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(DockButtonStyle())

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    Button { model.goToStep(index) } label: {
                        HStack(spacing: 7) {
                            ZStack {
                                Circle()
                                    .stroke(index == model.activeStep ? PoetTheme.sage : PoetTheme.faint, lineWidth: 1.5)
                                    .frame(width: 20, height: 20)
                                if index < model.activeStep {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(PoetTheme.sage)
                                } else if index == model.activeStep {
                                    Circle().fill(PoetTheme.sage).frame(width: 8, height: 8)
                                }
                            }
                            Text(label)
                                .font(PoetTheme.utility(11, weight: index == model.activeStep ? .semibold : .medium))
                                .foregroundStyle(index == model.activeStep ? PoetTheme.cream : PoetTheme.muted)
                        }
                    }
                    .buttonStyle(.plain)

                    if index < labels.count - 1 {
                        Rectangle()
                            .fill(index < model.activeStep ? PoetTheme.sage.opacity(0.55) : PoetTheme.elevated)
                            .frame(width: 42, height: 1)
                    }
                }
            }

            Spacer(minLength: 8)

            if model.phase != .export {
                Button { performPrimaryAction() } label: {
                    HStack(spacing: 8) {
                        Text(primaryActionTitle)
                        Image(systemName: primaryActionIcon)
                    }
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .disabled(primaryActionDisabled)
            } else {
                Color.clear.frame(width: 122, height: 38)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: 780)
        .frame(height: 58)
        .background(.ultraThinMaterial.opacity(0.7))
        .background(PoetTheme.card.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .frame(maxWidth: .infinity)
    }

    private var isPolishSettings: Bool {
        model.phase == .polish && !model.isShowingPolishPreview
    }

    private var primaryActionTitle: String {
        if model.phase == .edit { return "Review polish" }
        if isPolishSettings { return "Apply Polish" }
        return "Continue to export"
    }

    private var primaryActionIcon: String {
        isPolishSettings ? "wand.and.stars" : "arrow.right"
    }

    private var primaryActionDisabled: Bool {
        isPolishSettings && (!model.usePolish || model.audioURL == nil)
    }

    private func performPrimaryAction() {
        if isPolishSettings {
            model.applyPolish()
        } else {
            model.goForward()
        }
    }
}

private struct DockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PoetTheme.utility(11, weight: .semibold))
            .foregroundStyle(PoetTheme.muted)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
