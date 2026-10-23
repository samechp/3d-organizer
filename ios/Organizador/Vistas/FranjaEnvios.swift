// Franja de "N tandas pendientes de enviar" y, si el servidor rechazó alguna
// de la cola, el aviso con la lista y el motivo: nada se pierde en silencio.
import SwiftUI

struct FranjaEnvios: View {
    @Environment(Envios.self) private var envios
    @State private var verDescartadas = false

    var body: some View {
        VStack(spacing: 8) {
            if !envios.pendientes.isEmpty {
                let n = envios.pendientes.count
                Button {
                    Task { await envios.vaciar() }
                } label: {
                    fila(texto: "\(Formato.num(n)) \(Formato.plural(n, "tanda pendiente", "tandas pendientes")) de enviar",
                         icono: "icloud.and.arrow.up", color: .acentoTexto)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Se envían solas cuando vuelve la señal. Toca para intentarlo ahora.")
            }
            if !envios.descartadas.isEmpty {
                let n = envios.descartadas.count
                Button {
                    verDescartadas = true
                } label: {
                    fila(texto: "\(Formato.num(n)) \(Formato.plural(n, "tanda no se pudo guardar", "tandas no se pudieron guardar"))",
                         icono: "exclamationmark.triangle.fill", color: .red)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Toca para ver por qué y volver a intentarlo.")
            }
        }
        .sheet(isPresented: $verDescartadas) {
            DescartadasVista()
        }
    }

    private func fila(texto: String, icono: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icono)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(texto)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .vidrio()
        .contentShape(Rectangle())
    }
}

/// Las tandas de la cola que el servidor no aceptó, con el motivo.
struct DescartadasVista: View {
    @Environment(Envios.self) private var envios
    @Environment(\.dismiss) private var cerrar
    @State private var confirmarOlvido = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(envios.descartadas.enumerated()), id: \.offset) { _, d in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(Formato.num(d.tanda.cantidad)) de \(Almacen.nombreModelo(id: d.tanda.modeloId) ?? "un modelo")")
                                .font(.body.weight(.semibold))
                            Text(Formato.cuando(d.tanda.cuando))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(d.motivo)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                } footer: {
                    Text("Si el problema ya se arregló, vuelve a intentarlo. Si no, anótalas de nuevo en el pedido correcto y descártalas.")
                }

                Section {
                    Button {
                        envios.reintentarDescartadas()
                        cerrar()
                    } label: {
                        Label("Volver a intentar", systemImage: "arrow.clockwise")
                            .frame(minHeight: 44)
                    }
                    Button(role: .destructive) {
                        confirmarOlvido = true
                    } label: {
                        Label("Descartar", systemImage: "trash")
                            .frame(minHeight: 44)
                    }
                }
            }
            .navigationTitle("No se guardaron")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        cerrar()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cerrar")
                }
            }
            .confirmationDialog("¿Descartar estas tandas?", isPresented: $confirmarOlvido, titleVisibility: .visible) {
                Button("Descartar", role: .destructive) {
                    envios.olvidarDescartadas()
                    cerrar()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("No se van a sumar al avance de ningún pedido.")
            }
        }
    }
}
