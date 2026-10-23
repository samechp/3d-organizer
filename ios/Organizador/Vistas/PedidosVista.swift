// Pestaña Pedidos (maqueta Main): abiertos y terminados, cada uno con su
// avance y su ritmo. Sin señal se muestra la última lista guardada.
import SwiftUI

struct PedidosVista: View {
    @State private var pedidos: [PedidoResumen] = Almacen.pedidos() ?? []
    @State private var verTerminados = false
    @State private var cargando = false
    @State private var cargadoUnaVez = false
    @State private var mensaje: String? = nil
    @State private var creando = false
    @State private var camino: [Ruta] = []

    @Environment(Envios.self) private var envios

    private var abiertos: [PedidoResumen] { pedidos.filter { $0.estado == .abierto } }
    private var terminados: [PedidoResumen] { pedidos.filter { $0.estado == .terminado } }

    var body: some View {
        NavigationStack(path: $camino) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    FranjaEnvios()

                    Picker("Filtrar pedidos", selection: $verTerminados) {
                        Text("Abiertos · \(Formato.num(abiertos.count))").tag(false)
                        Text("Terminados · \(Formato.num(terminados.count))").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if let mensaje {
                        Label(mensaje, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if verTerminados {
                        listaTerminados
                    } else {
                        listaAbiertos
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Pedidos")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creando = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Nuevo pedido")
                }
            }
            .refreshable { await cargar() }
            .task { await cargar() }
            .onChange(of: envios.enviadas) { Task { await cargar() } }
            .navigationDestination(for: Ruta.self) { ruta in
                switch ruta {
                case .detalle(let id):
                    DetallePedidoVista(pedidoId: id, resumen: pedidos.first { $0.id == id })
                case .historial(let id):
                    HistorialVista(pedidoId: id)
                }
            }
            .sheet(isPresented: $creando) {
                NuevoPedidoVista(editando: nil) { creado in
                    Task { await cargar() }
                    camino.append(.detalle(creado.id))
                }
            }
        }
    }

    @ViewBuilder
    private var listaAbiertos: some View {
        if abiertos.isEmpty && cargadoUnaVez {
            ContentUnavailableView {
                Label("Sin pedidos abiertos", systemImage: "shippingbox")
            } description: {
                Text("Toca + para crear uno.")
            }
            .padding(.top, 40)
        } else if abiertos.isEmpty && cargando {
            ProgressView().padding(.top, 40)
        } else {
            ForEach(abiertos) { p in
                NavigationLink(value: Ruta.detalle(p.id)) {
                    TarjetaPedido(pedido: p)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var listaTerminados: some View {
        if terminados.isEmpty {
            ContentUnavailableView {
                Label("Sin pedidos terminados", systemImage: "checkmark.seal")
            } description: {
                Text("Aquí aparecen los pedidos que marques como terminados.")
            }
            .padding(.top, 40)
        } else {
            VStack(spacing: 0) {
                ForEach(terminados) { p in
                    NavigationLink(value: Ruta.detalle(p.id)) {
                        HStack(spacing: 12) {
                            Text(p.nombre)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Formato.num(p.avance.hechasTotal))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(p.nombre), \(Formato.num(p.avance.hechasTotal)) piezas, terminado")
                    .accessibilityAddTraits(.isButton)
                    if p.id != terminados.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
        }
    }

    private func cargar() async {
        cargando = true
        defer { cargando = false }
        do {
            let nuevos = try await ClienteAPI.compartido.pedidos()
            pedidos = nuevos
            Almacen.guardarPedidos(nuevos)
            mensaje = nil
            cargadoUnaVez = true
        } catch is CancellationError {
            // La vista se fue o se volvió a cargar: nada que mostrar.
        } catch {
            if let texto = error.textoParaMostrar {
                mensaje = pedidos.isEmpty ? texto : "\(texto) Se muestra lo último guardado."
            }
            cargadoUnaVez = true
        }
    }
}

/// Tarjeta de un pedido abierto: nombre, cliente, barra y ritmo.
struct TarjetaPedido: View {
    let pedido: PedidoResumen

    private var subtitulo: String {
        let modelos = "\(Formato.num(pedido.numModelos)) \(Formato.plural(pedido.numModelos, "modelo", "modelos"))"
        if let cliente = pedido.cliente, !cliente.isEmpty { return "\(cliente) · \(modelos)" }
        return modelos
    }

    private var etiquetaVoiceOver: String {
        let av = pedido.avance
        var partes = [pedido.nombre,
                      "\(Formato.num(av.contadas)) de \(Formato.num(av.metaTotal))",
                      "\(av.porcentaje) por ciento"]
        if pedido.estado == .abierto {
            if let larga = Formato.entregaLarga(pedido.entrega) {
                partes.append("entrega \(larga)")
            } else {
                partes.append("sin fecha de entrega")
            }
        }
        if let r = pedido.ritmo {
            if r.estaVencido { partes.append("vencido") }
            if let porDia = r.porDia { partes.append("\(Formato.num(porDia)) al día") }
        }
        return partes.joined(separator: ", ")
    }

    var body: some View {
        let av = pedido.avance
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pedido.nombre)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitulo)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            BarraAvance(fraccion: av.metaTotal > 0 ? Double(av.contadas) / Double(av.metaTotal) : 0,
                        completo: av.faltan <= 0)
            HStack {
                Text("\(Formato.num(av.contadas)) de \(Formato.num(av.metaTotal))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(av.porcentaje) %")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let ritmo = Formato.pastillaRitmo(pedido) {
                if pedido.ritmo == nil {
                    // "Sin fecha de entrega" va como texto suelto, no como pastilla.
                    Text(ritmo.texto)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    PastillaRitmo(texto: ritmo.texto, tono: ritmo.tono)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(etiquetaVoiceOver)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("Tarjeta, claro y oscuro") {
    VStack(spacing: 14) {
        TarjetaPedido(pedido: Muestras.resumen)
        TarjetaPedido(pedido: Muestras.resumen)
            .environment(\.colorScheme, .dark)
        TarjetaPedido(pedido: Muestras.resumen)
            .environment(\.dynamicTypeSize, .accessibility2)
    }
    .padding()
}
