// Historial de tandas de un pedido (maqueta Historial): por día, con filtro
// por modelo. Tocar una tanda abre la hoja para editarla o borrarla; deslizar
// a la izquierda sigue mostrando Editar y Borrar como atajo.
import SwiftUI
import UIKit

struct HistorialVista: View {
    let pedidoId: Int

    @State private var tandas: [Tanda]
    @State private var detalle: PedidoDetalle?
    /// nil = todos los modelos.
    @State private var filtro: Int? = nil
    @State private var mensaje: String? = nil
    @State private var editando: Tanda? = nil
    @State private var borrando: Tanda? = nil

    @Environment(Envios.self) private var envios

    init(pedidoId: Int) {
        self.pedidoId = pedidoId
        _tandas = State(initialValue: Almacen.tandas(pedidoId: pedidoId))
        _detalle = State(initialValue: Almacen.detalle(id: pedidoId))
    }

    private struct Dia: Identifiable {
        let id: String
        let titulo: String
        let tandas: [Tanda]
        var total: Int { tandas.reduce(0) { $0 + $1.cantidad } }
    }

    /// Los modelos para los filtros: los del pedido, en su orden; si el
    /// detalle no está guardado, los que salen en las tandas.
    private struct OpcionModelo: Identifiable {
        let id: Int
        let nombre: String
    }

    private var modelos: [OpcionModelo] {
        if let d = detalle { return d.modelos.map { OpcionModelo(id: $0.id, nombre: $0.nombre) } }
        var vistos: [OpcionModelo] = []
        for t in tandas where !vistos.contains(where: { $0.id == t.modeloId }) {
            vistos.append(OpcionModelo(id: t.modeloId, nombre: t.modelo))
        }
        return vistos
    }

    private var dias: [Dia] {
        let filtradas = tandas.filter { filtro == nil || $0.modeloId == filtro }
        var grupos: [Dia] = []
        for t in filtradas {
            let fecha = t.fecha ?? Date.distantPast
            let componentes = Formato.calendario.dateComponents([.year, .month, .day], from: fecha)
            let clave = "\(componentes.year ?? 0)-\(componentes.month ?? 0)-\(componentes.day ?? 0)"
            if let ultimo = grupos.last, ultimo.id == clave {
                grupos[grupos.count - 1] = Dia(id: clave, titulo: ultimo.titulo, tandas: ultimo.tandas + [t])
            } else {
                grupos.append(Dia(id: clave, titulo: Formato.encabezadoDia(fecha), tandas: [t]))
            }
        }
        return grupos
    }

    var body: some View {
        List {
            Section {
                filtros
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if !envios.pendientes.isEmpty || !envios.descartadas.isEmpty {
                Section {
                    FranjaEnvios()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if let mensaje {
                Section {
                    Label(mensaje, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if dias.isEmpty {
                Section {
                    Text(filtro == nil ? "Todavía no hay tandas anotadas." : "Este modelo no tiene tandas.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(dias) { dia in
                Section {
                    ForEach(dia.tandas) { t in
                        fila(t)
                    }
                } header: {
                    HStack {
                        Text(dia.titulo)
                        Spacer()
                        Text("\(Formato.num(dia.total)) buenas")
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !dias.isEmpty {
                Section {
                } footer: {
                    Text("Toca una tanda para editarla o borrarla. También puedes deslizarla a la izquierda.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Historial")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await cargar() }
        .task { await cargar() }
        .onChange(of: envios.enviadas) { Task { await cargar() } }
        .sheet(item: $editando) { t in
            EditarTandaVista(tanda: t, alGuardar: { await cargar() }, alBorrar: { await quitar(t) })
        }
        .confirmationDialog("¿Borrar esta tanda?", isPresented: Binding(
            get: { borrando != nil },
            set: { if !$0 { borrando = nil } }
        ), titleVisibility: .visible, presenting: borrando) { t in
            Button("Borrar tanda", role: .destructive) {
                Task { await borrar(t) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { t in
            Text("Se restan \(Formato.num(t.cantidad)) de \(t.modelo) del avance del pedido.")
        }
    }

    private var filtros: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Todos", elegido: filtro == nil) { filtro = nil }
                ForEach(modelos) { m in
                    chip(m.nombre, elegido: filtro == m.id) { filtro = m.id }
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filtrar por modelo")
    }

    private func chip(_ texto: String, elegido: Bool, accion: @escaping () -> Void) -> some View {
        Button(action: accion) {
            Text(texto)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(elegido ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(elegido ? Color.acento : Color(.secondarySystemGroupedBackground), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(elegido ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private func fila(_ t: Tanda) -> some View {
        let hora = t.fecha.map { Formato.hora($0) } ?? ""
        // Toda la fila es un botón (con su flecha) para que editar se vea sin
        // tener que adivinar que se desliza.
        return Button {
            editando = t
        } label: {
            HStack {
                Text("\(Formato.num(t.cantidad)) · \(t.modelo)")
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                Text(hora)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        // El botón ya junta lo de adentro en un solo elemento; la etiqueta lo
        // dice como frase ("50 de Medalla oro") en vez de leer el "·".
        .accessibilityLabel("\(Formato.num(t.cantidad)) de \(t.modelo), \(hora)")
        .accessibilityHint("Toca para editar")
        // El primero que se declara queda en el borde: Borrar va a la derecha
        // del todo y Editar a su lado, como en la maqueta.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                borrando = t
            } label: {
                Label("Borrar", systemImage: "trash")
            }
            .tint(.red)
            .accessibilityLabel("Borrar tanda de \(Formato.num(t.cantidad)) de \(t.modelo)")
            Button {
                editando = t
            } label: {
                Label("Editar", systemImage: "pencil")
            }
            .tint(.blue)
            .accessibilityLabel("Editar tanda de \(Formato.num(t.cantidad)) de \(t.modelo)")
        }
    }

    private func cargar() async {
        do {
            let nuevas = try await ClienteAPI.compartido.tandas(pedidoId: pedidoId)
            tandas = nuevas
            Almacen.guardarTandas(nuevas, pedidoId: pedidoId)
            mensaje = nil
        } catch {
            if let texto = error.textoParaMostrar {
                mensaje = tandas.isEmpty ? texto : "\(texto) Se muestra lo último guardado."
            }
        }
    }

    private func borrar(_ t: Tanda) async {
        do {
            // Si ya estaba borrada (desde la web o un intento anterior) también
            // cuenta como hecho, y se quita de la lista.
            try await ClienteAPI.compartido.borrarTandaAunqueNoExista(id: t.id)
            UIAccessibility.post(notification: .announcement, argument: "Tanda borrada")
            await quitar(t)
        } catch is CancellationError {
            // La vista se fue: nada que mostrar.
        } catch {
            if let texto = error.textoParaMostrar { mensaje = texto }
        }
    }

    /// Tras borrar (desde el deslizar o desde la hoja): se quita de una vez y
    /// luego se recarga para que todo cuadre con el servidor.
    private func quitar(_ t: Tanda) async {
        tandas.removeAll { $0.id == t.id }
        Almacen.guardarTandas(tandas, pedidoId: pedidoId)
        await cargar()
    }
}
