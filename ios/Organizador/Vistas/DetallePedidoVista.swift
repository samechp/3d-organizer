// Detalle de un pedido (maqueta Detalle): avance, ritmo, cada modelo con su
// foto y sus números, y las últimas tandas. Desde aquí se anota.
import SwiftUI
import PhotosUI
import UIKit

struct DetallePedidoVista: View {
    let pedidoId: Int
    /// Lo que ya se sabe por la lista: el título aparece antes de que cargue.
    let resumen: PedidoResumen?

    @State private var detalle: PedidoDetalle?
    @State private var tandas: [Tanda]
    @State private var cargando = false
    @State private var mensaje: String? = nil
    @State private var hoja: HojaAnotar? = nil
    @State private var editando = false
    /// La tanda de "Últimas tandas" que se está corrigiendo.
    @State private var editandoTanda: Tanda? = nil
    @State private var confirmarTerminar = false
    @State private var cambiandoEstado = false
    /// Sube con cada tanda guardada: dispara la háptica de éxito.
    @State private var guardadas = 0

    @Environment(Envios.self) private var envios

    private struct HojaAnotar: Identifiable {
        let id = UUID()
        let modeloId: Int?
    }

    init(pedidoId: Int, resumen: PedidoResumen? = nil, detalle: PedidoDetalle? = nil) {
        self.pedidoId = pedidoId
        self.resumen = resumen
        // Lo guardado se muestra de una vez (y sin señal es lo único que hay).
        _detalle = State(initialValue: detalle ?? Almacen.detalle(id: pedidoId))
        _tandas = State(initialValue: Almacen.tandas(pedidoId: pedidoId))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FranjaEnvios()
                if let mensaje {
                    Label(mensaje, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let d = detalle {
                    encabezado(d)
                    tarjetaAvance(d)
                    seccionModelos(d)
                    seccionTandas(d)
                } else if cargando {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    ContentUnavailableView("No se pudo abrir el pedido", systemImage: "wifi.exclamationmark",
                                           description: Text("Desliza hacia abajo para intentarlo de nuevo."))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(detalle?.nombre ?? resumen?.nombre ?? "Pedido")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                NavigationLink(value: Ruta.historial(pedidoId)) {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Historial de tandas")
                menu
            }
        }
        .botonAbajo {
            BotonPrincipal(titulo: "Anotar tanda", icono: "plus") {
                hoja = HojaAnotar(modeloId: modeloSugerido())
            }
            // Los del stock no llevan tandas: sin ningún otro, no hay qué anotar.
            .disabled(!(detalle?.modelos.contains(where: { !$0.esDelStock }) ?? false))
        }
        .refreshable { await cargar() }
        .task { await cargar() }
        .onChange(of: envios.enviadas) { Task { await cargar() } }
        .sensoryFeedback(.success, trigger: guardadas)
        .sheet(item: $hoja) { h in
            if let d = detalle {
                AnotarTandaVista(detalle: d, modeloInicial: h.modeloId, tandas: tandas) { enCola in
                    guardadas += 1
                    if !enCola { Task { await cargar() } }
                }
            }
        }
        .sheet(isPresented: $editando) {
            if let d = detalle {
                NuevoPedidoVista(editando: d) { nuevo in
                    detalle = nuevo
                    Almacen.guardarDetalle(nuevo)
                }
            }
        }
        // Al guardar o borrar se recarga el pedido para que el avance cambie.
        .sheet(item: $editandoTanda) { t in
            EditarTandaVista(tanda: t, alGuardar: { await cargar() }, alBorrar: { await cargar() })
        }
        .confirmationDialog("¿Marcar el pedido como terminado?", isPresented: $confirmarTerminar,
                            titleVisibility: .visible) {
            Button("Marcar terminado") {
                Task { await cambiarEstado(.terminado) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Todavía faltan \(Formato.num(detalle?.avance.faltan ?? 0)) piezas.")
        }
    }

    // MARK: - Partes

    private var menu: some View {
        Menu {
            Button {
                editando = true
            } label: {
                Label("Editar pedido", systemImage: "pencil")
            }
            if detalle?.estado == .terminado {
                Button {
                    Task { await cambiarEstado(.abierto) }
                } label: {
                    Label("Reabrir", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button {
                    if (detalle?.avance.faltan ?? 0) > 0 {
                        confirmarTerminar = true
                    } else {
                        Task { await cambiarEstado(.terminado) }
                    }
                } label: {
                    Label("Marcar terminado", systemImage: "checkmark.seal")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Más opciones")
        .disabled(detalle == nil || cambiandoEstado)
    }

    private func encabezado(_ d: PedidoDetalle) -> some View {
        var partes: [String] = []
        if let cliente = d.cliente, !cliente.isEmpty { partes.append(cliente) }
        if d.estado == .terminado {
            partes.append("Terminado")
        } else if let entrega = Formato.entrega(d.entrega, conAnio: true) {
            partes.append("Entrega \(entrega)")
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(d.nombre)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            if !partes.isEmpty {
                Text(partes.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let nota = d.nota, !nota.isEmpty {
                Text(nota)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tarjetaAvance(_ d: PedidoDetalle) -> some View {
        let av = d.avance
        let ritmo = Formato.lineaRitmo(d)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Formato.num(av.contadas)) de \(Formato.num(av.metaTotal))")
                    .font(.title2.bold())
                Spacer()
                Text("\(av.porcentaje) %")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(av.faltan <= 0 ? Color.completoTexto : Color.secondary)
            }
            BarraAvance(fraccion: av.metaTotal > 0 ? Double(av.contadas) / Double(av.metaTotal) : 0,
                        completo: av.faltan <= 0, alto: 10)
            if let ritmo {
                Text(ritmo.texto)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colorDeTono(ritmo.tono))
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Avance del pedido: \(Formato.num(av.contadas)) de \(Formato.num(av.metaTotal)), "
                            + "\(av.porcentaje) por ciento" + (ritmo.map { ". \($0.texto)" } ?? ""))
    }

    private func colorDeTono(_ tono: Formato.Tono) -> Color {
        switch tono {
        case .normal: return .primary
        case .vencido: return .red
        case .completo: return .completoTexto
        }
    }

    private func seccionModelos(_ d: PedidoDetalle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Modelos")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(d.modelos.enumerated()), id: \.element.id) { i, m in
                    FilaModelo(modelo: m, indice: i, anotar: {
                        hoja = HojaAnotar(modeloId: m.id)
                    }, fotoSubida: {
                        Task { await cargar() }
                    })
                    .padding(.horizontal, 16)
                    if i < d.modelos.count - 1 {
                        Divider().padding(.leading, 72)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
            Text(!d.modelos.isEmpty && d.modelos.allSatisfy { $0.esDelStock }
                 ? "Todos los modelos salen del stock: no llevan tandas. Toca la foto de un modelo para cambiarla."
                 : "Toca la foto de un modelo para cambiarla.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func seccionTandas(_ d: PedidoDetalle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Últimas tandas")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                NavigationLink("Ver todas", value: Ruta.historial(pedidoId))
                    .font(.body)
                    .frame(minHeight: 44)
            }
            if d.ultimasTandas.isEmpty {
                Text("Todavía no hay tandas anotadas.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(d.ultimasTandas) { t in
                        // Tocar la tanda abre la misma hoja de editar que el
                        // Historial: así corregir no depende de saber deslizar.
                        Button {
                            editandoTanda = t
                        } label: {
                            HStack {
                                Text("\(t.modelo) · ") + Text(Formato.num(t.cantidad)).bold()
                                Spacer()
                                Text(t.fecha.map { Formato.cuando($0) } ?? "")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.body)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(Formato.num(t.cantidad)) de \(t.modelo), "
                                            + (t.fecha.map { Formato.cuando($0) } ?? ""))
                        .accessibilityHint("Toca para editar")
                        if t.id != d.ultimasTandas.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
            }
        }
    }

    // MARK: - Acciones

    /// Para el botón de abajo: el modelo de la última tanda (se suele seguir
    /// con el mismo) o, si no hay, el primero que no esté completo.
    private func modeloSugerido() -> Int? {
        guard let d = detalle else { return nil }
        let imprimibles = d.modelos.filter { !$0.esDelStock }
        if let ultima = tandas.first, imprimibles.contains(where: { $0.id == ultima.modeloId }) {
            return ultima.modeloId
        }
        return (imprimibles.first { !$0.completo } ?? imprimibles.first)?.id
    }

    private func cargar() async {
        cargando = true
        defer { cargando = false }
        do {
            async let pedido = ClienteAPI.compartido.pedido(id: pedidoId)
            async let lista = ClienteAPI.compartido.tandas(pedidoId: pedidoId)
            let (nuevo, nuevas) = try await (pedido, lista)
            detalle = nuevo
            tandas = nuevas
            Almacen.guardarDetalle(nuevo)
            Almacen.guardarTandas(nuevas, pedidoId: pedidoId)
            mensaje = nil
        } catch {
            if let texto = error.textoParaMostrar {
                mensaje = detalle == nil ? texto : "\(texto) Se muestra lo último guardado."
            }
        }
    }

    private func cambiarEstado(_ estado: EstadoPedido) async {
        cambiandoEstado = true
        defer { cambiandoEstado = false }
        do {
            let nuevo = try await ClienteAPI.compartido.editarPedido(id: pedidoId, CambiosPedido(estado: estado))
            detalle = nuevo
            Almacen.guardarDetalle(nuevo)
            mensaje = nil
            UIAccessibility.post(notification: .announcement,
                                 argument: estado == .terminado ? "Pedido marcado como terminado" : "Pedido reabierto")
        } catch {
            if let texto = error.textoParaMostrar { mensaje = texto }
        }
    }
}

/// Una fila de modelo: foto (se toca para cambiarla), números y el + para
/// anotar una tanda de ese modelo.
private struct FilaModelo: View {
    let modelo: Modelo
    let indice: Int
    let anotar: () -> Void
    let fotoSubida: () -> Void

    @State private var eleccion: PhotosPickerItem? = nil
    @State private var subiendo = false
    @State private var fallo: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $eleccion, matching: .images) {
                ZStack {
                    MiniaturaModelo(modelo: modelo, indice: indice)
                    if subiendo {
                        ProgressView()
                    }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(subiendo)
            .accessibilityLabel(modelo.fotoUrl == nil ? "Agregar foto de \(modelo.nombre)"
                                                      : "Cambiar foto de \(modelo.nombre)")

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(modelo.nombre)
                        .font(.body.weight(.semibold))
                    Spacer(minLength: 8)
                    Text("\(Formato.num(modelo.hechas)) / \(Formato.num(modelo.meta))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                BarraAvance(fraccion: modelo.meta > 0 ? Double(modelo.hechas) / Double(modelo.meta) : 0,
                            completo: modelo.completo, alto: 6)
                if let stock = modelo.delStock {
                    Text("Del stock: \(stock.nombre)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if stock.saldo < 0 {
                        Label("faltan \(Formato.num(-stock.saldo)) por imprimir en Productos",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.acentoTexto)
                    }
                } else if modelo.esDelStock {
                    Text("Del stock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(Formato.notaModelo(modelo))
                        .font(modelo.completo ? Font.footnote.weight(.semibold) : Font.footnote)
                        .foregroundStyle(modelo.completo ? Color.completoTexto : Color.secondary)
                }
                if let fallo {
                    Text(fallo)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .accessibilityElement(children: .combine)

            // Del stock: sale de Productos, no se imprime por tandas.
            if !modelo.esDelStock {
                Button(action: anotar) {
                    Image(systemName: "plus")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Color.acentoTexto)
                        .frame(width: 44, height: 44)
                        .background(Color.acento.opacity(0.14), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Anotar tanda de \(modelo.nombre)")
            }
        }
        .padding(.vertical, 10)
        .onChange(of: eleccion) { _, nueva in
            guard let nueva else { return }
            Task { await subir(nueva) }
        }
    }

    private func subir(_ item: PhotosPickerItem) async {
        subiendo = true
        fallo = nil
        defer {
            subiendo = false
            eleccion = nil
        }
        do {
            guard let datos = try await item.loadTransferable(type: Data.self),
                  let jpeg = Fotos.jpegReducido(datos) else {
                fallo = "No se pudo leer esa foto."
                return
            }
            _ = try await ClienteAPI.compartido.subirFoto(modeloId: modelo.id, jpeg: jpeg)
            fotoSubida()
        } catch {
            fallo = error.textoParaMostrar
        }
    }
}

#Preview("Detalle") {
    NavigationStack {
        DetallePedidoVista(pedidoId: Muestras.detalle.id, detalle: Muestras.detalle)
    }
    .environment(Envios())
}

#Preview("Detalle oscuro, letra grande") {
    NavigationStack {
        DetallePedidoVista(pedidoId: Muestras.detalle.id, detalle: Muestras.detalle)
    }
    .environment(Envios())
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility1)
}
