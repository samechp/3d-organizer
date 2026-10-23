// Provisional: Task 9 la reemplaza por la lista de pedidos.
import SwiftUI

struct PedidosVista: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Pedidos", systemImage: "shippingbox",
                                   description: Text("Aquí van a aparecer tus pedidos."))
                .navigationTitle("Pedidos")
        }
    }
}
