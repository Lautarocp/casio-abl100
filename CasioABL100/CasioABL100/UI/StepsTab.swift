import SwiftUI
import Charts

/// Pasos: hoy, por horas y los días anteriores. Sale del histórico guardado en el iPhone
/// (StepHistory), que se completa con cada lectura del reloj.
struct StepsTab: View {
    @ObservedObject var watchManager = CasioWatchManager.shared

    var body: some View {
        NavigationStack {
            List {
                if let today = today {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(today.steps)")
                                .font(.clockDigits(64))
                            Text("pasos hoy")
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)

                        LabeledContent("Distancia", value: distance(today.distanceMeters))
                        if let timestamp = watchManager.stepData?.timestamp {
                            LabeledContent("Leído del reloj", value: timestamp.formatted(date: .omitted, time: .shortened))
                        }
                    }

                    Section {
                        Chart {
                            ForEach(0..<24, id: \.self) { hour in
                                BarMark(
                                    x: .value("Hora", hour),
                                    y: .value("Pasos", today.hourly[hour] ?? 0),
                                    width: .fixed(7)
                                )
                                .foregroundStyle(.orange)
                            }
                        }
                        .chartXScale(domain: 0...23)
                        .chartXAxis {
                            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let hour = value.as(Int.self) { Text("\(hour)h") }
                                }
                            }
                        }
                        .frame(height: 180)
                        .padding(.vertical, 8)
                    } header: {
                        Text("Por horas")
                    } footer: {
                        Text("La hora en curso se completa en la siguiente lectura.")
                    }
                } else {
                    Section {
                        Text("Todavía no hay pasos de hoy.")
                            .foregroundColor(.secondary)
                    } footer: {
                        DisconnectedFooter()
                    }
                }

                if !previousDays.isEmpty {
                    Section("Días anteriores") {
                        ForEach(previousDays) { day in
                            LabeledContent(dayTitle(day.date)) {
                                Text("\(day.steps) pasos · \(distance(day.distanceMeters))")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pasos")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if watchManager.stepsRunning {
                        ProgressView()
                    } else {
                        Button {
                            watchManager.readSteps()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(!watchManager.isConnected)
                    }
                }
            }
        }
    }

    private var todayKey: String { StepHistory.dateKey(Date()) }

    private var today: StepDay? {
        watchManager.stepDays.first { $0.date == todayKey }
    }

    private var previousDays: [StepDay] {
        Array(watchManager.stepDays.filter { $0.date != todayKey }.prefix(7))
    }

    private func dayTitle(_ key: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }
        if Calendar.current.isDateInYesterday(date) { return "Ayer" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func distance(_ meters: Int) -> String {
        meters < 1000 ? "\(meters) m" : String(format: "%.2f km", Double(meters) / 1000)
    }
}
