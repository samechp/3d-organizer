// Hoja de anotar una venta o una tanda de un producto (maqueta AnotarProducto).
// Mismo flujo que AnotarTandaVista: primero sin forzar; si el servidor ve una
// tanda igual hace poco, pregunta "¿Es otra tanda?". Sin señal hace la misma
// pregunta contra lo guardado y deja el movimiento en la cola. Las ventas no se
// preguntan: dos ventas iguales seguidas son normales.
import SwiftUI
import UIKit

struct AnotarMovimientoVista: View {
    /// Con lo pendiente ya sumado: la vista previa parte del saldo que se ve.
    let detalle: ProductoDetalle
    /// enCola: true si quedó en el iPhone esperando señal.
    let alGuardar: (_ enCola: Bool) -> Void

    @Environment(Envios.self) private var envios
    @Environment(\.dismiss) private var cerrar
    @Environment(\.dynamicTypeSize) private var tamanoLetra

    @State private var tipo: TipoMovimiento
    @State private var opcionId: Int
    @State private var textoCantidad: String
    @State private var cuando = Date()
    /// false = "ahora": se manda sin hora y la pone el servidor.
    @State private var horaElegida = false
    @State private var enviando = false
    @State private var fallo: String? = nil
    /// Mientras no cambien los datos se reutiliza su id: un reintento nunca duplica.
    @State private var intento: MovimientoNuevo? = nil
    @State private var aviso: Aviso? = nil
    @FocusState private var escribiendo: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var tamanoCantidad: CGFloat = 56

    private struct Aviso: Identifiable {
        let id = UUID()
        let texto: String
    }

    init(detalle: ProductoDetalle, opcionInicial: Int?, tipoInicial: TipoMovimiento,
         alGuardar: @escaping (_ enCola: Bool) -> Void) {
        self.detalle = detalle
        self.alGuardar = alGuardar
        _tipo = State(initialValue: tipoInicial)
        _opcionId = State(initialValue: opcionInicial ?? detalle.opciones.first?.id ?? 0)
        _textoCantidad = State(initialValue: AnotarMovimientoVista.cantidadInicial(tipoInicial, detalle))
    }

    /// Una venta empieza en 1; una tanda, en la última que se anotó.
    private static func cantidadInicial(_ tipo: TipoMovimiento, _ detalle: ProductoDetalle) -> String {
        if tipo == .venta { return "1" }
        return detalle.movimientos.first { !$0.esVenta }.map { String($0.cantidad) } ?? ""
    }

    private var opcion: OpcionProducto? { detalle.opciones.first { $0.id == opcionId } }

    private var cantidad: Int? {
        guard let n = Int(textoCantidad), (1...100_000).contains(n) else { return nil }
        return n
    }

    /// Venta: 1, 2 y 5. Tanda: las 3 últimas cantidades distintas del producto.
    private var rapidas: [Int] {
        if tipo == .venta { return [1, 2, 5] }
        var vistas: [Int] = []
        for m in detalle.movimientos where !m.esVenta && !vistas.contains(m.cantidad) {
            vistas.append(m.cantidad)
            if vistas.count == 3 { break }
        }
        return vistas
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Picker("Qué anotar", selection: Binding(
                        get: { tipo },
                        set: { nuevo in
                            guard nuevo != tipo else { return }
                            tipo = nuevo
                            textoCantidad = AnotarMovimientoVista.cantidadInicial(nuevo, detalle)
                        }
                    )) {
                        Text("Venta (resta)").tag(TipoMovimiento.venta)
                        Text("Tanda (suma)").tag(TipoMovimiento.tanda)
                    }
                    .pickerStyle(.segmented)
                    seccionOpcion
                    seccionCantidad
                    seccionCuando
                    if let previa = vistaPrevia {
                        Text(previa)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    if let fallo {
                        Label(fallo, systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .interactiveDismissDisabled(enviando)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Anotar").font(.headline)
                        Text(detalle.nombre).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        cerrar()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cerrar")
                    .disabled(enviando)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Listo") { escribiendo = false }
                }
            }
            .botonAbajo {
                BotonPrincipal(titulo: tituloGuardar, cargando: enviando) {
                    guardar(forzar: false)
                }
                .disabled(cantidad == nil || opcion == nil || enviando)
            }
            .alert("¿Es otra tanda?", isPresented: Binding(
                get: { aviso != nil },
                set: { if !$0 { aviso = nil } }
            ), presenting: aviso) { _ in
                Button("Sí, es otra: guardar") {
                    guardar(forzar: true)
                }
                Button("No, ya estaba anotada", role: .cancel) {
                    intento = nil
                    cerrar()
                }
            } message: { a in
                Text(a.texto)
            }
        }
    }

    private var tituloGuardar: String {
        guard let cantidad, let opcion else { return "Escribe cuántas" }
        return "\(tipo == .venta ? "Restar" : "Sumar") \(Formato.num(cantidad)) · \(opcion.nombre)"
    }

    /// "Negro: 8 en stock → 28 en stock".
    private var vistaPrevia: String? {
        guard let cantidad, let opcion else { return nil }
        let despues = opcion.saldo + (tipo == .venta ? -cantidad : cantidad)
        return "\(opcion.nombre): \(Formato.saldo(opcion.saldo, ceroLargo: true)) → "
            + Formato.saldo(despues, ceroLargo: true)
    }

    // MARK: - Secciones

    private func titulo(_ texto: String) -> some View {
        Text(texto)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var seccionOpcion: some View {
        let columnas = Array(repeating: GridItem(.flexible(), spacing: 10),
                             count: tamanoLetra.isAccessibilitySize ? 1 : 2)
        return VStack(alignment: .leading, spacing: 8) {
            titulo("Opción")
            LazyVGrid(columns: columnas, spacing: 10) {
                ForEach(detalle.opciones) { o in
                    botonOpcion(o)
                }
            }
        }
    }

    private func botonOpcion(_ o: OpcionProducto) -> some View {
        let elegida = o.id == opcionId
        let forma = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            opcionId = o.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(o.nombre)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Text(Formato.saldo(o.saldo, inicial: true))
                    .font(.footnote)
                    .foregroundStyle(elegida ? Color.acentoTexto : Color.secondary)
            }
            .foregroundStyle(elegida ? Color.acentoTexto : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(elegida ? Color.acento.opacity(0.14) : Color(.secondarySystemGroupedBackground), in: forma)
            .overlay(forma.strokeBorder(elegida ? Color.acento : Color.clear, lineWidth: 2))
            .contentShape(forma)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(o.nombre), \(Formato.saldo(o.saldo, ceroLargo: true))")
        .accessibilityAddTraits(elegida ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private var seccionCantidad: some View {
        VStack(alignment: .leading, spacing: 12) {
            titulo("Cuántas")
            // − y + del mismo ancho a los lados: el número queda centrado.
            HStack(spacing: 12) {
                botonPaso(icono: "minus", etiqueta: "Una menos") {
                    textoCantidad = String(max(1, (cantidad ?? 1) - 1))
                }
                TextField("0", text: $textoCantidad)
                    .keyboardType(.numberPad)
                    .font(.system(size: tamanoCantidad, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .focused($escribiendo)
                    .accessibilityLabel("Cantidad")
                    .frame(maxWidth: .infinity)
                    .onChange(of: textoCantidad) { _, nuevo in
                        // Solo cifras y como mucho 6 (el tope es 100.000).
                        let limpio = String(nuevo.filter { $0.isASCII && $0.isNumber }.prefix(6))
                        if limpio != nuevo { textoCantidad = limpio }
                    }
                botonPaso(icono: "plus", etiqueta: "Una más") {
                    textoCantidad = String(min(100_000, (cantidad ?? 0) + 1))
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))

            if !rapidas.isEmpty {
                HStack(spacing: 8) {
                    Text("Rápidas:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(rapidas, id: \.self) { n in
                        Button {
                            textoCantidad = String(n)
                        } label: {
                            Text(Formato.num(n))
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .frame(minWidth: 44, minHeight: 44)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Poner \(Formato.num(n))")
                    }
                }
            }
        }
    }

    private func botonPaso(icono: String, etiqueta: String, accion: @escaping () -> Void) -> some View {
        Button(action: accion) {
            Image(systemName: icono)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.acentoTexto)
                .frame(width: 56, height: 56)
                .background(Color.acento.opacity(0.14), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(etiqueta)
    }

    private var seccionCuando: some View {
        VStack(alignment: .leading, spacing: 8) {
            titulo("Fecha y hora")
            HStack(spacing: 12) {
                DatePicker("Fecha y hora", selection: Binding(
                    get: { cuando },
                    set: { cuando = $0; horaElegida = true }
                ), in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                Spacer(minLength: 0)
                if horaElegida {
                    Button("Ahora") {
                        cuando = Date()
                        horaElegida = false
                    }
                    .frame(minHeight: 44)
                    .accessibilityLabel("Volver a la hora de ahora")
                } else {
                    Text("Ahora")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
            .environment(\.timeZone, Fechas.bogota)
        }
    }

    // MARK: - Guardar

    private func guardar(forzar: Bool) {
        guard let cantidad, let opcion, !enviando else { return }
        escribiendo = false
        let hora: Date? = horaElegida ? cuando : nil
        let movimiento: MovimientoNuevo
        if let i = intento, i.opcionId == opcion.id, i.tipo == tipo, i.cantidad == cantidad, i.cuando == hora {
            movimiento = i
        } else {
            movimiento = MovimientoNuevo(opcionId: opcion.id, tipo: tipo, cantidad: cantidad, cuando: hora)
            intento = movimiento
        }
        // Una tanda igual esperando en la cola: el servidor no la conoce todavía.
        if !forzar, tipo == .tanda,
           let enCola = envios.tandaParecida(opcionId: opcion.id, cantidad: cantidad, cuando: hora ?? Date()) {
            let minutos = Int(abs((hora ?? Date()).timeIntervalSince(enCola.cuando)) / 60)
            aviso = Aviso(texto: textoAviso(cantidad: cantidad, opcion: opcion.nombre,
                                            previa: enCola.cuando, minutos: minutos))
            return
        }
        let cola = envios
        enviando = true
        fallo = nil
        Task {
            defer { enviando = false }
            do {
                switch try await ClienteAPI.compartido.enviarMovimiento(movimiento, forzar: forzar) {
                case .guardado:
                    listo(movimiento, opcion: opcion.nombre, enCola: false)
                case .parecida(let p):
                    aviso = Aviso(texto: textoAviso(cantidad: p.cantidad, opcion: opcion.nombre,
                                                    previa: p.fecha, minutos: p.haceMinutos))
                }
            } catch is CancellationError {
                // La hoja se cerró: nada que mostrar.
            } catch ErrorAPI.sinConexion {
                sinSenal(movimiento, opcion: opcion, forzar: forzar, cola: cola)
            } catch ErrorAPI.sinSesion {
                // La hoja se va con la sesión: sin preguntar, a la cola.
                encolar(movimiento, opcion: opcion.nombre, cola: cola)
                listo(movimiento, opcion: opcion.nombre, enCola: true)
            } catch {
                fallo = error.textoParaMostrar
            }
        }
    }

    /// Sin servidor: la misma pregunta que haría él, contra los movimientos
    /// guardados y la cola. Lo que entra a la cola se manda con forzar: true.
    private func sinSenal(_ m: MovimientoNuevo, opcion: OpcionProducto, forzar: Bool, cola: Envios) {
        let momento = m.cuando ?? Date()
        if !forzar, m.tipo == .tanda,
           let previa = parecidaLocal(opcionId: opcion.id, cantidad: m.cantidad, cuando: momento, cola: cola) {
            let minutos = Int(abs(momento.timeIntervalSince(previa)) / 60)
            aviso = Aviso(texto: textoAviso(cantidad: m.cantidad, opcion: opcion.nombre,
                                            previa: previa, minutos: minutos))
            return
        }
        encolar(m, opcion: opcion.nombre, cola: cola)
        listo(m, opcion: opcion.nombre, enCola: true)
    }

    /// La hora queda fija desde ahora (si no, el servidor pondría la de cuando vuelva la señal).
    private func encolar(_ m: MovimientoNuevo, opcion: String, cola: Envios) {
        cola.agregar(TandaPendiente(idCliente: m.idCliente, modeloId: 0, cantidad: m.cantidad,
                                    cuando: m.cuando ?? Date(),
                                    nombreModelo: "\(detalle.nombre) · \(opcion) (\(m.tipo.rawValue))",
                                    opcionId: m.opcionId, tipo: m.tipo.rawValue))
    }

    /// La hora de la tanda parecida más reciente de esa opción, si hay.
    private func parecidaLocal(opcionId: Int, cantidad: Int, cuando: Date, cola: Envios) -> Date? {
        let guardada = detalle.movimientos.first { m in
            guard m.opcionId == opcionId, !m.esVenta, let fecha = m.fecha else { return false }
            return ReglaParecida.esParecida(cantidad: cantidad, cuando: cuando,
                                            otraCantidad: m.cantidad, otroCuando: fecha)
        }?.fecha
        let enCola = cola.tandaParecida(opcionId: opcionId, cantidad: cantidad, cuando: cuando)?.cuando
        switch (guardada, enCola) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// "Hace 40 minutos ya anotaste una tanda de 20 de Negro (hoy, 3:02 p. m.)."
    private func textoAviso(cantidad: Int, opcion: String, previa: Date?, minutos: Int) -> String {
        let cuandoPrevia = previa.map { " (\(Formato.dia($0).lowercased()), \(Formato.hora($0)))" } ?? ""
        let que = "una tanda de \(Formato.num(cantidad)) de \(opcion)"
        if horaElegida {
            return "Ya anotaste \(que) a \(Formato.duracion(minutos: minutos)) de la hora que pusiste\(cuandoPrevia)."
        }
        return "Hace \(Formato.duracion(minutos: minutos)) ya anotaste \(que)\(cuandoPrevia)."
    }

    private func listo(_ m: MovimientoNuevo, opcion: String, enCola: Bool) {
        intento = nil
        let que = m.tipo == .venta ? "Venta anotada" : "Tanda anotada"
        let texto = enCola
            ? "Sin señal: quedó en el iPhone y se envía sola cuando vuelva la señal."
            : "\(que): \(Formato.num(m.cantidad)) de \(opcion)"
        UIAccessibility.post(notification: .announcement, argument: texto)
        alGuardar(enCola)
        cerrar()
    }
}
