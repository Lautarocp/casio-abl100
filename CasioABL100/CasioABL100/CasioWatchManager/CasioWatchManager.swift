import Foundation
import CoreBluetooth
import os.log

final class CasioWatchManager: NSObject, ObservableObject {
    /// Una sola instancia: iOS solo restaura un CBCentralManager por restore identifier.
    static let shared = CasioWatchManager()

    private let logger = OSLog(subsystem: "com.casio.abl100", category: "BLE")

    // MARK: - Constants
    private let serviceUUID = CBUUID(string: "26eb000d-b012-49a8-b1f8-394fb2032b0f")

    // MARK: - Published Properties
    @Published var isConnected = false
    @Published var watchName = "CASIO ABL-100WE"
    @Published var lastButtonPress: ButtonPress?
    @Published var connectionStatus = "Desconectado"
    @Published private(set) var timeSyncRunning = false

    @Published private(set) var stepData: StepCounterData?
    @Published private(set) var stepsRunning = false
    /// Histórico guardado en el iPhone, del día más reciente al más antiguo (ver StepHistory)
    @Published private(set) var stepDays: [StepDay] = []
    private let stepHistory = StepHistory()
    @Published private(set) var alarms: [WatchAlarm] = []
    @Published private(set) var alarmsBusy = false
    /// Cuándo sonará la alarma del temporizador de la app (alarma 5); nil = no hay ninguno en marcha
    @Published private(set) var timerAlarmDue: Date? = UserDefaults.standard.object(forKey: "hoursync.timerAlarmDue") as? Date {
        didSet { UserDefaults.standard.set(timerAlarmDue, forKey: "hoursync.timerAlarmDue") }
    }
    @Published private(set) var settings: WatchSettings?
    @Published private(set) var timeAdjustment: TimeAdjustment?
    @Published private(set) var settingsBusy = false
    @Published private(set) var timer: WatchTimer?
    @Published private(set) var timerBusy = false

    /// Pulsación larga del inferior derecho: buscar teléfono (por defecto) o reproducir una canción
    @Published var longPressAction: LongPressAction = CasioWatchManager.savedLongPressAction {
        didSet { UserDefaults.standard.set(longPressAction.rawValue, forKey: Self.longPressActionKey) }
    }
    /// Zona horaria que se manda al reloj ("World time"); nil = la del iPhone
    @Published var watchTimeZoneID: String? = UserDefaults.standard.string(forKey: "casio.abl100.timeZone") {
        didSet {
            UserDefaults.standard.set(watchTimeZoneID, forKey: "casio.abl100.timeZone")
            logEvent("🌍 [WORLD_TIME] \(watchTimeZone.identifier)")
            setTime()   // si no está conectado no hace nada; se aplica en la siguiente conexión
        }
    }
    var watchTimeZone: TimeZone {
        watchTimeZoneID.flatMap { TimeZone(identifier: $0) } ?? .current
    }
    /// Enlace de Apple Music para `.playSong`
    @Published var songLink: String = UserDefaults.standard.string(forKey: "casio.abl100.songLink") ?? "" {
        didSet { UserDefaults.standard.set(songLink, forKey: "casio.abl100.songLink") }
    }

    /// Peticiones GET/SET al reloj, de una en una
    let requests = WatchRequestQueue()
    /// Lifelog (pasos): transacción aparte por 0x23/0x24
    private let steps = StepCounterTransaction()

    // MARK: - Private Properties
    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristics_map = [CBUUID: CBCharacteristic]()
    private let startTime = Date()
    /// El reloj repite 0x10 varias veces por conexión: solo la primera cuenta como pulsación
    private var buttonHandledThisConnection = false

    /// Nombre que anuncia el reloj: "CASIO ABL-100WE"
    private static let watchNamePrefix = "CASIO ABL-100"
    private static let restoreIdentifier = "com.casio.abl100.central"
    private static let savedPeripheralKey = "casio.abl100.peripheralIdentifier"
    /// true mientras el usuario quiere que la app espere al reloj (se pone a false con Disconnect)
    private var autoReconnect: Bool {
        get { UserDefaults.standard.object(forKey: "casio.abl100.autoReconnect") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "casio.abl100.autoReconnect") }
    }
    private var savedPeripheralIdentifier: UUID? {
        get { UserDefaults.standard.string(forKey: Self.savedPeripheralKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.savedPeripheralKey) }
    }

    private func logEvent(_ message: String) {
        let elapsed = String(format: "%.3f", Date().timeIntervalSince(startTime))
        os_log("[%@s] %@", log: logger, type: .info, elapsed, message)
        #if DEBUG
        // Prefijo para filtrar en la consola de Xcode y separarlo de la app oficial de Casio
        print("🔵 [NUESTRA_APP \(elapsed)s] \(message)")
        #endif
    }

    private override init() {
        super.init()
        stepDays = stepHistory.sortedDays
        requests.writeGet = { [unowned self] data in self.writeGet(data) }
        requests.writeSet = { [unowned self] data in self.writeSet(data) }
        steps.writeDataRequest = { [unowned self] data in self.writeDataRequest(data) }
        steps.log = { [unowned self] message in self.logEvent(message) }
        #if !targetEnvironment(simulator)
        // Se crea de forma síncrona: si iOS relanza la app en background por un evento BLE,
        // el manager con el mismo restore identifier tiene que existir antes de que termine el launch.
        centralManager = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier
        ])
        #else
        connectionStatus = "Simulador (sin BLE)"
        #endif
    }

    // MARK: - Public Methods

    /// Botón "Connect Watch": activa el modo espera y lo deja armado.
    func startScanning() {
        autoReconnect = true
        armConnection()
    }

    /// Deja la app esperando al reloj.
    /// - Reloj ya conocido: connect() pendiente. No caduca y funciona en background:
    ///   iOS conecta en cuanto el reloj empieza a anunciarse (pulsación de botón).
    /// - Primera vez: scan en foreground para descubrirlo y guardar su identifier.
    private func armConnection() {
        guard autoReconnect, let cm = centralManager else { return }
        guard cm.state == .poweredOn else {
            connectionStatus = "Esperando Bluetooth… (estado \(cm.state.rawValue))"
            return
        }

        if peripheral == nil, let id = savedPeripheralIdentifier {
            peripheral = cm.retrievePeripherals(withIdentifiers: [id]).first
            peripheral?.delegate = self
        }

        if let peripheral = peripheral {
            switch peripheral.state {
            case .connected:
                // Conexión restaurada por iOS: falta descubrir servicios e inicializar
                if !isConnected {
                    isConnected = true
                    connectionStatus = "Conectado, preparando…"
                    peripheral.discoverServices([serviceUUID])
                }
                return
            case .connecting:
                return
            default:
                logEvent("⏳ [ARMED] Pending connect to known watch \(peripheral.identifier)")
                connectionStatus = "Esperando un botón del reloj…"
                cm.connect(peripheral, options: nil)
            }
            return
        }

        // La app todavía no conoce el reloj. El ABL-100WE no anuncia el service UUID,
        // así que hay que escanear sin filtro (solo funciona en foreground).
        connectionStatus = "Buscando… (pulsa un botón del reloj)"
        logEvent("🔍 [SCAN] First-time scan for watch")
        cm.scanForPeripherals(withServices: nil, options: nil)
    }

    func stopScanning() {
        centralManager?.stopScan()
    }

    /// Desconexión pedida por el usuario: cancela también el connect pendiente y deja de esperar.
    func disconnect() {
        autoReconnect = false
        centralManager?.stopScan()
        if let peripheral = peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        resetConnectionState()
        connectionStatus = "Desconectado"
    }

    /// Olvida el reloj guardado (p. ej. para emparejar otro).
    func forgetWatch() {
        disconnect()
        peripheral = nil
        savedPeripheralIdentifier = nil
    }

    private func resetConnectionState() {
        FindPhone.shared.stop()
        isConnected = false
        buttonHandledThisConnection = false
        requests.cancelAll()
        steps.cancel()
        timeSyncRunning = false
        stepsRunning = false
        characteristics_map.removeAll()
    }

    // MARK: - Private Methods
    private func parseButtonPress(_ data: Data) -> ButtonPress? {
        guard data.count >= 9 else { return nil }
        let bytes = [UInt8](data)

        // [1-6] MAC del reloj (invertida), [8] código del botón; el resto no cambia
        let buttonCode = bytes[8]
        os_log("BLE_FEATURES button code 0x%02x", log: logger, type: .debug, buttonCode)

        let buttonPress: ButtonPress?
        switch buttonCode {
        case 0x00:
            buttonPress = ButtonPress(button: .resetButton, timestamp: Date())
        case 0x01:
            buttonPress = ButtonPress(button: .lowerLeft, timestamp: Date())
        case 0x02:
            // Verificado en reloj real: pulsación larga (2+ s) del botón inferior derecho
            buttonPress = ButtonPress(button: .lowerRightLong, timestamp: Date())
        case 0x03:
            buttonPress = ButtonPress(button: .noButton, timestamp: Date())
        case 0x04:
            buttonPress = ButtonPress(button: .lowerRight, timestamp: Date())
        case 0x0A, 0x0B, 0x0D, 0x0E:
            buttonPress = ButtonPress(button: .alwaysConnected, timestamp: Date())
        default:
            buttonPress = nil
        }

        return buttonPress
    }

    /// Respuesta de handshake. Se envía ante CADA 0x10, sea cual sea el botón:
    /// el reloj repite 0x10 y hay que contestar cada vez. La hora (0x09) va después, en setTime().
    private func respondToHandshake() {
        logEvent("✅ [HANDSHAKE_INIT] 0x10 received - responding to handshake")
        sendHeaderResponseToWatch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.sendSettingForBLE()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.sendAppInformation()
        }
    }

    private func sendHeaderResponseToWatch() {
        guard isConnected, let peripheral = peripheral else { return }

        logEvent("🔄 [HANDSHAKE_START] Sending header response to watch")

        guard let char = characteristics_map[CasioCharacteristic.readRequest.uuid] else {
            logEvent("❌ Read Request characteristic not found")
            return
        }

        var header = Data()
        header.append(0x19)
        header.append(0xF8)
        header.append(0xFA)
        header.append(0xF1)

        let hexStr = header.map { String(format: "%02x", $0) }.joined(separator: " ")
        logEvent("📤 [STEP_1/3] Header sent: \(hexStr) to 0x2C")

        peripheral.writeValue(header, for: char, type: .withoutResponse)
    }

    private func sendSettingForBLE() {
        guard isConnected, let peripheral = peripheral else { return }

        logEvent("⚙️ [STEP_2/3] Sending SETTING_FOR_BLE (0x11) to 0x2C")

        guard let char = characteristics_map[CasioCharacteristic.readRequest.uuid] else {
            logEvent("❌ [STEP_2_FAIL] Read Request characteristic not found")
            return
        }

        var command = Data()
        command.append(0x11)

        let hexStr = command.map { String(format: "%02x", $0) }.joined(separator: " ")
        logEvent("📤 [STEP_2] Command 0x11 sent: \(hexStr)")

        peripheral.writeValue(command, for: char, type: .withoutResponse)
    }

    private func sendAppInformation() {
        guard isConnected, let peripheral = peripheral else { return }

        logEvent("📱 [STEP_3/3] Sending APP_INFORMATION (0x22) to 0x2C")

        guard let char = characteristics_map[CasioCharacteristic.readRequest.uuid] else {
            logEvent("❌ [STEP_3_FAIL] Read Request characteristic not found")
            return
        }

        var command = Data()
        command.append(0x22)

        let hexStr = command.map { String(format: "%02x", $0) }.joined(separator: " ")
        logEvent("📤 [STEP_3] Command 0x22 sent: \(hexStr)")

        peripheral.writeValue(command, for: char, type: .withoutResponse)
    }

    private func parseSettingForBLE(_ data: Data) {
        guard data.count >= 2 else { return }
        let bytes = [UInt8](data)

        let hexStr = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        os_log("✅ SETTING_FOR_BLE response (%d bytes): %@", log: logger, type: .info, data.count, hexStr)
        os_log("✅ SETTING_FOR_BLE received", log: logger, type: .info)

        // Response format:
        // [0] = 0x11 (echo command)
        // [1-14] = BLE settings configuration data
        // Connection should be complete at this point
    }

    // MARK: - Time sync
    // Réplica de GShockAPI TimeIO.set() para el ABL-100 (dstCount = 1, worldCitiesCount = 2,
    // sin world cities ni home time): leer 1D00, 1E00 y 1E01 y reescribirlos tal cual
    // (conserva la zona que tenga el reloj) y después enviar 0x09 con la hora.

    /// Botón "Sincronizar hora" y cambio de ciudad: solo la hora.
    func setTime() {
        syncTime(retriesLeft: 1) { _ in }
    }

    /// Al conectar: la hora y después todo lo demás. Si la hora falla (p. ej. otra app conectada
    /// al reloj a la vez), se leen igualmente pasos, alarmas, ajustes y temporizador.
    private func syncOnConnection() {
        syncTime(retriesLeft: 1) { _ in
            // Una cosa detrás de otra: el lifelog usa otras características y no pasa por la cola
            self.readSteps { self.readAlarms { self.readSettings { self.readTimer() } } }
        }
    }

    private func syncTime(retriesLeft: Int, completion: @escaping (Bool) -> Void) {
        guard isConnected, !timeSyncRunning else {
            completion(false)
            return
        }
        timeSyncRunning = true
        logEvent("⏰ [TIME_SYNC] Start")

        echoRecords([[0x1d, 0x00], [0x1e, 0x00], [0x1e, 0x01]]) { error in
            if let error = error {
                self.timeSyncFailed(error, retriesLeft: retriesLeft, completion: completion)
                return
            }
            let packet = self.currentTimePacket()
            self.logEvent("⏰ [TIME_SYNC] Set time \(packet.hexString)")
            self.requests.set(packet) { result in
                if case .failure(let error) = result {
                    self.timeSyncFailed(error, retriesLeft: retriesLeft, completion: completion)
                    return
                }
                self.finishTimeSync(nil)
                self.connectionStatus = "Hora sincronizada"
                completion(true)
            }
        }
    }

    /// `ff 81 <cmd>` sale cuando se solapan peticiones, normalmente de otra app conectada al reloj
    /// a la vez: se reintenta una vez.
    private func timeSyncFailed(_ error: WatchRequestError, retriesLeft: Int, completion: @escaping (Bool) -> Void) {
        finishTimeSync(error)
        if case .rejected = error, retriesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.syncTime(retriesLeft: retriesLeft - 1, completion: completion)
            }
        } else {
            completion(false)
        }
    }

    private func finishTimeSync(_ error: WatchRequestError?) {
        timeSyncRunning = false
        if let error = error {
            logEvent("❌ [TIME_SYNC] \(error)")
        } else {
            logEvent("⏰ [TIME_SYNC] Done")
        }
    }

    /// GET de cada registro y SET del mismo paquete, en orden.
    private func echoRecords(_ keys: [[UInt8]], completion: @escaping (WatchRequestError?) -> Void) {
        guard let key = keys.first else {
            completion(nil)
            return
        }
        requests.get(key) { result in
            switch result {
            case .failure(let error):
                completion(error)
            case .success(let packet):
                self.logEvent("⏰ [TIME_SYNC] Echo \(packet.hexString)")
                self.requests.set(packet) { result in
                    if case .failure(let error) = result {
                        completion(error)
                        return
                    }
                    self.echoRecords(Array(keys.dropFirst()), completion: completion)
                }
            }
        }
    }

    private func currentTimePacket() -> Data {
        // Hora de la zona elegida en "World time" (por defecto, la del iPhone). Calendario gregoriano
        // explícito: con Calendar.current, un iPhone con otro calendario mandaría otro año
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = watchTimeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond, .weekday], from: Date())
        let year = c.year ?? 2000
        let weekday = c.weekday ?? 1

        var command = Data([0x09])
        command.append(UInt8(year & 0xFF))            // año little-endian (TimeIOFunctional.prepareCurrentTime)
        command.append(UInt8((year >> 8) & 0xFF))
        command.append(UInt8(c.month ?? 1))
        command.append(UInt8(c.day ?? 1))
        command.append(UInt8(c.hour ?? 0))
        command.append(UInt8(c.minute ?? 0))
        command.append(UInt8(c.second ?? 0))
        command.append(UInt8(weekday == 1 ? 7 : weekday - 1))  // ISO: lunes = 1 ... domingo = 7
        command.append(UInt8(((c.nanosecond ?? 0) * 256) / 1_000_000_000))
        command.append(1)                             // reserved
        return command
    }

    // MARK: - Steps (lifelog)

    func readSteps(then next: (() -> Void)? = nil) {
        guard isConnected, !stepsRunning else {
            next?()
            return
        }
        stepsRunning = true
        logEvent("👣 [STEPS] Start")
        steps.start { result in
            self.stepsRunning = false
            defer { next?() }
            switch result {
            case .success(let data):
                self.stepData = data
                self.stepHistory.merge(data)
                self.stepDays = self.stepHistory.sortedDays
                let hourly = data.hourlyByHour.enumerated()
                    .compactMap { hour, count in count.map { "\(hour)h=\($0)" } }
                    .joined(separator: " ")
                let watchTime = data.timestamp.map { "\($0)" } ?? "-"
                self.logEvent("👣 [STEPS] Today \(Self.format(data.todaySteps)) steps, \(Self.format(data.todayDistanceMeters)) m, watch time \(watchTime)")
                self.logEvent("👣 [STEPS] Hourly: \(hourly)")
                self.logEvent("👣 [STEPS] Daily steps: \(data.dailySteps.map(Self.format))")
                self.logEvent("👣 [STEPS] Daily distance: \(data.dailyDistancesMeters.map(Self.format))")
                if !data.warnings.isEmpty {
                    self.logEvent("⚠️ [STEPS] \(data.warnings.joined(separator: "; "))")
                }
                #if DEBUG
                self.logEvent("👣 [STEPS] Raw \(data.raw.count) bytes: \(data.raw.hexString)")
                #endif
            case .failure(let error):
                self.logEvent("❌ [STEPS] \(error)")
            }
        }
    }

    // MARK: - Alarms

    func readAlarms(then next: (() -> Void)? = nil) {
        guard isConnected, !alarmsBusy else {
            next?()
            return
        }
        alarmsBusy = true
        logEvent("⏰ [ALARMS] Read")
        fetchAlarms {
            self.alarmsBusy = false
            self.disableFinishedTimerAlarm()
            next?()
        }
    }

    // MARK: - Timer alarm (temporizador de la app → alarma 5)

    /// Alarma del reloj que usa el temporizador de la app: la 5 (índice 4)
    static let timerAlarmIndex = 4

    /// "Iniciar" del temporizador: pone la alarma 5 a ahora + la duración y la activa. El reloj suena
    /// solo, sin depender del iPhone. Las alarmas van por minutos: se redondea hacia arriba para que
    /// nunca suene antes de tiempo.
    func startTimerAlarm(hours: Int, minutes: Int) {
        let index = Self.timerAlarmIndex
        let duration = TimeInterval(hours * 3600 + minutes * 60)
        guard isConnected, !alarmsBusy, alarms.count > index, duration > 0 else { return }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = watchTimeZone      // la alarma se compara con la hora que muestra el reloj
        let exact = Date().addingTimeInterval(duration)
        let minuteStart = calendar.dateInterval(of: .minute, for: exact)?.start ?? exact
        let due = minuteStart < exact ? minuteStart.addingTimeInterval(60) : minuteStart
        let c = calendar.dateComponents([.hour, .minute], from: due)

        var updated = alarms
        updated[index].hour = c.hour ?? 0
        updated[index].minute = c.minute ?? 0
        updated[index].enabled = true
        logEvent(String(format: "⏲️ [TIMER_ALARM] %ld h %ld min → alarma 5 a las %02ld:%02ld",
                        hours, minutes, c.hour ?? 0, c.minute ?? 0))
        timerAlarmDue = due
        saveAlarms(updated)
    }

    /// Cancela el temporizador en marcha: apaga la alarma 5.
    func cancelTimerAlarm() {
        let index = Self.timerAlarmIndex
        guard isConnected, !alarmsBusy, alarms.count > index else { return }
        var updated = alarms
        updated[index].enabled = false
        logEvent("⏲️ [TIMER_ALARM] Cancelled")
        timerAlarmDue = nil
        saveAlarms(updated)
    }

    /// Las alarmas del reloj suenan cada día: cuando la del temporizador ya ha sonado, se apaga en la
    /// siguiente conexión para que no vuelva a sonar mañana. Si el usuario la cambió a mano, no se toca.
    private func disableFinishedTimerAlarm() {
        let index = Self.timerAlarmIndex
        guard let due = timerAlarmDue, Date() > due.addingTimeInterval(60), alarms.count > index else { return }
        timerAlarmDue = nil

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = watchTimeZone
        let c = calendar.dateComponents([.hour, .minute], from: due)
        let alarm = alarms[index]
        guard alarm.enabled, alarm.hour == c.hour, alarm.minute == c.minute else { return }

        var updated = alarms
        updated[index].enabled = false
        logEvent("⏲️ [TIMER_ALARM] Already rang: disabling alarm 5")
        saveAlarms(updated)
    }

    /// Escribe las alarmas y las vuelve a leer para comprobar que el reloj las ha guardado.
    func saveAlarms(_ newAlarms: [WatchAlarm]) {
        guard isConnected, !alarmsBusy else { return }
        let packets = AlarmCodec.encode(newAlarms)
        guard !packets.isEmpty else { return }
        alarmsBusy = true
        logEvent("⏰ [ALARMS] Save \(packets.map { $0.hexString })")

        sendSets(packets) { error in
            if let error = error {
                self.logEvent("❌ [ALARMS] Save failed: \(error)")
                self.alarmsBusy = false
                return
            }
            self.fetchAlarms { self.alarmsBusy = false }
        }
    }

    private func fetchAlarms(completion: @escaping () -> Void) {
        requests.get([AlarmCodec.firstCode]) { first in
            self.requests.get([AlarmCodec.restCode]) { rest in
                defer { completion() }
                switch (first, rest) {
                case (.success(let a), .success(let b)):
                    self.logEvent("⏰ [ALARMS] Raw \(a.hexString) | \(b.hexString)")
                    guard let parsed = AlarmCodec.parse(first: a, rest: b) else {
                        self.logEvent("❌ [ALARMS] Unexpected format")
                        return
                    }
                    self.alarms = parsed
                    for alarm in parsed {
                        self.logEvent(String(format: "⏰ [ALARMS] #%ld %02ld:%02ld %@%@", alarm.id + 1, alarm.hour, alarm.minute,
                                             alarm.enabled ? "ON" : "off", alarm.hourlyChime ? " +chime" : ""))
                    }
                case (.failure(let error), _), (_, .failure(let error)):
                    self.logEvent("❌ [ALARMS] Read failed: \(error)")
                }
            }
        }
    }

    // MARK: - Settings (0x13) + time adjustment (0x11)

    func readSettings(then next: (() -> Void)? = nil) {
        guard isConnected, !settingsBusy else {
            next?()
            return
        }
        settingsBusy = true
        logEvent("⚙️ [SETTINGS] Read")
        fetchSettings {
            self.settingsBusy = false
            next?()
        }
    }

    /// Escribe ajustes y ajuste automático de hora, y los vuelve a leer para comprobarlos.
    func saveSettings(_ newSettings: WatchSettings, _ newAdjustment: TimeAdjustment) {
        guard isConnected, !settingsBusy else { return }
        settingsBusy = true
        var packets: [Data] = []
        if newSettings != settings { packets.append(SettingsCodec.encode(newSettings)) }
        if newAdjustment != timeAdjustment { packets.append(SettingsCodec.encode(newAdjustment)) }
        logEvent("⚙️ [SETTINGS] Save \(packets.map { $0.hexString })")
        sendSets(packets) { error in
            if let error = error {
                self.logEvent("❌ [SETTINGS] Save failed: \(error)")
                self.settingsBusy = false
                return
            }
            self.fetchSettings { self.settingsBusy = false }
        }
    }

    private func fetchSettings(completion: @escaping () -> Void) {
        requests.get([SettingsCodec.settingsCode]) { basic in
            self.requests.get([SettingsCodec.timeAdjustmentCode]) { adjustment in
                defer { completion() }
                switch basic {
                case .success(let data):
                    self.logEvent("⚙️ [SETTINGS] Raw \(data.hexString)")
                    if let parsed = SettingsCodec.parseSettings(data) {
                        self.settings = parsed
                        let hourFormat = parsed.is24Hour ? "24h" : "12h"
                        let tone = parsed.buttonTone ? "on" : "off"
                        let saving = parsed.powerSaving ? "on" : "off"
                        let light = parsed.longLight ? "long" : "short"
                        self.logEvent("⚙️ [SETTINGS] \(hourFormat), button tone \(tone), power saving \(saving), light \(light)")
                    } else {
                        self.logEvent("❌ [SETTINGS] Unexpected format")
                    }
                case .failure(let error):
                    self.logEvent("❌ [SETTINGS] Read failed: \(error)")
                }
                switch adjustment {
                case .success(let data):
                    self.logEvent("⚙️ [TIME_ADJ] Raw \(data.hexString)")
                    if let parsed = SettingsCodec.parseTimeAdjustment(data) {
                        self.timeAdjustment = parsed
                        self.logEvent("⚙️ [TIME_ADJ] \(parsed.enabled ? "on" : "off"), minute \(parsed.minute)")
                    } else {
                        self.logEvent("❌ [TIME_ADJ] Unexpected format")
                    }
                case .failure(let error):
                    self.logEvent("❌ [TIME_ADJ] Read failed: \(error)")
                }
            }
        }
    }

    // MARK: - Long press action

    private static let longPressActionKey = "casio.abl100.longPressAction"
    private static var savedLongPressAction: LongPressAction {
        UserDefaults.standard.string(forKey: longPressActionKey).flatMap { LongPressAction(rawValue: $0) } ?? .findPhone
    }

    /// También lo usa el botón "Test" de la app.
    func runLongPressAction() {
        switch longPressAction {
        case .findPhone:
            // Normalmente ya llegó 0a 02 antes; ring() vuelve a empezar, así que no suena el doble
            FindPhone.shared.ring()
        case .playSong:
            SongPlayer.play(link: songLink) { [weak self] message in self?.logEvent(message) }
        }
    }

    // MARK: - Timer (0x18)

    func readTimer() {
        guard isConnected, !timerBusy else { return }
        timerBusy = true
        fetchTimer { self.timerBusy = false }
    }

    func saveTimer(_ newTimer: WatchTimer) {
        guard isConnected, !timerBusy else { return }
        timerBusy = true
        let packet = TimerCodec.encode(newTimer)
        logEvent("⏲️ [TIMER] Save \(packet.hexString)")
        requests.set(packet) { result in
            if case .failure(let error) = result {
                self.logEvent("❌ [TIMER] Save failed: \(error)")
                self.timerBusy = false
                return
            }
            self.fetchTimer { self.timerBusy = false }
        }
    }

    private func fetchTimer(completion: @escaping () -> Void) {
        requests.get([TimerCodec.code]) { result in
            defer { completion() }
            switch result {
            case .success(let data):
                guard let parsed = TimerCodec.parse(data) else {
                    self.logEvent("❌ [TIMER] Unexpected format \(data.hexString)")
                    return
                }
                self.timer = parsed
                self.logEvent(String(format: "⏲️ [TIMER] Raw %@ → %02ld:%02ld:%02ld", data.hexString,
                                     parsed.hours, parsed.minutes, parsed.seconds))
            case .failure(let error):
                self.logEvent("❌ [TIMER] Read failed: \(error)")
            }
        }
    }

    /// SET de varios paquetes en orden; para en el primer error.
    private func sendSets(_ packets: [Data], completion: @escaping (WatchRequestError?) -> Void) {
        guard let first = packets.first else {
            completion(nil)
            return
        }
        requests.set(first) { result in
            if case .failure(let error) = result {
                completion(error)
                return
            }
            self.sendSets(Array(packets.dropFirst()), completion: completion)
        }
    }

    private static func format(_ value: Int?) -> String {
        value.map { "\($0)" } ?? "-"
    }

    private func writeDataRequest(_ data: Data) -> Bool {
        guard let peripheral = peripheral,
              let char = characteristics_map[CasioCharacteristic.dataRequest.uuid] else { return false }
        logEvent("📤 [DATA_REQUEST] \(data.hexString)")
        peripheral.writeValue(data, for: char, type: .withResponse)
        return true
    }

    private func writeGet(_ data: Data) -> Bool {
        guard let peripheral = peripheral,
              let char = characteristics_map[CasioCharacteristic.readRequest.uuid] else { return false }
        logEvent("📤 [GET] \(data.hexString)")
        peripheral.writeValue(data, for: char, type: .withoutResponse)
        return true
    }

    private func writeSet(_ data: Data) -> Bool {
        guard let peripheral = peripheral,
              let char = characteristics_map[CasioCharacteristic.allFeatures.uuid] else { return false }
        logEvent("📤 [SET] \(data.hexString)")
        peripheral.writeValue(data, for: char, type: .withResponse)
        return true
    }
}

// MARK: - CBCentralManagerDelegate
extension CasioWatchManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            os_log("Bluetooth powered on", log: logger, type: .info)
            armConnection()
        case .poweredOff:
            connectionStatus = "Bluetooth apagado"
        case .unauthorized:
            connectionStatus = "Sin permiso de Bluetooth"
        case .unsupported:
            connectionStatus = "Este dispositivo no tiene Bluetooth LE"
        default:
            connectionStatus = "Bluetooth no disponible"
        }
    }

    /// iOS relanzó la app en background: recuperar el reloj y seguir donde estaba.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let watch = restored.first else { return }

        logEvent("♻️ [RESTORE] Restored peripheral \(watch.identifier), state: \(watch.state.rawValue)")
        peripheral = watch
        watch.delegate = self
        savedPeripheralIdentifier = watch.identifier

        // Aquí el central aún no está en .poweredOn (usarlo da "API MISUSE"):
        // armConnection() retoma la conexión o la re-arma al llegar a .poweredOn
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        os_log("Discovered: %@ (RSSI: %d)", log: logger, type: .debug,
               name ?? "Unknown", RSSI.intValue)

        // Solo el ABL-100: otros relojes Casio anuncian nombres parecidos pero hablan otro protocolo
        guard name?.hasPrefix(Self.watchNamePrefix) == true, self.peripheral == nil else { return }

        // Parar el scan antes de conectar para no lanzar connect() varias veces
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        connectionStatus = "Conectando…"
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logEvent("🔗 [CONNECTED] \(peripheral.name ?? "Unknown")")
        savedPeripheralIdentifier = peripheral.identifier
        isConnected = true
        connectionStatus = "Conectado, preparando…"
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        os_log("Failed to connect: %@", log: logger, type: .error,
               error?.localizedDescription ?? "Unknown error")
        resetConnectionState()
        connectionStatus = "Error al conectar"
        // Reintentar: vuelve a dejar el connect pendiente
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.armConnection() }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        logEvent("🔌 [DISCONNECTED] \(error?.localizedDescription ?? "no error")")
        resetConnectionState()
        connectionStatus = "Desconectado"
        // El reloj corta al terminar la sesión (o a los ~3 min si no la completamos):
        // volver a esperar la siguiente pulsación
        armConnection()
    }
}

// MARK: - CBPeripheralDelegate
extension CasioWatchManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            os_log("No services discovered", log: logger, type: .error)
            return
        }

        os_log("🔍 Discovered %d services", log: logger, type: .info, services.count)

        for service in services {
            os_log("   Service: %@ UUID: %@", log: logger, type: .info,
                   service.uuid.uuidString, service.uuid.uuidString)

            // Discover ALL characteristics for each service (not just our predefined ones)
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let chars = service.characteristics else { return }
        os_log("Discovered %d characteristics", log: logger, type: .debug, chars.count)

        for char in chars {
            characteristics_map[char.uuid] = char

            // Enable notificaciones para características que las soportan
            if char.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: char)
            }

            // Lee características que tengan read
            if char.properties.contains(.read) {
                peripheral.readValue(for: char)
            }
        }

        // iOS puede devolver también servicios cacheados (p. ej. 0x1804 Tx Power):
        // inicializar solo una vez, con las características del servicio Casio
        guard service.uuid == serviceUUID else { return }

        connectionStatus = "Conectado"

        sendInitializationCommand(peripheral)
    }

    private func sendInitializationCommand(_ peripheral: CBPeripheral) {
        // Step 1: Enable notifications on All Features (0x2D) FIRST
        enableNotifications(peripheral)

        // Step 2: Send initialization header per G-Shock protocol
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.sendInitializationHeader(peripheral)
        }

        // Step 3: Request BLE Features (0x10 command)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.sendBLEFeaturesRequest(peripheral)
        }
    }

    private func sendInitializationHeader(_ peripheral: CBPeripheral) {
        // Use Read Request (0x2C) for header - command channel
        guard let char = characteristics_map[CasioCharacteristic.readRequest.uuid] else {
            os_log("❌ Read Request characteristic not found", log: logger, type: .error)
            return
        }

        // G-Shock protocol: Send initialization header
        var header = Data()
        header.append(0x19)  // Header bytes per protocol
        header.append(0xF8)
        header.append(0xFA)
        header.append(0xF1)

        let hexStr = header.map { String(format: "%02x", $0) }.joined(separator: " ")
        os_log("📤 Sending initialization header to 0x2C: %@", log: logger, type: .info, hexStr)

        peripheral.writeValue(header, for: char, type: .withoutResponse)
    }

    private func enableNotifications(_ peripheral: CBPeripheral) {
        guard let char = characteristics_map[CasioCharacteristic.allFeatures.uuid] else {
            os_log("❌ All Features characteristic not found", log: logger, type: .error)
            return
        }

        peripheral.setNotifyValue(true, for: char)
        os_log("📢 Enabled notifications on All Features (0x2D)", log: logger, type: .info)
    }

    private func sendBLEFeaturesRequest(_ peripheral: CBPeripheral) {
        guard let char = characteristics_map[CasioCharacteristic.readRequest.uuid] else {
            os_log("❌ Read Request characteristic not found", log: logger, type: .error)
            return
        }

        // Send BLE_FEATURES request (0x10)
        var command = Data()
        command.append(0x10)  // BLE_FEATURES request code

        let hexStr = command.map { String(format: "%02x", $0) }.joined(separator: " ")
        os_log("📤 Sending BLE_FEATURES request: %@", log: logger, type: .info, hexStr)

        peripheral.writeValue(command, for: char, type: .withoutResponse)
        os_log("✅ Initialization sequence complete", log: logger, type: .info)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value else { return }

        let charName: String
        switch characteristic.uuid {
        case CasioCharacteristic.readRequest.uuid: charName = "0x2C (Read Request)"
        case CasioCharacteristic.allFeatures.uuid: charName = "0x2D (All Features)"
        case CasioCharacteristic.dataRequest.uuid: charName = "0x0023 (Data Request)"
        case CasioCharacteristic.convoy.uuid: charName = "0x0024 (Convoy)"
        case CasioCharacteristic.getConfiguration.uuid: charName = "0x2F (Get Config)"
        default: charName = characteristic.uuid.uuidString
        }

        let firstByte = data.count > 0 ? String(format: "0x%02x", [UInt8](data)[0]) : "empty"
        logEvent("📥 [RX] Characteristic: \(charName), Size: \(data.count) bytes, First byte: \(firstByte)")
        os_log("Received data from %@: %@", log: logger, type: .debug,
               characteristic.uuid.uuidString, data.hexString)

        // Lifelog: los trozos de 0x24 no llevan código, no pueden pasar por el switch del primer byte
        if characteristic.uuid == CasioCharacteristic.dataRequest.uuid {
            steps.handleDataRequest(data)
            return
        }
        if characteristic.uuid == CasioCharacteristic.convoy.uuid {
            steps.handleChunk(data)
            return
        }

        // Identifica qué característica es por UUID
        if characteristic.uuid == CasioCharacteristic.readRequest.uuid ||
           characteristic.uuid == CasioCharacteristic.allFeatures.uuid {

            // Verifica el primer byte para identificar el tipo de datos
            guard data.count >= 1 else { return }
            let firstByte = [UInt8](data)[0]

            if requests.handleNotification(data) { return }
            // Como gshock_api: durante el lifelog, lo que llega por 0x2D empezando por 0x26
            // (el año en BCD de la cabecera) también es parte del registro
            if steps.isRunning, firstByte == 0x26, steps.handleChunk(data) { return }

            switch firstByte {
            case 0x0a: // FIND_PHONE: 0a 02 = empieza a buscar, 0a 00 = para
                let state = data.count >= 2 ? [UInt8](data)[1] : 0
                if state == 0x02 {
                    logEvent("📳 [FIND_PHONE] Start (\(data.hexString)), action: \(longPressAction.rawValue)")
                    if longPressAction == .findPhone { FindPhone.shared.ring() }
                } else {
                    logEvent("📳 [FIND_PHONE] Stop (\(data.hexString))")
                    FindPhone.shared.stop()
                }

            case 0x10: // BLE_FEATURES (botón presionado)
                respondToHandshake()
                if !buttonHandledThisConnection, let buttonPress = parseButtonPress(data) {
                    buttonHandledThisConnection = true
                    // Igual que la app oficial: sincronizar la hora en cada conexión,
                    // después de la respuesta de handshake (0x11, 0x22)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.syncOnConnection() }
                    lastButtonPress = buttonPress
                    os_log("Button detected: %@", log: logger, type: .info,
                           buttonPress.button.rawValue)

                    if buttonPress.button == .lowerRight {
                        os_log("🔔 LOWER_RIGHT detected", log: logger, type: .info)
                        // TODO: Custom action for LOWER_RIGHT
                    } else if buttonPress.button == .lowerRightLong {
                        logEvent("📳 [LONG_PRESS] \(longPressAction.rawValue)")
                        runLongPressAction()
                    }
                }

            case 0x11: // SETTING_FOR_BLE (response to confirmation)
                parseSettingForBLE(data)

            case 0xff: // ERROR
                logEvent("❌ [WATCH_ERROR] \(data.hexString)")

            default:
                os_log("Unknown data type: 0x%02x", log: logger, type: .debug, firstByte)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if characteristic.uuid == CasioCharacteristic.allFeatures.uuid {
            requests.handleWriteResult(error: error)
        }
        if let error = error {
            logEvent("❌ [WRITE_FAILED] \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        } else {
            os_log("Write successful", log: logger, type: .debug)
        }
    }
}

// MARK: - Models
struct ButtonPress: Identifiable {
    let id = UUID()
    let button: WatchButton
    let timestamp: Date
}

enum WatchButton: String {
    case lowerLeft = "Lower Left"
    case lowerRight = "Lower Right"
    case lowerRightLong = "Lower Right (long)"
    case resetButton = "Reset"
    case noButton = "No Button"
    case alwaysConnected = "Always Connected"
}

enum CasioCharacteristic {
    case readRequest
    case allFeatures
    case dataRequest
    /// 0x24: por aquí llegan los trozos del lifelog (en GShockAPI "convoy")
    case convoy
    case getConfiguration

    var uuid: CBUUID {
        switch self {
        case .readRequest:
            return CBUUID(string: "26eb002c-b012-49a8-b1f8-394fb2032b0f")
        case .allFeatures:
            return CBUUID(string: "26eb002d-b012-49a8-b1f8-394fb2032b0f")
        case .dataRequest:
            return CBUUID(string: "26eb0023-b012-49a8-b1f8-394fb2032b0f")
        case .convoy:
            return CBUUID(string: "26eb0024-b012-49a8-b1f8-394fb2032b0f")
        case .getConfiguration:
            return CBUUID(string: "26eb002f-b012-49a8-b1f8-394fb2032b0f")
        }
    }
}

// MARK: - Helpers
extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
