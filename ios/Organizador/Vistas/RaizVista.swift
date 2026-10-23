// La primera vista: sin sesión, la pantalla de entrar; con sesión, las tres
// pestañas. La barra de pestañas clásica toma el Liquid Glass sola en iOS 26.
import SwiftUI

struct RaizVista: View {
    @Environment(Sesion.self) private var sesion

    var body: some View {
        Group {
            if sesion.haySesion {
                TabView {
                    PedidosVista()
                        .tabItem { Label("Pedidos", systemImage: "shippingbox") }
                    CalculadoraVista()
                        .tabItem { Label("Calculadora", systemImage: "plus.forwardslash.minus") }
                    AjustesVista()
                        .tabItem { Label("Ajustes", systemImage: "slider.horizontal.3") }
                }
            } else {
                EntrarVista()
            }
        }
        .tint(Color.acento)
        // Háptica de éxito al entrar. Solo cuando pasa de no tener sesión a
        // tenerla: al abrir la app ya con sesión no suena.
        .sensoryFeedback(.success, trigger: sesion.haySesion) { _, ahora in ahora }
    }
}
