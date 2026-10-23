// La primera vista: sin sesión, la pantalla de entrar; con sesión, las tres
// pestañas. La barra de pestañas clásica toma el Liquid Glass sola en iOS 26.
import SwiftUI

struct RaizVista: View {
    @Environment(Sesion.self) private var sesion
    @Environment(Envios.self) private var envios
    @Environment(\.scenePhase) private var fase

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
        // La cola sin señal se vacía al abrir la app, al volver a entrar
        // (la sesión vencida no la borró) y al volver a primer plano; cuando
        // vuelve la red, Envios lo hace solo.
        .task(id: sesion.haySesion) {
            if sesion.haySesion { await envios.vaciar() }
        }
        .onChange(of: fase) { _, nueva in
            if nueva == .active && sesion.haySesion {
                Task { await envios.vaciar() }
            }
        }
    }
}
