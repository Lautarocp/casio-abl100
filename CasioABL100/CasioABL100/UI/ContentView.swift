import SwiftUI

/// Estética de la app Reloj de iOS: modo oscuro, acento naranja, cifras grandes y finas,
/// listas agrupadas e interruptores verdes.
struct ContentView: View {
    @AppStorage("hoursync.welcomeSeen") private var welcomeSeen = false

    var body: some View {
        TabView {
            WatchTab()
                .tabItem { Label("Reloj", systemImage: "applewatch.watchface") }
            AlarmsTab()
                .tabItem { Label("Alarmas", systemImage: "alarm.fill") }
            StepsTab()
                .tabItem { Label("Pasos", systemImage: "figure.walk") }
            TimerTab()
                .tabItem { Label("Temporizador", systemImage: "timer") }
            SettingsTab()
                .tabItem { Label("Ajustes", systemImage: "gearshape.fill") }
        }
        .tint(.orange)
        .preferredColorScheme(.dark)
        .sheet(isPresented: Binding(get: { !welcomeSeen }, set: { welcomeSeen = !$0 })) {
            WelcomeView {
                welcomeSeen = true
                CasioWatchManager.shared.startScanning()
            }
            .interactiveDismissDisabled()
            .preferredColorScheme(.dark)
        }
    }
}

/// Cifras grandes y finas, como las horas de la app Reloj.
extension Font {
    static func clockDigits(_ size: CGFloat) -> Font {
        .system(size: size, weight: .thin).monospacedDigit()
    }
}

/// Aviso al pie de las pestañas que necesitan el reloj conectado para leer o guardar.
struct DisconnectedFooter: View {
    @ObservedObject var watchManager = CasioWatchManager.shared

    var body: some View {
        if !watchManager.isConnected {
            Label("Pulsa un botón del reloj para conectarlo y leer o guardar cambios.",
                  systemImage: "antenna.radiowaves.left.and.right.slash")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}

/// Botón "Guardar" de la barra de navegación: gira mientras el reloj está ocupado.
struct SaveToolbarButton: View {
    let busy: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        if busy {
            ProgressView()
        } else {
            Button("Guardar", action: action)
                .fontWeight(.semibold)
                .disabled(!enabled)
        }
    }
}

#Preview {
    ContentView()
}
