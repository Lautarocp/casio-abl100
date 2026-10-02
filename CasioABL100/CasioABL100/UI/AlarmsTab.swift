import SwiftUI

/// Alarmas del reloj, con el aspecto de la pestaña Alarmas de la app Reloj.
/// Se edita una copia local; "Guardar" la escribe en el reloj y la vuelve a leer.
struct AlarmsTab: View {
    @ObservedObject var watchManager = CasioWatchManager.shared
    @State private var draft: [WatchAlarm] = []
    @State private var editing: WatchAlarm?

    var body: some View {
        NavigationStack {
            List {
                if draft.isEmpty {
                    Section {
                        Text("Todavía no se han leído las alarmas.")
                            .foregroundColor(.secondary)
                    } footer: {
                        DisconnectedFooter()
                    }
                } else {
                    Section {
                        ForEach($draft) { $alarm in
                            HStack {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(String(format: "%02ld:%02ld", alarm.hour, alarm.minute))
                                        .font(.clockDigits(54))
                                    Text(title(alarm))
                                        .font(.subheadline)
                                }
                                .foregroundColor(alarm.enabled ? .primary : .secondary)
                                .contentShape(Rectangle())
                                .onTapGesture { editing = alarm }

                                Spacer()

                                Toggle("", isOn: $alarm.enabled)
                                    .labelsHidden()
                                    .tint(.green)
                            }
                        }
                    }

                    Section {
                        Toggle("Señal horaria", isOn: $draft[0].hourlyChime)
                            .tint(.green)
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("El reloj pita cada hora en punto.")
                            DisconnectedFooter()
                        }
                    }
                }
            }
            .navigationTitle("Alarmas")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SaveToolbarButton(
                        busy: watchManager.alarmsBusy,
                        enabled: watchManager.isConnected && !draft.isEmpty && draft != watchManager.alarms
                    ) {
                        watchManager.saveAlarms(draft)
                    }
                }
            }
            .sheet(item: $editing) { alarm in
                AlarmEditor(alarm: alarm) { updated in
                    if let index = draft.firstIndex(where: { $0.id == updated.id }) {
                        draft[index] = updated
                    }
                }
            }
            .onReceive(watchManager.$alarms) { draft = $0 }
        }
    }
}

extension AlarmsTab {
    /// La alarma 5 es la que usa el temporizador de la app
    func title(_ alarm: WatchAlarm) -> String {
        alarm.id == CasioWatchManager.timerAlarmIndex
            ? "Alarma \(alarm.id + 1) · Temporizador"
            : "Alarma \(alarm.id + 1)"
    }
}

/// Editor de una alarma, como el de la app Reloj: rueda de hora y minutos.
private struct AlarmEditor: View {
    @State var alarm: WatchAlarm
    let onDone: (WatchAlarm) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Hora", selection: time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                Toggle("Activada", isOn: $alarm.enabled)
                    .tint(.green)
            }
            .navigationTitle("Alarma \(alarm.id + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        onDone(alarm)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: alarm.hour, minute: alarm.minute)) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                alarm.hour = c.hour ?? 0
                alarm.minute = c.minute ?? 0
                alarm.enabled = true   // como en la app Reloj: cambiar la hora la activa
            }
        )
    }
}
