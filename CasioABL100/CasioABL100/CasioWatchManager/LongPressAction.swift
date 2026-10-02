import Foundation
import MediaPlayer
import UIKit

/// Qué hace la pulsación larga del botón inferior derecho (código 0x02).
enum LongPressAction: String, CaseIterable, Identifiable {
    case findPhone
    case playSong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .findPhone: return "Buscar iPhone"
        case .playSong: return "Canción"
        }
    }
}

/// Reproduce una canción de Apple Music a partir de un enlace compartido.
///
/// La app suele estar en background cuando llega la pulsación, y iOS no deja abrir otra app
/// desde background: la canción se manda a la app Música con `systemMusicPlayer`, que suena
/// sin mostrarla. Si la app está en foreground, además se abre el enlace en Música.
enum SongPlayer {
    /// ID de catálogo de la canción. Admite los enlaces de "Compartir → Copiar enlace":
    /// - `https://music.apple.com/es/album/nombre/123?i=456` → 456 (canción dentro de un álbum)
    /// - `https://music.apple.com/es/song/nombre/456` → 456
    static func storeID(from link: String) -> String? {
        guard let components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.host?.hasSuffix("music.apple.com") == true else { return nil }
        if let i = components.queryItems?.first(where: { $0.name == "i" })?.value, isNumeric(i) {
            return i
        }
        let path = components.path.split(separator: "/")
        if path.contains("song"), let last = path.last, isNumeric(String(last)) {
            return String(last)
        }
        return nil
    }

    /// Pide permiso para controlar Música. Llamarlo en foreground (al elegir "Play song" o con "Test").
    static func requestAuthorization() {
        if MPMediaLibrary.authorizationStatus() == .notDetermined {
            MPMediaLibrary.requestAuthorization { _ in }
        }
    }

    /// Reproduce la canción; `log` recibe el resultado.
    static func play(link: String, log: @escaping (String) -> Void) {
        guard let id = storeID(from: link) else {
            log("❌ [SONG] Not an Apple Music song link: \(link)")
            return
        }
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            log("❌ [SONG] Music access not granted (status \(MPMediaLibrary.authorizationStatus().rawValue))")
            return
        }

        let player = MPMusicPlayerController.systemMusicPlayer
        player.setQueue(with: [id])
        player.prepareToPlay { error in
            DispatchQueue.main.async {
                if let error = error {
                    log("❌ [SONG] \(id): \(error.localizedDescription)")
                    return
                }
                player.play()
                log("🎵 [SONG] Playing \(id)")
                if UIApplication.shared.applicationState == .active, let url = URL(string: link) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    private static func isNumeric(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy(\.isNumber)
    }
}
