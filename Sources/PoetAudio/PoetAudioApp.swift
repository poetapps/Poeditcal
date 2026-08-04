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
        let supportedExtensions = Set(["wav", "m4a", "mp3", "aiff", "aif", "flac", "poe"])
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
    }
}
