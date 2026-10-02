import SwiftUI

@main
struct CasioWatchApp: App {
    init() {
        // Crear el manager en el launch: necesario para la restauración BLE en background
        _ = CasioWatchManager.shared
        FindPhone.shared.setUp()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
