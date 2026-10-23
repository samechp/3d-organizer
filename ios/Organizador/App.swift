// Punto de entrada. La Sesion, los Envios (cola sin señal) y el Catalogo
// (perfiles y filamentos) se crean una vez aquí y bajan a todas las vistas
// por el entorno.
import SwiftUI

@main
struct OrganizadorApp: App {
    @State private var sesion = Sesion()
    @State private var envios = Envios()
    @State private var catalogo = Catalogo()

    var body: some Scene {
        WindowGroup {
            RaizVista()
                .environment(sesion)
                .environment(envios)
                .environment(catalogo)
        }
    }
}
