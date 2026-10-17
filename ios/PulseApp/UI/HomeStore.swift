import Foundation
import Combine

/// Calcula HomeData en segundo plano (una cosa cada vez) y guarda el último resultado de cada día un rato,
/// para que Inicio, Sueño, Esfuerzo y Salud no repitan el mismo trabajo al cambiar de pantalla.
final class HomeStore: ObservableObject {
    static let shared = HomeStore()

    /// Sube cada vez que cambian los datos (actividad guardada, perfil, hora de despertar…): las pantallas recargan.
    @Published var version = 0

    private let queue = DispatchQueue(label: "pulseapp.home", qos: .userInitiated)
    private var cache = [Int: (Date, HomeData)]()   // solo se toca desde `queue`

    /// Datos de hoy + [offset]. Si hay unos de hace menos de [maxAge] s se devuelven sin recalcular.
    func load(_ offset: Int, maxAge: TimeInterval = 50, completion: @escaping (HomeData) -> Void) {
        queue.async {
            if let c = self.cache[offset], Date().timeIntervalSince(c.0) < (offset == 0 ? maxAge : max(maxAge, 600)) {
                let d = c.1
                DispatchQueue.main.async { completion(d) }
                return
            }
            let d = HomeDataLoader.load(dayOffset: offset)
            self.cache[offset] = (Date(), d)
            DispatchQueue.main.async { completion(d) }
        }
    }

    /// Algo ha cambiado: se olvida lo calculado y se avisa a las pantallas.
    func invalidate() {
        queue.async { self.cache.removeAll() }
        DispatchQueue.main.async { self.version += 1 }
    }

    /// Trabajo pesado que no es HomeData (p. ej. el Monitor de estrés), en la misma cola.
    func run<T>(_ work: @escaping () -> T, completion: @escaping (T) -> Void) {
        queue.async {
            let r = work()
            DispatchQueue.main.async { completion(r) }
        }
    }
}

/// Pantallas a las que se puede ir dentro de cada pestaña.
enum Route: Hashable {
    case sleep(Int)
    case strain(Int)
    case health
    case stress
    case recovery
    case activity(Int64)
    case editActivity(Int64)
}
