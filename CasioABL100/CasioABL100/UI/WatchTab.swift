import SwiftUI

/// Pestaña principal: la hora que tiene el reloj, la ciudad (hora mundial) y la conexión.
struct WatchTab: View {
    @ObservedObject var watchManager = CasioWatchManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(TimeZoneRow.time(context.date, in: watchManager.watchTimeZone, seconds: true))
                                .font(.clockDigits(64))
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                            Text(zoneLabel)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                    }

                    NavigationLink {
                        TimeZonePicker(selection: $watchManager.watchTimeZoneID)
                    } label: {
                        LabeledContent {
                            Text(watchManager.watchTimeZoneID == nil ? "Automática" : TimeZoneRow.city(watchManager.watchTimeZone))
                        } label: {
                            Label("Hora mundial", systemImage: "globe")
                        }
                    }
                }

                Section("Conexión") {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(watchManager.isConnected ? Color.green : Color.gray)
                            .frame(width: 10, height: 10)
                        Text(watchManager.connectionStatus)
                    }

                    if let press = watchManager.lastButtonPress {
                        LabeledContent("Último botón") {
                            Text("\(press.button.displayName) · \(press.timestamp.formatted(date: .omitted, time: .shortened))")
                        }
                    }

                    if watchManager.isConnected {
                        Button {
                            watchManager.setTime()
                        } label: {
                            Label("Sincronizar hora", systemImage: "clock.arrow.2.circlepath")
                        }
                        .disabled(watchManager.timeSyncRunning)
                    }

                    if watchManager.isConnected {
                        Button("Desconectar", role: .destructive) { watchManager.disconnect() }
                    } else {
                        Button("Conectar reloj") { watchManager.startScanning() }
                    }
                }
            }
            .navigationTitle("Hour Sync")
        }
    }

    private var zoneLabel: String {
        let zone = watchManager.watchTimeZone
        let name = watchManager.watchTimeZoneID == nil ? "Hora del iPhone" : TimeZoneRow.city(zone)
        return "\(name), \(TimeZoneRow.offset(zone))"
    }
}

extension WatchButton {
    var displayName: String {
        switch self {
        case .lowerLeft: return "Inferior izquierdo"
        case .lowerRight: return "Inferior derecho"
        case .lowerRightLong: return "Inferior derecho (largo)"
        case .resetButton: return "Reset"
        case .noButton: return "Ajuste automático"
        case .alwaysConnected: return "Siempre conectado"
        }
    }
}
