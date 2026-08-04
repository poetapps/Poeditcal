import Combine
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    let updaterController: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
