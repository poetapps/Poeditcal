import SwiftUI

@MainActor
final class PoetAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var pendingOpenURL: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpenURL = urls.first
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        pendingOpenURL = filenames.first.map { URL(fileURLWithPath: $0) }
        sender.reply(toOpenOrPrint: pendingOpenURL == nil ? .failure : .success)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        pendingOpenURL = URL(fileURLWithPath: filename)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard pendingOpenURL == nil else { return }
        pendingOpenURL = Self.launchOpenURL(arguments: CommandLine.arguments)
    }

    nonisolated static func launchOpenURL(
        arguments: [String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        let supportedExtensions = Set(["wav", "m4a", "mp3", "aiff", "aif", "flac", "mov", "mp4", "m4v", "poe"])
        return arguments
            .dropFirst()
            .lazy
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0) }
            .first { url in
                supportedExtensions.contains(url.pathExtension.lowercased())
                    && fileExists(url.path)
            }
    }

    nonisolated static func launchAudioURL(
        arguments: [String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        launchOpenURL(arguments: arguments, fileExists: fileExists).flatMap {
            $0.pathExtension.lowercased() == "poe" ? nil : $0
        }
    }
}

@main
struct PoetAudioApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var denoiseModel = DenoiseModelStore()
    @StateObject private var smartEditModel = SmartEditModelStore.shared
    @StateObject private var updateController = UpdateController()
    @NSApplicationDelegateAdaptor(PoetAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(denoiseModel)
                .environmentObject(smartEditModel)
                .environmentObject(appDelegate)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button("Open Project…") { model.openProjectPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { model.saveProject() }
                    .keyboardShortcut("s")
                    .disabled(model.audioURL == nil || model.isSavingProject)
                Button("Save Project As…") { model.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.audioURL == nil || model.isSavingProject)
            }
        }

        Settings {
            DownloadedModelsSettingsView()
                .environmentObject(model)
                .environmentObject(denoiseModel)
                .environmentObject(smartEditModel)
                .preferredColorScheme(.dark)
        }
    }
}

private enum DownloadedModelRemoval: Identifiable {
    case noiseReduction
    case smartEdit(SmartEditModelChoice)

    var id: String {
        switch self {
        case .noiseReduction: "noise-reduction"
        case .smartEdit(let choice): "smart-edit-\(choice.rawValue)"
        }
    }

    var name: String {
        switch self {
        case .noiseReduction: DenoiseModelStore.modelDisplayName
        case .smartEdit(let choice): choice.modelName
        }
    }
}

private struct DownloadedModelsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var denoiseModel: DenoiseModelStore
    @EnvironmentObject private var smartEditModel: SmartEditModelStore
    @State private var pendingRemoval: DownloadedModelRemoval?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Downloaded Models")
                    .font(PoetTheme.editorial(27, weight: .regular))
                Text("Manage optional models Poet downloaded after installation. Removing one does not affect the app or your projects; you can download it again later.")
                    .font(PoetTheme.utility(11))
                    .foregroundStyle(PoetTheme.muted)
                    .lineSpacing(2)
            }
            .padding(.bottom, 22)

            VStack(spacing: 1) {
                modelRow(
                    title: DenoiseModelStore.modelDisplayName,
                    subtitle: "Steady room-tone and fan-noise removal · 10.6 MB",
                    systemImage: "waveform.badge.minus",
                    isInstalled: denoiseModel.isInstalled
                ) {
                    if denoiseModel.isInstalled {
                        Button("Remove…", role: .destructive) {
                            pendingRemoval = .noiseReduction
                        }
                        .disabled(denoiseModel.isDownloading)
                    }
                }

                ForEach(SmartEditModelChoice.allCases) { choice in
                    modelRow(
                        title: "Smart Edit — \(choice.title)",
                        subtitle: "\(choice.modelName) · \(choice.detail)",
                        systemImage: "brain.head.profile",
                        isInstalled: smartEditModel.isInstalled(choice)
                    ) {
                        if smartEditModel.isInstalled(choice) {
                            Button("Remove…", role: .destructive) {
                                pendingRemoval = .smartEdit(choice)
                            }
                            .disabled(smartEditModel.downloadingChoice == choice)
                        }
                    }
                }
            }
            .background(PoetTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let error = denoiseModel.errorMessage ?? smartEditModel.errorMessage {
                Text(error)
                    .font(PoetTheme.utility(10, weight: .medium))
                    .foregroundStyle(PoetTheme.error)
                    .padding(.top, 12)
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 620, height: 430)
        .background(PoetTheme.background)
        .alert(item: $pendingRemoval) { removal in
            Alert(
                title: Text("Remove \(removal.name)?"),
                message: Text("Its downloaded files will be deleted from this Mac. You can download the model again from Poet whenever you need it."),
                primaryButton: .destructive(Text("Remove Model")) {
                    remove(removal)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func modelRow<Actions: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        isInstalled: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isInstalled ? PoetTheme.sage : PoetTheme.faint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(PoetTheme.utility(11, weight: .semibold))
                Text(subtitle)
                    .font(PoetTheme.utility(9))
                    .foregroundStyle(PoetTheme.muted)
                    .lineLimit(1)
            }

            Spacer()

            Text(isInstalled ? "Downloaded" : "Not downloaded")
                .font(PoetTheme.utility(9, weight: .medium))
                .foregroundStyle(isInstalled ? PoetTheme.sage : PoetTheme.faint)
            actions()
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background(PoetTheme.card)
    }

    private func remove(_ removal: DownloadedModelRemoval) {
        switch removal {
        case .noiseReduction:
            if denoiseModel.uninstall() {
                model.disableNoiseReduction()
            }
        case .smartEdit(let choice):
            smartEditModel.uninstall(choice)
        }
    }
}
