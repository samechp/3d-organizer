// Hoja para corregir una tanda: cantidad (con − y + para el típico "anoté 50
// pero uno salió malo"), fecha y hora, o borrarla. La abren el Historial y
// las últimas tandas del Detalle, así que vive aparte para que las dos
// pantallas usen la misma. Con init(movimiento:) corrige también una venta o
// tanda de un producto (mismos campos, otras rutas).
import SwiftUI
import UIKit

struct EditarTandaVista: View {
    /// Lo que se corrige, ya sea tanda de pedido o movimiento de producto.
    private struct Dato {
        let titulo: String
        let etiqueta: String
        let nombre: String
        let cantidad: Int
        let fecha: Date?
        let textoBorrar: String
        let avisoBorrar: String
        let anuncioBorrado: String
        let editar: (CambiosTanda) async throws -> Void
        let borrar: () async throws -> Void
    }

    private let dato: Dato
    /// Se llama después de guardar, antes de cerrar: la pantalla de atrás recarga.
    let alGuardar: () async -> Void
    /// Se llama después de borrar (o si ya estaba borrada), antes de cerrar.
    let alBorrar: () async -> Void

    @Environment(\.dismiss) private var cerrar
    @State private var textoCantidad: String
    @State private var cuando: Date
    @State private var guardando = false
    @State private var borrando = false
    @State private var confirmarBorrar = false
    @State private var fallo: String? = nil
    /// Suben con cada toque de − / + y con cada cambio hecho: disparan la háptica.
    @State private var pasos = 0
    @State private var hechos = 0

    private static let maximo = 100_000

    init(tanda: Tanda, alGuardar: @escaping () async -> Void, alBorrar: @escaping () async -> Void) {
        let id = tanda.id
        self.init(dato: Dato(
            titulo: "Editar tanda", etiqueta: "Modelo", nombre: tanda.modelo,
            cantidad: tanda.cantidad, fecha: tanda.fecha, textoBorrar: "Borrar tanda",
            avisoBorrar: "Se restan \(Formato.num(tanda.cantidad)) de \(tanda.modelo) del avance del pedido.",
            anuncioBorrado: "Tanda borrada",
            editar: { cambios in _ = try await ClienteAPI.compartido.editarTanda(id: id, cambios) },
            borrar: { try await ClienteAPI.compartido.borrarTandaAunqueNoExista(id: id) }),
            alGuardar: alGuardar, alBorrar: alBorrar)
    }

    init(movimiento m: Movimiento, alGuardar: @escaping () async -> Void, alBorrar: @escaping () async -> Void) {
        let id = m.id
        let venta = m.esVenta
        self.init(dato: Dato(
            titulo: venta ? "Editar venta" : "Editar tanda", etiqueta: "Opción", nombre: m.opcion,
            cantidad: m.cantidad, fecha: m.fecha, textoBorrar: venta ? "Borrar venta" : "Borrar tanda",
            avisoBorrar: venta
                ? "Se devuelven \(Formato.num(m.cantidad)) al stock de \(m.opcion)."
                : "Se restan \(Formato.num(m.cantidad)) del stock de \(m.opcion).",
            anuncioBorrado: venta ? "Venta borrada" : "Tanda borrada",
            editar: { cambios in _ = try await ClienteAPI.compartido.editarMovimiento(id: id, cambios) },
            borrar: {
                do {
                    try await ClienteAPI.compartido.borrarMovimiento(id: id)
                } catch ErrorAPI.noExiste {
                    // Ya estaba borrado.
                }
            }),
            alGuardar: alGuardar, alBorrar: alBorrar)
    }

    private init(dato: Dato, alGuardar: @escaping () async -> Void, alBorrar: @escaping () async -> Void) {
        self.dato = dato
        self.alGuardar = alGuardar
        self.alBorrar = alBorrar
        _textoCantidad = State(initialValue: String(dato.cantidad))
        _cuando = State(initialValue: dato.fecha ?? Date())
    }

    private var cantidad: Int? {
        guard let n = Int(textoCantidad), (1...Self.maximo).contains(n) else { return nil }
        return n
    }

    /// Desde dónde suman o restan − y +: lo escrito o, si no es un número,
    /// lo que tenía la tanda.
    private var base: Int { Int(textoCantidad) ?? dato.cantidad }

    private var ocupado: Bool { guardando || borrando }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(dato.etiqueta, value: dato.nombre)
                    HStack(spacing: 12) {
                        TextField("Cantidad", text: $textoCantidad)
                            .keyboardType(.numberPad)
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .accessibilityLabel("Cantidad")
                        botonPaso(icono: "minus", etiqueta: "Restar uno", activo: base > 1) {
                            cambiar(-1)
                        }
                        botonPaso(icono: "plus", etiqueta: "Sumar uno", activo: base < Self.maximo) {
                            cambiar(1)
                        }
                    }
                    DatePicker("Fecha y hora", selection: $cuando, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, Fechas.bogota)
                } footer: {
                    if let fallo {
                        Text(fallo).foregroundStyle(.red)
                    } else if cantidad == nil {
                        Text("Escribe un número de 1 a 100.000.")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmarBorrar = true
                    } label: {
                        HStack {
                            Label(dato.textoBorrar, systemImage: "trash")
                            if borrando {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(ocupado)
                }
            }
            .navigationTitle(dato.titulo)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { cerrar() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if guardando {
                        ProgressView()
                    } else {
                        Button("Guardar") { Task { await guardar() } }
                            .disabled(cantidad == nil || borrando)
                    }
                }
            }
            .confirmationDialog("¿\(dato.textoBorrar)?", isPresented: $confirmarBorrar,
                                titleVisibility: .visible) {
                Button(dato.textoBorrar, role: .destructive) {
                    Task { await borrar() }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(dato.avisoBorrar)
            }
            .sensoryFeedback(.selection, trigger: pasos)
            .sensoryFeedback(.success, trigger: hechos)
        }
    }

    /// Botón redondo de 44 pt, como el + de los modelos en el Detalle.
    private func botonPaso(icono: String, etiqueta: String, activo: Bool,
                           accion: @escaping () -> Void) -> some View {
        Button(action: accion) {
            Image(systemName: icono)
                .font(.body.weight(.bold))
                .foregroundStyle(Color.acentoTexto)
                .frame(width: 44, height: 44)
                .background(Color.acento.opacity(0.14), in: Circle())
                .contentShape(Circle())
        }
        // Dentro de un Form, sin esto el toque en cualquier parte de la fila
        // dispararía todos los botones de la fila a la vez.
        .buttonStyle(.borderless)
        .disabled(!activo || ocupado)
        .opacity(activo ? 1 : 0.4)
        .accessibilityLabel(etiqueta)
    }

    private func cambiar(_ paso: Int) {
        textoCantidad = String(min(Self.maximo, max(1, base + paso)))
        pasos += 1
    }

    private func guardar() async {
        guard let cantidad else { return }
        // Solo se manda lo que cambió.
        var cambios = CambiosTanda()
        if cantidad != dato.cantidad { cambios.cantidad = cantidad }
        if let antes = dato.fecha, abs(antes.timeIntervalSince(cuando)) >= 60 {
            cambios.cuando = Fechas.textoHora(cuando)
        } else if dato.fecha == nil {
            cambios.cuando = Fechas.textoHora(cuando)
        }
        guard cambios.cantidad != nil || cambios.cuando != nil else {
            cerrar()
            return
        }
        guardando = true
        defer { guardando = false }
        do {
            try await dato.editar(cambios)
            hechos += 1
            await alGuardar()
            cerrar()
        } catch is CancellationError {
            // La hoja se cerró: nada que mostrar.
        } catch {
            fallo = error.textoParaMostrar
        }
    }

    private func borrar() async {
        borrando = true
        defer { borrando = false }
        do {
            try await dato.borrar()
            hechos += 1
            UIAccessibility.post(notification: .announcement, argument: dato.anuncioBorrado)
            await alBorrar()
            cerrar()
        } catch is CancellationError {
            // La hoja se cerró: nada que mostrar.
        } catch {
            fallo = error.textoParaMostrar
        }
    }
}

extension ClienteAPI {
    /// Borra la tanda; si ya no existía (se borró desde la web o en un intento
    /// anterior), el resultado es el que se buscaba, así que no es un error.
    func borrarTandaAunqueNoExista(id: Int) async throws {
        do {
            try await borrarTanda(id: id)
        } catch ErrorAPI.noExiste {
            // Ya estaba borrada.
        }
    }
}

#Preview("Editar tanda") {
    EditarTandaVista(tanda: Muestras.detalle.ultimasTandas[0], alGuardar: {}, alBorrar: {})
}
