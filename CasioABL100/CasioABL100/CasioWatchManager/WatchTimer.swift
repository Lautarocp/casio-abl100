import Foundation

/// Temporizador (`0x18`). Réplica de GShockAPI `TimerIO`. Verificado en el reloj.
///
/// GET `18` → `18 HH MM SS` + 11 bytes a 0 (15 en el ABL-100; GShockAPI espera 7). SET: el mismo paquete, a 0x2D.
/// GShockAPI arma el SET desde cero; aquí se parte del paquete leído y solo se cambian HH MM SS.
struct WatchTimer: Equatable {
    var hours: Int
    var minutes: Int
    var seconds: Int
    fileprivate var raw: [UInt8]
}

enum TimerCodec {
    static let code: UInt8 = 0x18

    static func parse(_ data: Data) -> WatchTimer? {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == code else { return nil }
        return WatchTimer(hours: Int(b[1]), minutes: Int(b[2]), seconds: Int(b[3]), raw: b)
    }

    static func encode(_ timer: WatchTimer) -> Data {
        var b = timer.raw
        b[1] = UInt8(min(max(timer.hours, 0), 23))
        b[2] = UInt8(min(max(timer.minutes, 0), 59))
        b[3] = UInt8(min(max(timer.seconds, 0), 59))
        return Data(b)
    }
}
