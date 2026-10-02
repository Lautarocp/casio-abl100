import Foundation

enum WatchRequestError: Error, CustomStringConvertible {
    case notConnected
    case timeout
    /// El reloj contestó `FF <código de error> <comando>`
    case rejected(Data)
    case writeFailed(String)
    /// Desconexión con la petición pendiente
    case cancelled

    var description: String {
        switch self {
        case .notConnected: return "not connected"
        case .timeout: return "timeout"
        case .rejected(let data): return "rejected by watch (\(data.hexString))"
        case .writeFailed(let reason): return "write failed: \(reason)"
        case .cancelled: return "cancelled"
        }
    }
}

/// Cola de peticiones al reloj (ver PROTOCOL.md):
/// - GET: el código (p. ej. `1d 00`) se escribe en 0x2C y la respuesta es la notificación de 0x2D
///   que empieza por esos mismos bytes.
/// - SET: el paquete completo se escribe en 0x2D con respuesta; termina con `didWriteValueFor`.
///
/// Solo hay una petición en vuelo cada vez: el reloj responde `ff 81 <cmd>` si se solapan.
/// Todo corre en el hilo principal, igual que el CBCentralManager (cola `.main`).
final class WatchRequestQueue {
    private enum Operation {
        case get([UInt8])
        case set(Data)
    }

    private struct Request {
        let operation: Operation
        let completion: (Result<Data, WatchRequestError>) -> Void
    }

    /// Escriben en el reloj; devuelven false si no hay conexión o falta la característica
    var writeGet: (Data) -> Bool = { _ in false }
    var writeSet: (Data) -> Bool = { _ in false }

    private let timeout: TimeInterval = 3.0
    private var pending: [Request] = []
    private var inFlight: Request?
    /// Identifica la petición en vuelo para que el timeout de una anterior no la cancele
    private var generation = 0

    func get(_ key: [UInt8], completion: @escaping (Result<Data, WatchRequestError>) -> Void) {
        enqueue(Request(operation: .get(key), completion: completion))
    }

    func set(_ data: Data, completion: @escaping (Result<Void, WatchRequestError>) -> Void = { _ in }) {
        enqueue(Request(operation: .set(data)) { result in completion(result.map { _ in () }) })
    }

    /// Notificación de 0x2D. Devuelve true si era la respuesta de la petición en vuelo.
    func handleNotification(_ data: Data) -> Bool {
        guard let request = inFlight else { return false }
        let bytes = [UInt8](data)
        let command: UInt8

        switch request.operation {
        case .get(let key):
            if bytes.starts(with: key) {
                finish(.success(data))
                return true
            }
            command = key[0]
        case .set(let packet):
            command = packet.first ?? 0
        }

        if bytes.count >= 3, bytes[0] == 0xff, bytes[2] == command {
            finish(.failure(.rejected(data)))
            return true
        }
        return false
    }

    /// `didWriteValueFor` de 0x2D: confirma (o hace fallar) el SET en vuelo.
    func handleWriteResult(error: Error?) {
        guard let request = inFlight, case .set = request.operation else { return }
        if let error = error {
            finish(.failure(.writeFailed(error.localizedDescription)))
        } else {
            finish(.success(Data()))
        }
    }

    /// Al desconectar: falla todo lo pendiente con `.cancelled`.
    func cancelAll() {
        generation += 1
        let requests = (inFlight.map { [$0] } ?? []) + pending
        inFlight = nil
        pending = []
        requests.forEach { $0.completion(.failure(.cancelled)) }
    }

    private func enqueue(_ request: Request) {
        pending.append(request)
        startNext()
    }

    private func startNext() {
        guard inFlight == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        inFlight = request
        generation += 1
        let current = generation

        let written: Bool
        switch request.operation {
        case .get(let key): written = writeGet(Data(key))
        case .set(let packet): written = writeSet(packet)
        }
        guard written else {
            finish(.failure(.notConnected))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self, self.generation == current, self.inFlight != nil else { return }
            self.finish(.failure(.timeout))
        }
    }

    private func finish(_ result: Result<Data, WatchRequestError>) {
        guard let request = inFlight else { return }
        inFlight = nil
        request.completion(result)
        startNext()
    }
}
