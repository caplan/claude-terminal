import AppKit
import Sparkle

final class Updater: NSObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    var updater: SPUUpdater { controller.updater }

    @IBAction func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
