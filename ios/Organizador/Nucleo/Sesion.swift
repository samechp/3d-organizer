// Si hay sesión o no. RaizVista la mira para decidir entre la pantalla de
// entrar y las pestañas; ClienteAPI avisa con .sesionVencida cuando un 401
// la invalida.
import Foundation
import Observation

@MainActor
@Observable
final class Sesion {
    private(set) var token: String?
    /// Con qué correo se entró, para mostrarlo en Ajustes. No es secreto (el
    /// token sí, y va en el llavero).
    private(set) var correo: String? = nil

    private static let claveCorreo = "sesion.correo"

    var haySesion: Bool { token != nil }

    @ObservationIgnored private var observador: NSObjectProtocol?

    init() {
        token = Llavero.leer()
        correo = UserDefaults.standard.string(forKey: Sesion.claveCorreo)
        observador = NotificationCenter.default.addObserver(
            forName: .sesionVencida, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // El cierre no está marcado como del hilo principal (aunque la
            // cola sea .main); el cambio de estado tiene que hacerse en él.
            // Se relee el llavero en vez de poner nil: si justo entró de
            // nuevo, el token nuevo ya está ahí y no se debe perder.
            Task { @MainActor in
                self.token = Llavero.leer()
            }
        }
    }

    func entrar(correo: String, clave: String) async throws {
        token = try await ClienteAPI.compartido.entrar(correo: correo, clave: clave)
        recordarCorreo(correo)
    }

    /// Las sesiones de antes de guardar el correo lo piden a /api/yo una vez.
    func recordarCorreo(_ nuevo: String) {
        let limpio = nuevo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { return }
        correo = limpio
        UserDefaults.standard.set(limpio, forKey: Sesion.claveCorreo)
    }

    func salir() async {
        await ClienteAPI.compartido.salir()
        // La copia de los pedidos se borra; la cola sin señal no: son piezas
        // ya impresas y se mandan cuando alguien vuelva a entrar.
        Almacen.borrarTodo()
        UserDefaults.standard.removeObject(forKey: Sesion.claveCorreo)
        correo = nil
        token = nil
    }
}
