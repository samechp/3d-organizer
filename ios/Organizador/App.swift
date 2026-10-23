// Punto de entrada. La Sesion se crea una vez aquí y baja a todas las vistas
// por el entorno.
import SwiftUI

@main
struct OrganizadorApp: App {
    @State private var sesion = Sesion()

    var body: some Scene {
        WindowGroup {
            RaizVista()
                .environment(sesion)
        }
    }
}
