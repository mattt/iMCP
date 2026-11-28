import Sparkle
import SwiftUI

// Previews build a ServerController, which starts iMCP's network manager.
// They keep the server off (`isEnabled` is false) and don't toggle services.

#Preview("Menu panel") {
    ContentView(
        serverManager: ServerController(),
        isEnabled: .constant(false),
        updater: SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        ).updater,
        openSettings: {}
    )
    .frame(width: 280)
}

#Preview("Settings") {
    SettingsView(serverController: ServerController(), isMenuBarExtraInserted: true)
}

#Preview("General") {
    GeneralSettingsView(isMenuBarExtraInserted: true)
        .frame(width: 500, height: 300)
}

#Preview("Clients") {
    ClientsSettingsView(serverController: ServerController())
        .frame(width: 500, height: 560)
}

#Preview("Service") {
    let controller = ServerController()
    if let config = controller.computedServiceConfigs.first {
        ServiceSettingsView(serverController: controller, config: config)
            .frame(width: 500, height: 560)
    }
}
