import SwiftUI

/// Hora mundial: lista de ciudades (zonas horarias del sistema) con buscador.
/// Solo cambia la hora de `0x09`; los registros de zona del reloj (`1D`/`1E`) no se tocan.
struct TimeZonePicker: View {
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private static let zones: [TimeZone] = TimeZone.knownTimeZoneIdentifiers
        .compactMap { TimeZone(identifier: $0) }
        .filter { $0.identifier.contains("/") && !$0.identifier.hasPrefix("Etc/") }
        .sorted { TimeZoneRow.city($0) < TimeZoneRow.city($1) }

    private var filtered: [TimeZone] {
        guard !search.isEmpty else { return Self.zones }
        return Self.zones.filter {
            TimeZoneRow.city($0).localizedCaseInsensitiveContains(search)
                || $0.identifier.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            List {
                Button {
                    selection = nil
                    dismiss()
                } label: {
                    row(title: "Hora del iPhone", subtitle: TimeZone.current.identifier,
                        zone: .current, selected: selection == nil, now: context.date)
                }

                ForEach(filtered, id: \.identifier) { zone in
                    Button {
                        selection = zone.identifier
                        dismiss()
                    } label: {
                        row(title: TimeZoneRow.city(zone), subtitle: zone.identifier,
                            zone: zone, selected: selection == zone.identifier, now: context.date)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Buscar ciudad")
        .navigationTitle("Hora mundial")
    }

    private func row(title: String, subtitle: String, zone: TimeZone, selected: Bool, now: Date) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(.primary)
                Text("\(subtitle) · \(TimeZoneRow.offset(zone))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(TimeZoneRow.time(now, in: zone, seconds: false))
                .monospacedDigit()
                .foregroundColor(.primary)
            if selected {
                Image(systemName: "checkmark").foregroundColor(.accentColor)
            }
        }
    }
}

enum TimeZoneRow {
    /// "America/Argentina/Buenos_Aires" → "Buenos Aires"
    static func city(_ zone: TimeZone) -> String {
        (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier)
            .replacingOccurrences(of: "_", with: " ")
    }

    /// "GMT+2", "GMT-3", "GMT+5:30"
    static func offset(_ zone: TimeZone) -> String {
        let seconds = zone.secondsFromGMT()
        let sign = seconds < 0 ? "-" : "+"
        let hours = abs(seconds) / 3600
        let minutes = abs(seconds) % 3600 / 60
        return minutes == 0 ? "GMT\(sign)\(hours)" : String(format: "GMT%@%ld:%02ld", sign, hours, minutes)
    }

    static func time(_ date: Date, in zone: TimeZone, seconds: Bool) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return formatter.string(from: date)
    }
}
