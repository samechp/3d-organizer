// Pestaña Productos (maqueta Productos): lo que falta imprimir de todos los
// productos, ordenado por cuánto falta, y la lista de productos con el saldo
// de cada opción. Sin señal se muestra la última lista guardada, con lo que
// espera en la cola ya sumado o restado.
import SwiftUI

extension Formato {
    /// "8 en stock", "faltan 3" (o "Faltan 3") y "0" (o "0 en stock").
    static func saldo(_ n: Int, inicial: Bool = false, ceroLargo: Bool = false) -> String {
        if n > 0 { return "\(num(n)) en stock" }
        if n < 0 { return "\(inicial ? "Faltan" : "faltan") \(num(-n))" }
        return ceroLargo ? "0 en stock" : "0"
    }

    /// "3 opciones · 10 en stock · faltan 3".
    static func resumenProducto(opciones: Int, stock: Int, faltan: Int) -> String {
        var partes = ["\(num(opciones)) \(plural(opciones, "opción", "opciones"))"]
        if stock > 0 { partes.append("\(num(stock)) en stock") }
        if faltan > 0 { partes.append("faltan \(num(faltan))") }
        return partes.joined(separator: " · ")
    }
}

/// Pastilla del saldo: verde con stock, naranja si falta, gris en 0.
struct PastillaSaldo: View {
    /// Con nombre: "Negro · 8 en stock"; sin nombre: "8 en stock".
    var nombre: String? = nil
    let saldo: Int
    var inicial = false

    private var color: Color {
        if saldo > 0 { return .completoTexto }
        if saldo < 0 { return .acentoTexto }
        return .secondary
    }

    private var fondo: Color {
        if saldo > 0 { return Color.completo.opacity(0.14) }
        if saldo < 0 { return Color.acento.opacity(0.14) }
        return Color(.systemFill)
    }

    var body: some View {
        let texto = Formato.saldo(saldo, inicial: inicial && nombre == nil)
        Text(nombre.map { "\($0) · \(texto)" } ?? texto)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(fondo, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel((nombre.map { "\($0), " } ?? "") + Formato.saldo(saldo, ceroLargo: true))
    }
}

struct ProductosVista: View {
    @State private var productos: [ProductoResumen] = Almacen.productos() ?? []
    @State private var cargando = false
    @State private var cargadoUnaVez = false
    @State private var mensaje: String? = nil
    @State private var creando = false
    @State private var camino: [Int] = []

    @Environment(Envios.self) private var envios

    private struct Faltante: Identifiable {
        /// Id de la opción.
        let id: Int
        let productoId: Int
        let producto: String
        let opcion: String
        let faltan: Int
    }

    /// Lo del servidor más lo que espera en la cola.
    private var vistos: [ProductoResumen] {
        productos.map { $0.conPendientes(envios.pendientes) }
    }

    private func porImprimir(_ lista: [ProductoResumen]) -> [Faltante] {
        lista.flatMap { p in
            p.opciones.filter { $0.saldo < 0 }.map {
                Faltante(id: $0.id, productoId: p.id, producto: p.nombre, opcion: $0.nombre, faltan: -$0.saldo)
            }
        }
        .sorted { $0.faltan > $1.faltan }
    }

    var body: some View {
        let lista = vistos
        let faltantes = porImprimir(lista)
        NavigationStack(path: $camino) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    FranjaEnvios()

                    if let mensaje {
                        Label(mensaje, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !faltantes.isEmpty {
                        seccionPorImprimir(faltantes)
                    }

                    seccionProductos(lista)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Productos")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creando = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Nuevo producto")
                }
            }
            .refreshable { await cargar() }
            .task { await cargar() }
            .onChange(of: envios.enviadas) { Task { await cargar() } }
            .navigationDestination(for: Int.self) { id in
                DetalleProductoVista(productoId: id, resumen: productos.first { $0.id == id }) { nuevo in
                    actualizar(nuevo)
                }
            }
            .sheet(isPresented: $creando) {
                NuevoProductoVista(editando: nil) { creado in
                    Almacen.guardarProducto(creado)
                    actualizar(creado.resumen)
                    camino.append(creado.id)
                }
            }
        }
    }

    private func encabezado(_ texto: String) -> some View {
        Text(texto)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func seccionPorImprimir(_ faltantes: [Faltante]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            encabezado("Por imprimir")
            VStack(spacing: 0) {
                ForEach(faltantes) { f in
                    NavigationLink(value: f.productoId) {
                        HStack(spacing: 12) {
                            Text("\(f.producto) · \(f.opcion)")
                                .font(.body)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            PastillaSaldo(saldo: -f.faltan, inicial: true)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(f.producto) \(f.opcion), faltan \(Formato.num(f.faltan))")
                    .accessibilityAddTraits(.isButton)
                    if f.id != faltantes.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
        }
    }

    @ViewBuilder
    private func seccionProductos(_ lista: [ProductoResumen]) -> some View {
        if lista.isEmpty && cargadoUnaVez {
            ContentUnavailableView {
                Label("Sin productos", systemImage: "bag")
            } description: {
                Text("Toca + para crear uno.")
            }
            .padding(.top, 40)
        } else if lista.isEmpty && cargando {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            encabezado("Todos los productos")
            ForEach(Array(lista.enumerated()), id: \.element.id) { i, p in
                NavigationLink(value: p.id) {
                    TarjetaProducto(producto: p, indice: i)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func actualizar(_ nuevo: ProductoResumen) {
        if let i = productos.firstIndex(where: { $0.id == nuevo.id }) {
            productos[i] = nuevo
        } else {
            productos.append(nuevo)
            productos.sort { $0.nombre.localizedCaseInsensitiveCompare($1.nombre) == .orderedAscending }
        }
        Almacen.guardarProductos(productos)
    }

    private func cargar() async {
        cargando = true
        defer { cargando = false }
        do {
            let nuevos = try await ClienteAPI.compartido.productos()
            productos = nuevos
            Almacen.guardarProductos(nuevos)
            mensaje = nil
            cargadoUnaVez = true
        } catch is CancellationError {
            // La vista se fue o se volvió a cargar: nada que mostrar.
        } catch {
            if let texto = error.textoParaMostrar {
                mensaje = productos.isEmpty ? texto : "\(texto) Se muestra lo último guardado."
            }
            cargadoUnaVez = true
        }
    }
}

/// Tarjeta de un producto: foto, nombre, totales y una pastilla por opción.
struct TarjetaProducto: View {
    let producto: ProductoResumen
    let indice: Int

    @ScaledMetric(relativeTo: .subheadline) private var anchoPastilla: CGFloat = 130

    private var etiquetaVoiceOver: String {
        let opciones = producto.opciones.map { "\($0.nombre) \(Formato.saldo($0.saldo, ceroLargo: true))" }
        return ([producto.nombre] + opciones).joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MiniaturaModelo(nombre: producto.nombre, fotoUrl: producto.fotoUrl, indice: indice)
                VStack(alignment: .leading, spacing: 2) {
                    Text(producto.nombre)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(Formato.resumenProducto(opciones: producto.opciones.count,
                                                 stock: producto.stock, faltan: producto.faltan))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            if !producto.opciones.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: anchoPastilla), spacing: 8, alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(producto.opciones) { o in
                        PastillaSaldo(nombre: o.nombre, saldo: o.saldo)
                    }
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
