import SwiftUI

/// Se muestra la primera vez que se abre la app: cómo vincular el reloj.
struct WelcomeView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "applewatch.watchface")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundColor(.orange)
                Text("Hour Sync")
                    .font(.largeTitle.bold())
                Text("Hora, alarmas, pasos y temporizador de tu reloj ABL-100WE, sin la app oficial.")
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 20) {
                step("1", "Activa el Bluetooth y acepta los permisos que pida la app.")
                step("2", "Con la app abierta, pulsa el botón inferior izquierdo del reloj. Se vincula solo y sincroniza la hora.")
                step("3", "Después funciona en segundo plano: cada vez que pulses ese botón, el reloj se pone en hora.")
                step("4", "Mantén pulsado el botón inferior derecho para buscar el iPhone.")
            }

            Label("No cierres la app deslizándola en el selector de apps: iOS dejaría de despertarla cuando pulses el reloj.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundColor(.secondary)

            Spacer()

            Button(action: onStart) {
                Text("Empezar")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(24)
        .padding(.top, 24)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.headline.monospacedDigit())
                .foregroundColor(.orange)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.orange.opacity(0.2)))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
