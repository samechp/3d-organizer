// Historial de tandas de un pedido (maqueta Historial): por día, con filtro
// por modelo. Deslizar a la izquierda muestra Editar y Borrar.
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
                    Text("Desliza una tanda a la izquierda para editarla o borrarla.")
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
            EditarTandaVista(tanda: t) { await cargar() }
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
        return HStack {
            Text("\(Formato.num(t.cantidad)) · \(t.modelo)")
                .font(.body)
            Spacer()
            Text(hora)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Formato.num(t.cantidad)) de \(t.modelo), \(hora)")
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
            try await ClienteAPI.compartido.borrarTanda(id: t.id)
            tandas.removeAll { $0.id == t.id }
            Almacen.guardarTandas(tandas, pedidoId: pedidoId)
            UIAccessibility.post(notification: .announcement, argument: "Tanda borrada")
            await cargar()
        } catch {
            if let texto = error.textoParaMostrar { mensaje = texto }
        }
    }
}

/// Hoja para corregir la cantidad o la hora de una tanda.
private struct EditarTandaVista: View {
    let tanda: Tanda
    let alGuardar: () async -> Void

    @Environment(\.dismiss) private var cerrar
    @State private var textoCantidad: String
    @State private var cuando: Date
    @State private var guardando = false
    @State private var fallo: String? = nil

    init(tanda: Tanda, alGuardar: @escaping () async -> Void) {
        self.tanda = tanda
        self.alGuardar = alGuardar
        _textoCantidad = State(initialValue: String(tanda.cantidad))
        _cuando = State(initialValue: tanda.fecha ?? Date())
    }

    private var cantidad: Int? {
        guard let n = Int(textoCantidad), (1...100_000).contains(n) else { return nil }
        return n
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Modelo", value: tanda.modelo)
                    TextField("Cantidad", text: $textoCantidad)
                        .keyboardType(.numberPad)
                        .accessibilityLabel("Cantidad")
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
            }
            .navigationTitle("Editar tanda")
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
                            .disabled(cantidad == nil)
                    }
                }
            }
        }
    }

    private func guardar() async {
        guard let cantidad else { return }
        // Solo se manda lo que cambió.
        var cambios = CambiosTanda()
        if cantidad != tanda.cantidad { cambios.cantidad = cantidad }
        if let antes = tanda.fecha, abs(antes.timeIntervalSince(cuando)) >= 60 {
            cambios.cuando = Fechas.textoHora(cuando)
        } else if tanda.fecha == nil {
            cambios.cuando = Fechas.textoHora(cuando)
        }
        guard cambios.cantidad != nil || cambios.cuando != nil else {
            cerrar()
            return
        }
        guardando = true
        defer { guardando = false }
        do {
            _ = try await ClienteAPI.compartido.editarTanda(id: tanda.id, cambios)
            await alGuardar()
            cerrar()
        } catch {
            fallo = error.textoParaMostrar
        }
    }
}
