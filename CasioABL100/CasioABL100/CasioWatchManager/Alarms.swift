import Foundation

/// Alarma del reloj. Réplica de GShockAPI `AlarmsIO` / `model/Alarms.kt`.
/// Lectura y escritura verificadas en el reloj (5 alarmas: 1 en `15` + 4 en `16`).
///
/// - GET `15` → `15 FLAG 40 HH MM` (alarma 1)
/// - GET `16` → `16` + n × `FLAG 40 HH MM` (el resto; GShockAPI espera 4)
/// - SET: los mismos paquetes, a 0x2D.
///
/// FLAG: `0x40` = activada, `0x80` = señal horaria (solo tiene sentido en la alarma 1).
/// Los bits que no entendemos se conservan tal cual; el segundo byte también, salvo si llega `00` (entonces `40`, como GShockAPI).
struct WatchAlarm: Identifiable, Equatable {
    let id: Int
    var hour: Int
    var minute: Int
    var enabled: Bool
    var hourlyChime: Bool
    fileprivate var rawFlag: UInt8
    fileprivate var rawSecond: UInt8
}

enum AlarmCodec {
    static let firstCode: UInt8 = 0x15
    static let restCode: UInt8 = 0x16
    private static let enabledMask: UInt8 = 0x40
    private static let chimeMask: UInt8 = 0x80
    private static let entrySize = 4
    private static let secondByte: UInt8 = 0x40

    /// Junta las respuestas de `15` y `16`. nil si alguna no tiene el formato esperado.
    static func parse(first: Data, rest: Data) -> [WatchAlarm]? {
        let a = [UInt8](first), b = [UInt8](rest)
        guard a.count >= 1 + entrySize, a[0] == firstCode,
              b.count >= 1, b[0] == restCode else { return nil }

        var entries = [Array(a[1...entrySize])]
        var offset = 1
        while offset + entrySize <= b.count {
            entries.append(Array(b[offset..<offset + entrySize]))
            offset += entrySize
        }

        return entries.enumerated().map { index, e in
            WatchAlarm(
                id: index,
                hour: Int(e[2]),
                minute: Int(e[3]),
                enabled: e[0] & enabledMask != 0,
                hourlyChime: e[0] & chimeMask != 0,
                rawFlag: e[0],
                rawSecond: e[1]
            )
        }
    }

    /// Paquetes SET para `15` y `16`, en ese orden.
    static func encode(_ alarms: [WatchAlarm]) -> [Data] {
        guard let first = alarms.first else { return [] }
        var packets = [Data([firstCode] + entry(first))]
        if alarms.count > 1 {
            packets.append(Data([restCode] + alarms.dropFirst().flatMap(entry)))
        }
        return packets
    }

    private static func entry(_ alarm: WatchAlarm) -> [UInt8] {
        var flag = alarm.rawFlag & ~(enabledMask | chimeMask)
        if alarm.enabled { flag |= enabledMask }
        if alarm.hourlyChime { flag |= chimeMask }
        // Con el reloj recién reiniciado llega 00; GShockAPI escribe siempre 40
        let second = alarm.rawSecond == 0 ? secondByte : alarm.rawSecond
        return [flag, second, UInt8(alarm.hour), UInt8(alarm.minute)]
    }
}
