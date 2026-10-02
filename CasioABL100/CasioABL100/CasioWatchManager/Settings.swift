import Foundation

/// Ajustes básicos (`0x13`). Réplica de GShockAPI `SettingsIO`. Verificado en el reloj.
///
/// - Byte 1: bit 0 = 24 h, bit 1 = tono de botones APAGADO, bit 4 = ahorro de energía APAGADO.
/// - Byte 2: bit 0 = luz larga.
///
/// GShockAPI arma el SET desde cero (todo a 0); aquí se parte del paquete leído y solo se tocan
/// esos bits, para no cambiar nada que no entendamos.
struct WatchSettings: Equatable {
    var is24Hour: Bool
    var buttonTone: Bool
    var powerSaving: Bool
    var longLight: Bool
    fileprivate var raw: [UInt8]
}

/// Ajuste automático de hora (`0x11`, SETTING_FOR_BLE). Réplica de GShockAPI `TimeAdjustmentIO`.
///
/// - Byte 12: `00` = activado, `80` = desactivado.
/// - Byte 13: minuto (0...59) en el que el reloj se conecta para ajustar la hora.
struct TimeAdjustment: Equatable {
    var enabled: Bool
    var minute: Int
    fileprivate var raw: [UInt8]
}

enum SettingsCodec {
    static let settingsCode: UInt8 = 0x13
    static let timeAdjustmentCode: UInt8 = 0x11

    private static let mask24Hour: UInt8 = 0x01
    private static let maskButtonToneOff: UInt8 = 0x02
    private static let maskPowerSavingOff: UInt8 = 0x10
    private static let maskLongLight: UInt8 = 0x01
    private static let maskAdjustmentOff: UInt8 = 0x80

    static func parseSettings(_ data: Data) -> WatchSettings? {
        let b = [UInt8](data)
        guard b.count >= 3, b[0] == settingsCode else { return nil }
        return WatchSettings(
            is24Hour: b[1] & mask24Hour != 0,
            buttonTone: b[1] & maskButtonToneOff == 0,
            powerSaving: b[1] & maskPowerSavingOff == 0,
            longLight: b[2] & maskLongLight != 0,
            raw: b
        )
    }

    static func encode(_ settings: WatchSettings) -> Data {
        var b = settings.raw
        b[1] = set(b[1], mask24Hour, settings.is24Hour)
        b[1] = set(b[1], maskButtonToneOff, !settings.buttonTone)
        b[1] = set(b[1], maskPowerSavingOff, !settings.powerSaving)
        b[2] = set(b[2], maskLongLight, settings.longLight)
        return Data(b)
    }

    static func parseTimeAdjustment(_ data: Data) -> TimeAdjustment? {
        let b = [UInt8](data)
        guard b.count >= 14, b[0] == timeAdjustmentCode else { return nil }
        return TimeAdjustment(
            enabled: b[12] & maskAdjustmentOff == 0,
            minute: b[13] <= 59 ? Int(b[13]) : 30,
            raw: b
        )
    }

    static func encode(_ adjustment: TimeAdjustment) -> Data {
        var b = adjustment.raw
        b[12] = set(b[12], maskAdjustmentOff, !adjustment.enabled)
        b[13] = UInt8(min(max(adjustment.minute, 0), 59))
        return Data(b)
    }

    private static func set(_ byte: UInt8, _ mask: UInt8, _ on: Bool) -> UInt8 {
        on ? byte | mask : byte & ~mask
    }
}
