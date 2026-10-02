import SwiftUI

/// Ajustes del reloj (0x13), ajuste automático de hora (0x11) y opciones de la app.
/// Los ajustes del reloj se editan en una copia local y "Guardar" los escribe y los vuelve a leer;
/// la pulsación larga es de la app y se aplica al momento.
struct SettingsTab: View {
    @ObservedObject var watchManager = CasioWatchManager.shared
    @State private var settings: WatchSettings?
    @State private var adjustment: TimeAdjustment?
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if settings != nil {
                        Toggle("Formato 24 horas", isOn: binding(\.is24Hour))
                            .tint(.green)
                        Toggle("Sonido de botones", isOn: binding(\.buttonTone))
                            .tint(.green)
                        Toggle("Ahorro de energía", isOn: binding(\.powerSaving))
                            .tint(.green)
                        Toggle("Luz larga", isOn: binding(\.longLight))
                            .tint(.green)
                    } else {
                        Text("Todavía no se han leído los ajustes.")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Reloj")
                } footer: {
                    DisconnectedFooter()
                }

                if adjustment != nil {
                    Section {
                        Toggle("Ajuste automático", isOn: adjustmentBinding(\.enabled, default: false))
                            .tint(.green)
                        Stepper(value: adjustmentBinding(\.minute, default: 0), in: 0...59) {
                            LabeledContent("Minuto", value: "\(adjustment?.minute ?? 0)")
                        }
                    } header: {
                        Text("Hora")
                    } footer: {
                        Text("Varias veces al día, en este minuto, el reloj se conecta solo para ajustar la hora.")
                    }
                }

                Section {
                    Picker("Acción", selection: $watchManager.longPressAction) {
                        ForEach(LongPressAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .pickerStyle(.segmented)

                    if watchManager.longPressAction == .playSong {
                        TextField("Enlace de Apple Music", text: $watchManager.songLink)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        Button("Probar") { watchManager.runLongPressAction() }
                            .disabled(SongPlayer.storeID(from: watchManager.songLink) == nil)
                    }
                } header: {
                    Text("Pulsación larga (botón inferior derecho)")
                } footer: {
                    Text(longPressHint)
                }

                Section {
                    LabeledContent("Modelo", value: watchManager.watchName)
                    Button("Olvidar reloj", role: .destructive) { confirmForget = true }
                } header: {
                    Text("Reloj vinculado")
                }
            }
            .navigationTitle("Ajustes")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SaveToolbarButton(
                        busy: watchManager.settingsBusy,
                        enabled: watchManager.isConnected && hasChanges
                    ) {
                        if let settings = settings, let adjustment = adjustment {
                            watchManager.saveSettings(settings, adjustment)
                        }
                    }
                }
            }
            .confirmationDialog("¿Olvidar este reloj?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Olvidar reloj", role: .destructive) { watchManager.forgetWatch() }
            } message: {
                Text("Para volver a usarlo, pulsa \"Conectar reloj\" y un botón del reloj con la app abierta.")
            }
            .onChange(of: watchManager.longPressAction) { action in
                if action == .playSong { SongPlayer.requestAuthorization() }
            }
            .onReceive(watchManager.$settings) { settings = $0 }
            .onReceive(watchManager.$timeAdjustment) { adjustment = $0 }
        }
    }

    private var longPressHint: String {
        guard watchManager.longPressAction == .playSong else {
            return "El iPhone suena hasta que paras la búsqueda en el reloj."
        }
        if !watchManager.songLink.isEmpty && SongPlayer.storeID(from: watchManager.songLink) == nil {
            return "Ese enlace no es de una canción. En Música: ··· → Compartir → Copiar enlace."
        }
        return "En Música: ··· → Compartir → Copiar enlace, y pégalo aquí."
    }

    private var hasChanges: Bool {
        settings != nil && adjustment != nil
            && (settings != watchManager.settings || adjustment != watchManager.timeAdjustment)
    }

    private func binding(_ keyPath: WritableKeyPath<WatchSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings?[keyPath: keyPath] ?? false },
            set: { settings?[keyPath: keyPath] = $0 }
        )
    }

    private func adjustmentBinding<Value>(_ keyPath: WritableKeyPath<TimeAdjustment, Value>,
                                          default fallback: Value) -> Binding<Value> {
        Binding(
            get: { adjustment?[keyPath: keyPath] ?? fallback },
            set: { adjustment?[keyPath: keyPath] = $0 }
        )
    }
}
