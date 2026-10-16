import SwiftUI

@main
struct PulseAppApp: App {
    init() {
        // Crea el gestor Bluetooth al arrancar (también cuando iOS relanza la app en segundo plano)
        WhoopManager.shared.refreshHrMax()
        if WhoopSettings.autoConnect { WhoopManager.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
