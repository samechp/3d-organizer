// Punto de entrada. La Sesion y los Envios (cola sin señal) se crean una vez
// aquí y bajan a todas las vistas por el entorno.
import SwiftUI

@main
struct OrganizadorApp: App {
    @State private var sesion = Sesion()
    @State private var envios = Envios()

    var body: some Scene {
        WindowGroup {
            RaizVista()
                .environment(sesion)
                .environment(envios)
        }
    }
}
