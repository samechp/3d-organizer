// Crear un pedido (maqueta NuevoPedido) o, con `editando`, cambiar uno que ya
// existe: nombre, cliente, entrega y sus modelos.
import SwiftUI

struct NuevoPedidoVista: View {
    let editando: PedidoDetalle?
    let alGuardar: (PedidoDetalle) -> Void

    @Environment(\.dismiss) private var cerrar

    private struct FilaModelo: Identifiable {
        let id = UUID()
        /// nil = modelo nuevo, todavía no está en el servidor.
        var existenteId: Int?
        var nombre: String
        var meta: String
        /// Un modelo con tandas no se puede quitar (el servidor lo rechaza).
        var hechas: Int = 0
        /// Del stock: sale de una opción de Productos (opcionId) y no lleva nombre
        /// propio. En uno que ya existe no se cambia (el servidor no deja).
        var delStock = false
        var opcionId: Int? = nil
    }

    /// Una opción de Productos para elegir: "Producto · Opción" y su saldo.
    private struct OpcionElegible: Identifiable {
        let id: Int
        let nombre: String
        let saldo: Int
    }

    @State private var nombre: String
    @State private var cliente: String
    @State private var conFecha: Bool
    @State private var entrega: Date
    @State private var modelos: [FilaModelo]
    @State private var guardando = false
    /// Los modelos como están en el servidor según lo último que se sabe. Se
    /// actualiza con cada paso que sale bien: si guardar falla a la mitad, el
    /// reintento solo hace lo que faltó (no duplica ni vuelve a borrar).
    @State private var originales: [Modelo]
    @State private var fallo: String? = nil
    /// Para los modelos del stock: lo guardado se muestra de una vez y se refresca al abrir.
    @State private var productos: [ProductoResumen] = Almacen.productos() ?? []

    private static let maxModelos = 50

    private var opcionesStock: [OpcionElegible] {
        productos.flatMap { p in
            p.opciones.map { OpcionElegible(id: $0.id, nombre: "\(p.nombre) · \($0.nombre)", saldo: $0.saldo) }
        }
    }

    init(editando: PedidoDetalle?, alGuardar: @escaping (PedidoDetalle) -> Void) {
        self.editando = editando
        self.alGuardar = alGuardar
        _originales = State(initialValue: editando?.modelos ?? [])
        let enUnaSemana = Formato.calendario.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        if let d = editando {
            _nombre = State(initialValue: d.nombre)
            _cliente = State(initialValue: d.cliente ?? "")
            _conFecha = State(initialValue: d.entrega != nil)
            _entrega = State(initialValue: d.fechaEntrega ?? enUnaSemana)
            _modelos = State(initialValue: d.modelos.map {
                FilaModelo(existenteId: $0.id, nombre: $0.delStock?.nombre ?? $0.nombre, meta: String($0.meta),
                           hechas: $0.hechas, delStock: $0.esDelStock, opcionId: $0.opcionId)
            })
        } else {
            _nombre = State(initialValue: "")
            _cliente = State(initialValue: "")
            _conFecha = State(initialValue: true)
            _entrega = State(initialValue: enUnaSemana)
            _modelos = State(initialValue: [FilaModelo(existenteId: nil, nombre: "", meta: "")])
        }
    }

    private func limpio(_ texto: String) -> String {
        texto.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func metaValida(_ texto: String) -> Int? {
        guard let n = Int(texto), (1...1_000_000).contains(n) else { return nil }
        return n
    }

    private var total: Int {
        modelos.reduce(0) { $0 + (metaValida($1.meta) ?? 0) }
    }

    /// Lo que falta para poder guardar, o nil si está todo bien.
    private var problema: String? {
        let n = limpio(nombre)
        if n.isEmpty { return "Escribe el nombre del pedido." }
        if n.count > 120 { return "El nombre puede tener hasta 120 letras." }
        if limpio(cliente).count > 120 { return "El cliente puede tener hasta 120 letras." }
        if modelos.isEmpty { return "Agrega al menos un modelo." }
        for m in modelos {
            if m.delStock {
                guard m.opcionId != nil else { return "Elige de qué producto sale cada modelo del stock." }
                if metaValida(m.meta) == nil { return "La cantidad de cada modelo del stock debe ser un número de 1 a 1.000.000." }
                continue
            }
            let nm = limpio(m.nombre)
            if nm.isEmpty { return "Cada modelo necesita un nombre." }
            if nm.count > 80 { return "El nombre de un modelo puede tener hasta 80 letras." }
            if metaValida(m.meta) == nil { return "La meta de \(nm) debe ser un número de 1 a 1.000.000." }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Nombre") {
                        TextField("Ej.: Llaveros empresa X", text: $nombre)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Nombre")
                    }
                    LabeledContent("Cliente") {
                        TextField("Opcional", text: $cliente)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Cliente")
                    }
                }

                Section {
                    Toggle("Fecha de entrega", isOn: $conFecha)
                        .tint(Color.completo)
                    if conFecha {
                        DatePicker("Entregar el", selection: $entrega, displayedComponents: .date)
                            .environment(\.timeZone, Fechas.bogota)
                    }
                }

                Section {
                    ForEach($modelos) { $m in
                        filaModelo($m)
                            // Los del stock no tienen tandas: se pueden quitar (el stock vuelve).
                            .deleteDisabled(m.hechas > 0 && !m.delStock)
                    }
                    .onDelete { posiciones in
                        modelos.remove(atOffsets: posiciones)
                    }
                    Button {
                        modelos.append(FilaModelo(existenteId: nil, nombre: "", meta: modelos.last?.meta ?? ""))
                    } label: {
                        Label("Agregar modelo", systemImage: "plus.circle.fill")
                            .frame(minHeight: 44)
                    }
                    .disabled(modelos.count >= NuevoPedidoVista.maxModelos)
                } header: {
                    HStack {
                        Text("Modelos · \(Formato.num(modelos.count))")
                        Spacer()
                        Text("Total \(Formato.num(total))")
                    }
                } footer: {
                    Text(editando == nil
                         ? "La foto de cada modelo se agrega después, en el pedido: toca su recuadro."
                         : "Un modelo que ya tiene tandas no se puede quitar.")
                }

                if let fallo {
                    Section {
                        Label(fallo, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .task { await cargarProductos() }
            // Mientras se guarda no se tocan las filas: guardarCambios las va marcando.
            .disabled(guardando)
            .navigationTitle(editando == nil ? "Nuevo pedido" : "Editar pedido")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(guardando)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        cerrar()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancelar")
                    .disabled(guardando)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if guardando {
                        ProgressView()
                    } else {
                        Button {
                            Task { await guardar() }
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .accessibilityLabel(editando == nil ? "Crear pedido" : "Guardar cambios")
                        .disabled(problema != nil)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let problema, !guardando {
                    Text(problema)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .vidrio(Capsule())
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Filas

    private func campoMeta(_ m: Binding<FilaModelo>, etiqueta: String) -> some View {
        TextField(m.wrappedValue.delStock ? "Cantidad" : "Meta", text: m.meta)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(maxWidth: 110)
            .accessibilityLabel(etiqueta)
    }

    @ViewBuilder
    private func filaModelo(_ m: Binding<FilaModelo>) -> some View {
        let fila = m.wrappedValue
        if fila.existenteId != nil && fila.delStock {
            // Ya existe y sale del stock: la opción no se cambia, la cantidad sí.
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Del stock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fila.nombre)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                campoMeta(m, etiqueta: "Cantidad de \(fila.nombre)")
            }
            .frame(minHeight: 44)
        } else if fila.existenteId != nil {
            HStack(spacing: 12) {
                TextField("Nombre del modelo", text: m.nombre)
                    .accessibilityLabel("Nombre del modelo")
                campoMeta(m, etiqueta: "Meta de \(fila.nombre.isEmpty ? "este modelo" : fila.nombre)")
            }
            .frame(minHeight: 44)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Tipo de modelo", selection: m.delStock) {
                    Text("Nuevo").tag(false)
                    Text("Del stock").tag(true)
                }
                .pickerStyle(.segmented)
                if !fila.delStock {
                    HStack(spacing: 12) {
                        TextField("Nombre del modelo", text: m.nombre)
                            .accessibilityLabel("Nombre del modelo")
                        campoMeta(m, etiqueta: "Meta de \(fila.nombre.isEmpty ? "este modelo" : fila.nombre)")
                    }
                    .frame(minHeight: 44)
                } else if opcionesStock.isEmpty {
                    Text("Primero crea productos en la pestaña Productos.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                } else {
                    HStack(spacing: 12) {
                        Picker("Producto", selection: m.opcionId) {
                            Text("Elige un producto").tag(Int?.none)
                            ForEach(opcionesStock) { o in
                                Text("\(o.nombre) · \(Formato.saldo(o.saldo, ceroLargo: true))").tag(Int?.some(o.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Producto del stock")
                        campoMeta(m, etiqueta: "Cantidad del stock")
                    }
                    .frame(minHeight: 44)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func cargarProductos() async {
        guard let nuevos = try? await ClienteAPI.compartido.productos() else { return }
        productos = nuevos
        Almacen.guardarProductos(nuevos)
    }

    /// El cuerpo para crear el modelo de una fila nueva, de una u otra forma.
    private func modeloNuevo(_ fila: FilaModelo) -> ModeloNuevo {
        let meta = metaValida(fila.meta) ?? 1
        if fila.delStock, let opcionId = fila.opcionId {
            return ModeloNuevo(nombre: nil, meta: meta, opcionId: opcionId)
        }
        return ModeloNuevo(nombre: limpio(fila.nombre), meta: meta)
    }

    // MARK: - Guardar

    private func guardar() async {
        guard problema == nil else { return }
        guardando = true
        fallo = nil
        defer { guardando = false }
        do {
            let resultado: PedidoDetalle
            if let d = editando {
                resultado = try await guardarCambios(d)
            } else {
                let nuevo = PedidoNuevo(
                    nombre: limpio(nombre),
                    cliente: limpio(cliente).isEmpty ? nil : limpio(cliente),
                    entrega: conFecha ? Fechas.textoDia(entrega) : nil,
                    nota: nil,
                    modelos: modelos.map { modeloNuevo($0) })
                resultado = try await ClienteAPI.compartido.crearPedido(nuevo)
            }
            alGuardar(resultado)
            cerrar()
        } catch {
            fallo = error.textoParaMostrar
            if let d = editando { await recargarTrasFallo(d) }
        }
    }

    /// Un paso pudo quedar hecho en el servidor aunque la respuesta no llegó
    /// (timeout): se pregunta cómo quedó para que el reintento no lo repita.
    private func recargarTrasFallo(_ d: PedidoDetalle) async {
        guard let fresco = try? await ClienteAPI.compartido.pedido(id: d.id) else { return }
        let conocidos = Set(originales.map { $0.id })
        var adoptados = Set<Int>()
        for nuevo in fresco.modelos where !conocidos.contains(nuevo.id) {
            // Los del stock se reconocen por su opción (el nombre lo puso el servidor).
            if let i = modelos.firstIndex(where: { fila in
                guard fila.existenteId == nil else { return false }
                if fila.delStock { return nuevo.opcionId != nil && fila.opcionId == nuevo.opcionId }
                return nuevo.opcionId == nil && limpio(fila.nombre) == nuevo.nombre
            }) {
                modelos[i].existenteId = nuevo.id
                modelos[i].hechas = nuevo.hechas
                if let stock = nuevo.delStock { modelos[i].nombre = stock.nombre }
                adoptados.insert(nuevo.id)
            }
        }
        // Un modelo que alguien agregó desde la web no entra: si entrara, el
        // reintento lo borraría por no estar en la lista.
        originales = fresco.modelos.filter { conocidos.contains($0.id) || adoptados.contains($0.id) }
    }

    /// Primero los modelos (quitar, cambiar, agregar) y al final el pedido,
    /// que devuelve el detalle ya con todo.
    private func guardarCambios(_ d: PedidoDetalle) async throws -> PedidoDetalle {
        let api = ClienteAPI.compartido
        let quedan = Set(modelos.compactMap { $0.existenteId })
        for viejo in originales where !quedan.contains(viejo.id) {
            do {
                try await api.borrarModelo(id: viejo.id)
            } catch ErrorAPI.noExiste {
                // Ya estaba borrado (un intento anterior o desde la web).
            }
            originales.removeAll { $0.id == viejo.id }
        }
        for fila in modelos {
            let nm = limpio(fila.nombre)
            let meta = metaValida(fila.meta) ?? 1
            if let id = fila.existenteId {
                guard let antes = originales.first(where: { $0.id == id }) else { continue }
                var cambios = CambiosModelo()
                // En uno del stock el nombre que se ve es el de la opción: no se manda.
                if !fila.delStock && nm != antes.nombre { cambios.nombre = nm }
                if meta != antes.meta { cambios.meta = meta }
                if cambios.nombre != nil || cambios.meta != nil {
                    let nuevo = try await api.editarModelo(id: id, cambios)
                    if let k = originales.firstIndex(where: { $0.id == id }) { originales[k] = nuevo }
                }
            } else {
                let nuevo = try await api.agregarModelo(pedidoId: d.id, modeloNuevo(fila))
                originales.append(nuevo)
                if let i = modelos.firstIndex(where: { $0.id == fila.id }) {
                    modelos[i].existenteId = nuevo.id
                    if let stock = nuevo.delStock { modelos[i].nombre = stock.nombre }
                }
            }
        }

        var cambios = CambiosPedido()
        let n = limpio(nombre)
        if n != d.nombre { cambios.nombre = n }
        let c = limpio(cliente)
        if c != (d.cliente ?? "") { cambios.cliente = c.isEmpty ? .borrar : .poner(c) }
        let nuevaEntrega: String? = conFecha ? Fechas.textoDia(entrega) : nil
        if nuevaEntrega != d.entrega {
            if let nuevaEntrega {
                cambios.entrega = .poner(nuevaEntrega)
            } else {
                cambios.entrega = .borrar
            }
        }
        return try await api.editarPedido(id: d.id, cambios)
    }
}

#Preview("Nuevo pedido") {
    NuevoPedidoVista(editando: nil) { _ in }
}

#Preview("Editar, oscuro") {
    NuevoPedidoVista(editando: Muestras.detalle) { _ in }
        .preferredColorScheme(.dark)
}
