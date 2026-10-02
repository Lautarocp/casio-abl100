import Foundation

/// Lifelog (pasos) del ABL-100WE. Réplica de GShockAPI `StepCounterIO` / gshock_api `step_counter_io.py`.
/// Verificado en el reloj (ver PROTOCOL.md).
struct StepCounterData {
    /// Hora del reloj en la que se generó el registro
    var timestamp: Date?
    var todaySteps: Int?
    var todayDistanceMeters: Int?
    /// Pasos por hora del día (índice = hora, 0...23); nil = sin dato
    var hourlyByHour: [Int?]
    /// Los 7 resúmenes diarios en el orden en que llegan (orden sin verificar)
    var dailySteps: [Int?]
    var dailyDistancesMeters: [Int?]
    var warnings: [String]
    var raw: Data
}

enum StepCounterParser {
    private static let headerSize = 6
    private static let activityRecordSize = 10
    private static let activityScanLimit = 146
    private static let sentinelBucket = 0xFFFE
    private static let sentinelDaily = 0xFFFF_FFFE
    private static let dailySummaryOffset = 318
    private static let dailySummaryCount = 7
    private static let dailySummarySize = 8
    private static let currentStepsOffset = 374
    private static let currentDistanceOffset = 378
    private static let pendingIntensityOffset = 382

    static func parse(_ payload: Data) -> StepCounterData? {
        let p = [UInt8](payload)
        guard p.count >= headerSize else { return nil }
        var warnings: [String] = []

        // Cabecera: año, mes, día, h, m, s en BCD
        var timestamp: Date?
        var hour: Int?
        let f = p[0..<6].compactMap(decodeBCD)
        if f.count == 6 {
            let c = DateComponents(year: 2000 + f[0], month: f[1], day: f[2], hour: f[3], minute: f[4], second: f[5])
            timestamp = Calendar(identifier: .gregorian).date(from: c)
            hour = f[3] < 24 ? f[3] : nil
        } else {
            warnings.append("invalid BCD timestamp")
        }

        var todaySteps = u32(p, currentStepsOffset)
        if todaySteps == sentinelDaily { todaySteps = nil }

        var pendingSteps = 0
        for i in 0..<3 {
            if let value = u16(p, pendingIntensityOffset + i * 2), value != sentinelBucket {
                pendingSteps += value
            }
        }

        // Los registros horarios (10 bytes = 5 buckets) tienen longitud variable: el final es
        // el que mejor cuadra la suma de buckets con los pasos de hoy.
        var recordEnd = headerSize
        if let today = todaySteps {
            var minDiff = Int.max
            for end in stride(from: headerSize, through: activityScanLimit, by: activityRecordSize) {
                var total = 0
                for offset in stride(from: headerSize, to: end, by: activityRecordSize) {
                    total += bucketSum(p, offset)
                }
                let diff = abs(today - pendingSteps - total)
                if diff < minDiff {
                    minDiff = diff
                    recordEnd = end
                }
            }
        }

        // Registro 0 = la hora anterior a la actual, y hacia atrás
        var hourlyByHour = [Int?](repeating: nil, count: 24)
        if let hour = hour {
            for (index, offset) in stride(from: headerSize, to: recordEnd, by: activityRecordSize).enumerated() {
                let steps = bucketSum(p, offset)
                if steps > 0 {
                    hourlyByHour[(hour - index - 1 + 24 * 2) % 24] = steps
                }
            }
            if pendingSteps > 0 {
                hourlyByHour[hour] = pendingSteps
            }
        }

        var dailySteps: [Int?] = []
        var dailyDistances: [Int?] = []
        for i in 0..<dailySummaryCount {
            let offset = dailySummaryOffset + i * dailySummarySize
            guard offset + dailySummarySize <= p.count else { break }
            let steps = u32(p, offset)
            let distance = u32(p, offset + 4)
            dailySteps.append(steps == sentinelDaily ? nil : steps)
            dailyDistances.append(distance == sentinelDaily ? nil : distance)
        }

        if p.count < currentStepsOffset + 4 {
            warnings.append("payload truncated (\(p.count) bytes)")
        }

        return StepCounterData(
            timestamp: timestamp,
            todaySteps: todaySteps,
            todayDistanceMeters: u32(p, currentDistanceOffset),
            hourlyByHour: hourlyByHour,
            dailySteps: dailySteps,
            dailyDistancesMeters: dailyDistances,
            warnings: warnings,
            raw: payload
        )
    }

    private static func bucketSum(_ p: [UInt8], _ offset: Int) -> Int {
        (0..<5).reduce(0) { total, i in
            guard let value = u16(p, offset + i * 2), value != sentinelBucket else { return total }
            return total + value
        }
    }

    private static func decodeBCD(_ byte: UInt8) -> Int? {
        let high = Int(byte >> 4), low = Int(byte & 0x0F)
        guard high <= 9, low <= 9 else { return nil }
        return high * 10 + low
    }

    /// u16 little-endian; 0xFFFF = sin dato
    private static func u16(_ p: [UInt8], _ offset: Int) -> Int? {
        guard offset + 2 <= p.count else { return nil }
        let value = Int(p[offset]) | Int(p[offset + 1]) << 8
        return value == 0xFFFF ? nil : value
    }

    /// u32 little-endian
    private static func u32(_ p: [UInt8], _ offset: Int) -> Int? {
        guard offset + 4 <= p.count else { return nil }
        return Int(p[offset]) | Int(p[offset + 1]) << 8 | Int(p[offset + 2]) << 16 | Int(p[offset + 3]) << 24
    }
}

/// Transacción de lifelog. No usa 0x2C/0x2D (ver PROTOCOL.md):
/// 1. `00 11 00 00 00` a 0x23 con respuesta (0x11 = categoría "exercise").
/// 2. 0x23 notifica `00 11 L0 L1 L2`: longitud total (little-endian).
/// 3. Los datos llegan troceados por 0x24 hasta completar la longitud.
/// 4. `04 11 00 00 00` a 0x23 cierra la transacción.
final class StepCounterTransaction {
    static let startCommand = Data([0x00, 0x11, 0x00, 0x00, 0x00])
    static let endCommand = Data([0x04, 0x11, 0x00, 0x00, 0x00])
    private static let fallbackLength = 400
    private static let timeout: TimeInterval = 10.0

    /// Escribe en 0x23 (Data Request) con respuesta; false si no hay conexión
    var writeDataRequest: (Data) -> Bool = { _ in false }
    var log: (String) -> Void = { _ in }

    private(set) var isRunning = false
    private var accumulator = Data()
    private var expectedLength = fallbackLength
    private var completion: ((Result<StepCounterData, WatchRequestError>) -> Void)?
    private var generation = 0

    func start(completion: @escaping (Result<StepCounterData, WatchRequestError>) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        accumulator = Data()
        expectedLength = Self.fallbackLength
        self.completion = completion
        generation += 1
        let current = generation

        guard writeDataRequest(Self.startCommand) else {
            finish(.failure(.notConnected))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            guard let self = self, self.isRunning, self.generation == current else { return }
            self.log("❌ [STEPS] Timeout: \(self.accumulator.count)/\(self.expectedLength) bytes")
            self.finish(.failure(.timeout))
        }
    }

    /// Notificación de 0x23: anuncio de longitud
    func handleDataRequest(_ data: Data) {
        let b = [UInt8](data)
        guard isRunning, b.count >= 5, b[1] == 0x11, b[0] == 0x00 else { return }
        expectedLength = Int(b[2]) | Int(b[3]) << 8 | Int(b[4]) << 16
        log("👣 [STEPS] Expected length \(expectedLength) bytes")
    }

    /// Trozo de datos (0x24). Devuelve true si la transacción lo ha consumido.
    @discardableResult
    func handleChunk(_ data: Data) -> Bool {
        guard isRunning else { return false }
        accumulator.append(data)
        log("👣 [STEPS] Chunk \(data.count) bytes (\(accumulator.count)/\(expectedLength))")
        guard accumulator.count >= expectedLength else { return true }

        _ = writeDataRequest(Self.endCommand)
        if let parsed = StepCounterParser.parse(accumulator) {
            finish(.success(parsed))
        } else {
            log("❌ [STEPS] Could not parse \(accumulator.hexString)")
            finish(.failure(.rejected(accumulator)))
        }
        return true
    }

    func cancel() {
        guard isRunning else { return }
        finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<StepCounterData, WatchRequestError>) {
        isRunning = false
        generation += 1
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
}
