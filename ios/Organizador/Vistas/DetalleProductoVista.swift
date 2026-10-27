// Detalle de un producto (maqueta Producto): cada opción con su saldo, "− Venta"
// que resta una al momento y "+ Tanda" que abre la hoja, y los últimos
// movimientos, que se tocan para corregirlos.
import SwiftUI
import PhotosUI
import UIKit

struct DetalleProductoVista: View {
    let productoId: Int
    /// Lo que ya se sabe por la lista: el título aparece antes de que cargue.
    let resumen: ProductoResumen?
    /// Para que la lista quede al día al volver.
    let alCambiar: (ProductoResumen) -> Void

    @State private var detalle: ProductoDetalle?
    @State private var cargando = false
    @State private var mensaje: String? = nil
    @State private var hoja: HojaAnotar? = nil
    @State private var editando = false
    @State private var editandoMovimiento: Movimiento? = nil
    /// Una venta de un pedido que se tocó: no se edita aquí, se explica.
    @State private var ventaDePedido: Movimiento? = nil
    /// Ventas de un toque que todavía esperan respuesta: ya se ven restadas.
    @State private var enVuelo: [TandaPendiente] = []
    /// Sube con cada venta o tanda guardada: dispara la háptica de éxito.
    @State private var guardadas = 0
    /// Sube cuando el servidor rechaza una venta de un toque: háptica de error.
    @State private var rechazadas = 0
    @State private var eleccionFoto: PhotosPickerItem? = nil
    @State private var subiendoFoto = false

    @Environment(Envios.self) private var envios
    @Environment(\.dynamicTypeSize) private var tamanoLetra

    private struct HojaAnotar: Identifiable {
        let id = UUID()
        let opcionId: Int
        let tipo: TipoMovimiento
    }

    init(productoId: Int, resumen: ProductoResumen? = nil, alCambiar: @escaping (ProductoResumen) -> Void = { _ in }) {
        self.productoId = productoId
        self.resumen = resumen
        self.alCambiar = alCambiar
        // Lo guardado se muestra de una vez (y sin señal es lo único que hay).
        _detalle = State(initialValue: Almacen.producto(id: productoId))
    }

    /// Lo del servidor más lo que espera en la cola o en camino.
    private var visto: ProductoDetalle? {
        detalle?.conPendientes(envios.pendientes + enVuelo)
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
                if let d = visto {
                    encabezado(d)
                    seccionOpciones(d)
                    seccionMovimientos(d)
                } else if cargando {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    ContentUnavailableView("No se pudo abrir el producto", systemImage: "wifi.exclamationmark",
                                           description: Text("Desliza hacia abajo para intentarlo de nuevo."))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(detalle?.nombre ?? resumen?.nombre ?? "Producto")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editando = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Editar producto")
                .disabled(detalle == nil)
            }
        }
        .refreshable { await cargar() }
        .task { await cargar() }
        .onChange(of: envios.enviadas) { Task { await cargar() } }
        .onChange(of: eleccionFoto) { _, nueva in
            guard let nueva else { return }
            Task { await subirFoto(nueva) }
        }
        .sensoryFeedback(.success, trigger: guardadas)
        .sensoryFeedback(.error, trigger: rechazadas)
        .sheet(item: $hoja) { h in
            if let d = visto {
                AnotarMovimientoVista(detalle: d, opcionInicial: h.opcionId, tipoInicial: h.tipo) { enCola in
                    guardadas += 1
                    if !enCola { Task { await cargar() } }
                }
            }
        }
        .sheet(isPresented: $editando) {
            if let d = detalle {
                NuevoProductoVista(editando: d) { nuevo in
                    guardar(nuevo)
                }
            }
        }
        .sheet(item: $editandoMovimiento) { m in
            EditarTandaVista(movimiento: m, alGuardar: { await cargar() }, alBorrar: { await cargar() })
        }
        .alert("Venta de un pedido", isPresented: Binding(
            get: { ventaDePedido != nil },
            set: { if !$0 { ventaDePedido = nil } }
        ), presenting: ventaDePedido) { _ in
            Button("Entendido", role: .cancel) {}
        } message: { m in
            Text("Esta venta es de un pedido (\(m.pedido ?? "sin nombre")): cámbiala desde el pedido.")
        }
    }

    // MARK: - Partes

    private func encabezado(_ d: ProductoDetalle) -> some View {
        HStack(spacing: 14) {
            PhotosPicker(selection: $eleccionFoto, matching: .images) {
                ZStack {
                    MiniaturaModelo(nombre: d.nombre, fotoUrl: d.fotoUrl, indice: 0, lado: 64)
                    if subiendoFoto {
                        ProgressView()
                    }
                }
                .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)
            .disabled(subiendoFoto)
            .accessibilityLabel(d.fotoUrl == nil ? "Agregar foto del producto" : "Cambiar foto del producto")

            VStack(alignment: .leading, spacing: 4) {
                Text(d.nombre)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(Formato.resumenProducto(opciones: d.opciones.count, stock: d.stock, faltan: d.faltan))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func titulo(_ texto: String) -> some View {
        Text(texto)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func seccionOpciones(_ d: ProductoDetalle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            titulo("Opciones")
            VStack(spacing: 0) {
                ForEach(d.opciones) { o in
                    filaOpcion(o, producto: d)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    if o.id != d.opciones.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
            Text("«− Venta» resta una al momento. Para varias, o para una tanda, se abre la hoja.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func filaOpcion(_ o: OpcionProducto, producto d: ProductoDetalle) -> some View {
        // Con letra muy grande, los botones van uno sobre otro.
        let botones = tamanoLetra.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(o.nombre)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                PastillaSaldo(saldo: o.saldo, inicial: true)
            }
            .accessibilityElement(children: .combine)
            botones {
                Button {
                    vender(o, producto: d)
                } label: {
                    Text("− Venta")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Restar una venta de \(o.nombre)")
                .contextMenu {
                    Button {
                        hoja = HojaAnotar(opcionId: o.id, tipo: .venta)
                    } label: {
                        Label("Anotar varias ventas", systemImage: "minus.circle")
                    }
                }
                Button {
                    hoja = HojaAnotar(opcionId: o.id, tipo: .tanda)
                } label: {
                    Text("+ Tanda")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.acentoTexto)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.acento.opacity(0.14), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Anotar tanda de \(o.nombre)")
            }
        }
    }

    private func seccionMovimientos(_ d: ProductoDetalle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                titulo("Movimientos")
                Spacer()
                if !d.movimientos.isEmpty {
                    Text("Toca uno para corregirlo")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if d.movimientos.isEmpty {
                Text("Todavía no hay ventas ni tandas anotadas.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(d.movimientos) { m in
                        filaMovimiento(m)
                        if m.id != d.movimientos.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
            }
        }
    }

    private func filaMovimiento(_ m: Movimiento) -> some View {
        let signo = (m.esVenta ? "−" : "+") + Formato.num(m.cantidad)
        let hora = m.fecha.map { Formato.cuando($0) } ?? ""
        let texto = m.esDePedido ? "\(m.opcion) · Pedido \(m.pedido ?? "")" : "\(m.opcion) · \(m.tipo)"
        return Button {
            if m.esDePedido {
                ventaDePedido = m
            } else {
                editandoMovimiento = m
            }
        } label: {
            HStack(spacing: 12) {
                Text(signo)
                    .font(.body.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(m.esVenta ? Color.primary : Color.completoTexto)
                    .frame(minWidth: 44, alignment: .leading)
                Text(texto)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(hora)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(m.esDePedido ? "\(signo) \(m.opcion), venta del pedido \(m.pedido ?? ""), \(hora)"
                                         : "\(signo) \(m.opcion), \(m.tipo), \(hora)")
        .accessibilityHint(m.esDePedido ? "Se cambia desde el pedido" : "Toca para corregir")
    }

    // MARK: - Acciones

    /// Una venta de un toque: se ve restada al momento y se manda; sin señal
    /// (o con la sesión vencida) queda en la cola, igual que una tanda.
    private func vender(_ o: OpcionProducto, producto d: ProductoDetalle) {
        let movimiento = MovimientoNuevo(opcionId: o.id, tipo: .venta, cantidad: 1, cuando: Date())
        let pendiente = TandaPendiente(idCliente: movimiento.idCliente, modeloId: 0, cantidad: 1,
                                       cuando: movimiento.cuando ?? Date(),
                                       nombreModelo: "\(d.nombre) · \(o.nombre) (venta)",
                                       opcionId: o.id, tipo: TipoMovimiento.venta.rawValue)
        // Se ve restada al momento; la háptica y el aviso esperan a que quede
        // guardada o en la cola.
        enVuelo.append(pendiente)
        mensaje = nil
        let anotada = "Venta anotada. \(o.nombre): \(Formato.saldo(o.saldo - 1, ceroLargo: true))"
        // Se toma ya: si la sesión vence, la vista se va a mitad del envío.
        let cola = envios
        Task {
            // Lo que no es un rechazo del servidor (sin red, sesión vencida, 5xx,
            // 408, 429, cancelada) va a la cola con el mismo id: si sí había
            // llegado, el servidor no la cuenta dos veces.
            var guardada = true
            do {
                _ = try await ClienteAPI.compartido.enviarMovimiento(movimiento)
                await cargar()
            } catch ErrorAPI.sinConexion {
                cola.agregar(pendiente)
            } catch ErrorAPI.sinSesion {
                cola.agregar(pendiente)
            } catch ErrorAPI.temporal {
                cola.agregar(pendiente)
            } catch is CancellationError {
                cola.agregar(pendiente)
            } catch {
                guardada = false
                let texto = error.textoParaMostrar ?? "Inténtalo de nuevo."
                mensaje = "No se anotó la venta: \(texto)"
                rechazadas += 1
                UIAccessibility.post(notification: .announcement, argument: "No se anotó la venta de \(o.nombre). \(texto)")
            }
            if guardada {
                guardadas += 1
                UIAccessibility.post(notification: .announcement, argument: anotada)
            }
            // Después de cargar o de encolar: así la venta nunca se ve dos veces ni desaparece un momento.
            enVuelo.removeAll { $0.idCliente == pendiente.idCliente }
        }
    }

    private func guardar(_ nuevo: ProductoDetalle) {
        detalle = nuevo
        Almacen.guardarProducto(nuevo)
        alCambiar(nuevo.resumen)
    }

    private func cargar() async {
        cargando = true
        defer { cargando = false }
        do {
            guardar(try await ClienteAPI.compartido.producto(id: productoId))
            mensaje = nil
        } catch {
            if let texto = error.textoParaMostrar {
                mensaje = detalle == nil ? texto : "\(texto) Se muestra lo último guardado."
            }
        }
    }

    private func subirFoto(_ item: PhotosPickerItem) async {
        subiendoFoto = true
        defer {
            subiendoFoto = false
            eleccionFoto = nil
        }
        do {
            guard let datos = try await item.loadTransferable(type: Data.self),
                  let jpeg = Fotos.jpegReducido(datos) else {
                mensaje = "No se pudo leer esa foto."
                return
            }
            guardar(try await ClienteAPI.compartido.subirFoto(productoId: productoId, jpeg: jpeg))
        } catch {
            if let texto = error.textoParaMostrar { mensaje = texto }
        }
    }
}
