// Provisional: Task 10 la reemplaza por la calculadora.
import SwiftUI

struct CalculadoraVista: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Calculadora", systemImage: "plus.forwardslash.minus",
                                   description: Text("Aquí va a estar la calculadora de precios."))
                .navigationTitle("Calculadora")
                .toolbarTitleDisplayMode(.inlineLarge)
        }
    }
}
