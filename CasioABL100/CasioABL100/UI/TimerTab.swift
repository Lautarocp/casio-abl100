import SwiftUI

/// Temporizador, con el aspecto de la pestaña Temporizador de la app Reloj: ruedas de horas y
/// minutos y botones circulares.
/// - Iniciar: pone la alarma 5 del reloj a ahora + la duración (el reloj suena solo).
/// - Guardar: guarda la duración en el temporizador del propio reloj.
struct TimerTab: View {
    @ObservedObject var watchManager = CasioWatchManager.shared
    @State private var draft: WatchTimer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                if draft != nil {
                    HStack(spacing: 0) {
                        wheel(\.hours, range: 0..<24, unit: "horas")
                        wheel(\.minutes, range: 0..<60, unit: "min")
                    }
                    .padding(.horizontal)

                    HStack {
                        CircleButton(title: "Iniciar", color: .green) {
                            if let draft = draft {
                                watchManager.startTimerAlarm(hours: draft.hours, minutes: draft.minutes)
                            }
                        }
                        .disabled(!canStart)

                        Spacer()

                        if watchManager.timerBusy {
                            ProgressView()
                                .frame(width: 84, height: 84)
                        } else {
                            CircleButton(title: "Guardar", color: .orange) {
                                if let draft = draft { watchManager.saveTimer(draft) }
                            }
                            .disabled(!watchManager.isConnected || draft == watchManager.timer)
                        }
                    }
                    .padding(.horizontal, 24)

                    if let due = watchManager.timerAlarmDue, due > Date() {
                        HStack(spacing: 6) {
                            Image(systemName: "alarm.fill")
                                .foregroundColor(.orange)
                            Text("La alarma 5 sonará a las \(TimeZoneRow.time(due, in: watchManager.watchTimeZone, seconds: false))")
                            Button("Cancelar") { watchManager.cancelTimerAlarm() }
                                .disabled(!watchManager.isConnected || watchManager.alarmsBusy)
                        }
                        .font(.subheadline)
                    } else {
                        Text("Iniciar pone la alarma 5 del reloj a esta duración desde ahora. Guardar lo guarda en el temporizador del reloj.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    Text("Todavía no se ha leído el temporizador.")
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                }

                DisconnectedFooter()
                    .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("Temporizador")
            .onReceive(watchManager.$timer) { draft = $0 }
        }
    }

    private var canStart: Bool {
        guard let draft = draft else { return false }
        return watchManager.isConnected && !watchManager.alarmsBusy
            && watchManager.alarms.count > CasioWatchManager.timerAlarmIndex
            && (draft.hours > 0 || draft.minutes > 0)
    }

    private func wheel(_ keyPath: WritableKeyPath<WatchTimer, Int>, range: Range<Int>, unit: String) -> some View {
        HStack(spacing: 4) {
            Picker(unit, selection: Binding(
                get: { draft?[keyPath: keyPath] ?? 0 },
                set: { draft?[keyPath: keyPath] = $0 }
            )) {
                ForEach(range, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(width: 64)
            .clipped()

            Text(unit)
                .fontWeight(.semibold)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Botón redondo de la app Reloj: círculo relleno con el color apagado y un anillo alrededor.
private struct CircleButton: View {
    let title: String
    let color: Color
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(color)
                .frame(width: 84, height: 84)
                .background(Circle().fill(color.opacity(0.25)))
                .overlay(Circle().stroke(color.opacity(0.25), lineWidth: 2).padding(-5))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
    }
}
