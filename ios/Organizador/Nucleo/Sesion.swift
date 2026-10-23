// Si hay sesión o no. RaizVista la mira para decidir entre la pantalla de
// entrar y las pestañas; ClienteAPI avisa con .sesionVencida cuando un 401
// la invalida.
import Foundation
import Observation

@MainActor
@Observable
final class Sesion {
    private(set) var token: String?

    var haySesion: Bool { token != nil }

    @ObservationIgnored private var observador: NSObjectProtocol?

    init() {
        token = Llavero.leer()
        observador = NotificationCenter.default.addObserver(
            forName: .sesionVencida, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // El cierre no está marcado como del hilo principal (aunque la
            // cola sea .main); el cambio de estado tiene que hacerse en él.
            Task { @MainActor in
                self.token = nil
            }
        }
    }

    func entrar(correo: String, clave: String) async throws {
        token = try await ClienteAPI.compartido.entrar(correo: correo, clave: clave)
    }

    func salir() async {
        await ClienteAPI.compartido.salir()
        token = nil
    }
}
