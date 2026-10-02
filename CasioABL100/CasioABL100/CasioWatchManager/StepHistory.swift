import Foundation

/// Pasos de un día, guardados en el iPhone.
struct StepDay: Codable, Equatable, Identifiable {
    /// "yyyy-MM-dd" (fecha del reloj)
    let date: String
    var steps: Int
    var distanceMeters: Int
    /// Pasos por hora (índice = hora); nil = sin dato
    var hourly: [Int?]

    var id: String { date }
}

/// Histórico de pasos en `UserDefaults`, fusionando cada lectura del lifelog.
///
/// Hace falta porque el reloj entrega cada registro horario **una sola vez**: tras cerrar la
/// transacción (`04 11`), la siguiente lectura los devuelve vacíos (`fe ff`) aunque el total del día
/// siga ahí (verificado el 2026-09-29, con otra app leyendo antes que la nuestra). Así el gráfico
/// por horas no se pierde, y el histórico de días sale de datos verificados en vez de los
/// resúmenes diarios del reloj, cuyo orden no conocemos.
final class StepHistory {
    private static let key = "hoursync.stepHistory"
    private static let daysKept = 30

    private(set) var days: [String: StepDay]

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        days = data.flatMap { try? JSONDecoder().decode([String: StepDay].self, from: $0) } ?? [:]
    }

    /// Fusiona una lectura con lo guardado para su fecha y devuelve el día resultante.
    @discardableResult
    func merge(_ reading: StepCounterData) -> StepDay? {
        guard let timestamp = reading.timestamp, let steps = reading.todaySteps else { return nil }
        let date = Self.dateKey(timestamp)
        var day = days[date] ?? StepDay(date: date, steps: 0, distanceMeters: 0,
                                        hourly: [Int?](repeating: nil, count: 24))
        // El total del día solo crece; una hora ya guardada no se pierde si ahora llega vacía
        day.steps = max(day.steps, steps)
        day.distanceMeters = max(day.distanceMeters, reading.todayDistanceMeters ?? 0)
        for hour in 0..<24 {
            if let value = reading.hourlyByHour[hour] {
                day.hourly[hour] = max(day.hourly[hour] ?? 0, value)
            }
        }
        days[date] = day
        prune()
        save()
        return day
    }

    /// Días guardados, del más reciente al más antiguo.
    var sortedDays: [StepDay] {
        days.values.sorted { $0.date > $1.date }
    }

    private func prune() {
        let keep = Set(sortedDays.prefix(Self.daysKept).map(\.date))
        days = days.filter { keep.contains($0.key) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(days) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
