// Provisional: Task 10 la reemplaza por perfiles y filamentos. Ya trae
// "Cerrar sesión", que sí funciona.
import SwiftUI

struct AjustesVista: View {
    @Environment(Sesion.self) private var sesion
    @State private var confirmar = false
    @State private var cerrando = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(role: .destructive) {
                        confirmar = true
                    } label: {
                        Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(minHeight: 44)
                    }
                    .disabled(cerrando)
                }
            }
            .navigationTitle("Ajustes")
            .toolbarTitleDisplayMode(.inlineLarge)
            .confirmationDialog("¿Cerrar sesión?", isPresented: $confirmar, titleVisibility: .visible) {
                Button("Cerrar sesión", role: .destructive) {
                    cerrando = true
                    Task {
                        await sesion.salir()
                        cerrando = false
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Para volver a usar la app tendrás que entrar con tu correo y contraseña.")
            }
        }
    }
}
