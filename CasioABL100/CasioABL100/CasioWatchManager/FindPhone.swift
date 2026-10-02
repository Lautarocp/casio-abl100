import Foundation
import UserNotifications

/// Buscar teléfono: el reloj solo avisa (`0a 02` al empezar, `0a 00` al parar; ver PROTOCOL.md).
/// Suena con notificaciones locales porque la app suele estar en background (la despierta el BLE):
/// una cada pocos segundos hasta que el reloj para la búsqueda, con un máximo de ~30 s.
final class FindPhone: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FindPhone()

    private let repetitions = 10
    private let interval: TimeInterval = 3

    /// Se llama al arrancar: pide permiso y hace que las notificaciones suenen también en foreground.
    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Empieza a sonar. Si ya estaba sonando, vuelve a empezar (el reloj puede avisar dos veces).
    func ring() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        for i in 0..<repetitions {
            let content = UNMutableNotificationContent()
            content.title = "Buscar iPhone"
            content.body = "Tu reloj está buscando este iPhone"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5 + Double(i) * interval, repeats: false)
            center.add(UNNotificationRequest(identifier: identifiers[i], content: content, trigger: trigger))
        }
    }

    /// Para de sonar: el reloj terminó la búsqueda o se desconectó.
    func stop() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private var identifiers: [String] {
        (0..<repetitions).map { "findPhone.\($0)" }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
