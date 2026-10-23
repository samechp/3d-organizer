// Hoja de anotar una tanda (maquetas Anotar y Duplicado). Primero se manda
// sin forzar; si el servidor ve una igual hace poco, pregunta "¿Es otra
// tanda?". Sin señal (o con la sesión vencida) hace la misma pregunta contra
// las tandas guardadas en el iPhone y deja la tanda en la cola.
import SwiftUI
import UIKit

struct AnotarTandaVista: View {
    let detalle: PedidoDetalle
    /// Las del pedido, la más reciente primero: dan las cantidades rápidas y
    /// sirven para "¿ya la anotaste?" sin señal.
    let tandas: [Tanda]
    /// enCola: true si quedó en el iPhone esperando señal.
    let alGuardar: (_ enCola: Bool) -> Void

    @Environment(Envios.self) private var envios
    @Environment(\.dismiss) private var cerrar
    @Environment(\.dynamicTypeSize) private var tamanoLetra

    @State private var modeloId: Int
    @State private var textoCantidad: String
    @State private var cuando = Date()
    /// false = "ahora": se manda sin hora y la pone el servidor.
    @State private var horaElegida = false
    @State private var enviando = false
    @State private var fallo: String? = nil
    /// La tanda que se está intentando: mientras no cambien los datos se
    /// reutiliza su id, así un reintento nunca la duplica.
    @State private var intento: TandaNueva? = nil
    @State private var aviso: Aviso? = nil
    @FocusState private var escribiendo: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var tamanoCantidad: CGFloat = 56

    private struct Aviso: Identifiable {
        let id = UUID()
        let texto: String
    }

    init(detalle: PedidoDetalle, modeloInicial: Int?, tandas: [Tanda],
         alGuardar: @escaping (_ enCola: Bool) -> Void) {
        self.detalle = detalle
        self.tandas = tandas
        self.alGuardar = alGuardar
        _modeloId = State(initialValue: modeloInicial ?? detalle.modelos.first?.id ?? 0)
        // Se empieza con la última cantidad: casi siempre sale lo mismo de la cama.
        _textoCantidad = State(initialValue: tandas.first.map { String($0.cantidad) } ?? "")
    }

    private var modelo: Modelo? { detalle.modelos.first { $0.id == modeloId } }

    /// La cantidad escrita, si es válida para el servidor (1 a 100.000).
    private var cantidad: Int? {
        guard let n = Int(textoCantidad), (1...100_000).contains(n) else { return nil }
        return n
    }

    /// Las 3 últimas cantidades distintas del pedido.
    private var rapidas: [Int] {
        var vistas: [Int] = []
        for t in tandas where !vistas.contains(t.cantidad) {
            vistas.append(t.cantidad)
            if vistas.count == 3 { break }
        }
        return vistas
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    seccionModelo
                    seccionCantidad
                    seccionCuando
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
                        Text("Anotar tanda").font(.headline)
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
                .disabled(cantidad == nil || modelo == nil || enviando)
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
        guard let cantidad, let modelo else { return "Escribe cuántas salieron" }
        return "Guardar \(Formato.num(cantidad)) de \(modelo.nombre)"
    }

    // MARK: - Secciones

    private func titulo(_ texto: String) -> some View {
        Text(texto)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var seccionModelo: some View {
        let columnas = Array(repeating: GridItem(.flexible(), spacing: 10),
                             count: tamanoLetra.isAccessibilitySize ? 1 : 2)
        return VStack(alignment: .leading, spacing: 8) {
            titulo("Modelo")
            LazyVGrid(columns: columnas, spacing: 10) {
                ForEach(detalle.modelos) { m in
                    botonModelo(m)
                }
            }
        }
    }

    private func botonModelo(_ m: Modelo) -> some View {
        let elegido = m.id == modeloId
        let forma = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            modeloId = m.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.nombre)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Text(m.completo ? "Completo" : "Faltan \(Formato.num(m.faltan))")
                    .font(.footnote)
                    .foregroundStyle(elegido ? Color.acentoTexto : Color.secondary)
            }
            .foregroundStyle(elegido ? Color.acentoTexto : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(elegido ? Color.acento.opacity(0.14) : Color(.secondarySystemGroupedBackground), in: forma)
            .overlay(forma.strokeBorder(elegido ? Color.acento : Color.clear, lineWidth: 2))
            .contentShape(forma)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(elegido ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private var seccionCantidad: some View {
        VStack(alignment: .leading, spacing: 12) {
            titulo("Cuántas salieron buenas")
            // − y + del mismo ancho a los lados: el número queda centrado
            // aunque tenga 1 o 6 cifras.
            HStack(spacing: 12) {
                botonPaso(icono: "minus", etiqueta: "Restar una") {
                    let actual = cantidad ?? 1
                    textoCantidad = String(max(1, actual - 1))
                }
                VStack(spacing: 2) {
                    TextField("0", text: $textoCantidad)
                        .keyboardType(.numberPad)
                        .font(.system(size: tamanoCantidad, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                        .focused($escribiendo)
                        .accessibilityLabel("Cantidad")
                        .onChange(of: textoCantidad) { _, nuevo in
                            // Solo cifras y como mucho 6 (el tope es 100.000).
                            let limpio = String(nuevo.filter { $0.isASCII && $0.isNumber }.prefix(6))
                            if limpio != nuevo { textoCantidad = limpio }
                        }
                    Text("toca para escribir")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
                botonPaso(icono: "plus", etiqueta: "Sumar una") {
                    let actual = cantidad ?? 0
                    textoCantidad = String(min(100_000, actual + 1))
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))

            if !rapidas.isEmpty {
                HStack(spacing: 8) {
                    Text("Usadas hace poco:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(rapidas, id: \.self) { n in
                        Button {
                            textoCantidad = String(n)
                        } label: {
                            Text(Formato.num(n))
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
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
            // Las horas se eligen y se muestran como en Bogotá.
            .environment(\.timeZone, Fechas.bogota)
        }
    }

    // MARK: - Guardar

    private func guardar(forzar: Bool) {
        guard let cantidad, let modelo, !enviando else { return }
        escribiendo = false
        let hora: Date? = horaElegida ? cuando : nil
        let tanda: TandaNueva
        if let i = intento, i.modeloId == modelo.id, i.cantidad == cantidad, i.cuando == hora {
            tanda = i
        } else {
            tanda = TandaNueva(modeloId: modelo.id, cantidad: cantidad, cuando: hora)
            intento = tanda
        }
        // Una igual esperando en la cola: el servidor todavía no la conoce y no
        // la detectaría, así que se pregunta aquí.
        if !forzar, let enCola = envios.pendienteParecida(modeloId: modelo.id, cantidad: cantidad,
                                                           cuando: hora ?? Date()) {
            let minutos = Int(abs((hora ?? Date()).timeIntervalSince(enCola.cuando)) / 60)
            aviso = Aviso(texto: textoAviso(cantidad: cantidad, modelo: modelo.nombre,
                                            previa: enCola.cuando, minutos: minutos))
            return
        }
        // Se toma ya: si la sesión vence, la hoja desaparece a mitad del envío
        // y el entorno deja de estar disponible.
        let cola = envios
        enviando = true
        fallo = nil
        Task {
            defer { enviando = false }
            do {
                switch try await ClienteAPI.compartido.enviarTanda(tanda, forzar: forzar) {
                case .guardada:
                    listo(tanda, nombre: modelo.nombre, enCola: false)
                case .parecida(let p):
                    aviso = Aviso(texto: textoAviso(cantidad: p.cantidad, modelo: modelo.nombre,
                                                    previa: p.fecha, minutos: p.haceMinutos))
                }
            } catch is CancellationError {
                // La hoja se cerró: nada que mostrar.
            } catch ErrorAPI.sinConexion {
                sinSenal(tanda, modelo: modelo, forzar: forzar, cola: cola)
            } catch ErrorAPI.sinSesion {
                // La sesión venció y la app ya vuelve a la pantalla de entrar:
                // la hoja se va, así que no se pregunta nada. Juan ya tocó
                // Guardar; queda en la cola y se manda al volver a entrar.
                encolar(tanda, nombre: modelo.nombre, cola: cola)
                listo(tanda, nombre: modelo.nombre, enCola: true)
            } catch {
                fallo = error.textoParaMostrar
            }
        }
    }

    /// Sin servidor: misma pregunta que haría él, contra lo guardado en el
    /// iPhone y lo que ya está en la cola. Lo que entra a la cola ya no se
    /// vuelve a preguntar (se manda con forzar: true).
    private func sinSenal(_ tanda: TandaNueva, modelo: Modelo, forzar: Bool, cola: Envios) {
        let momento = tanda.cuando ?? Date()
        if !forzar, let previa = parecidaLocal(modeloId: modelo.id, cantidad: tanda.cantidad, cuando: momento,
                                                         cola: cola) {
            let minutos = Int(abs(momento.timeIntervalSince(previa)) / 60)
            aviso = Aviso(texto: textoAviso(cantidad: tanda.cantidad, modelo: modelo.nombre,
                                            previa: previa, minutos: minutos))
            return
        }
        encolar(tanda, nombre: modelo.nombre, cola: cola)
        listo(tanda, nombre: modelo.nombre, enCola: true)
    }

    /// La hora queda fija desde ahora (si no, el servidor pondría la de cuando
    /// vuelva la señal).
    private func encolar(_ tanda: TandaNueva, nombre: String, cola: Envios) {
        cola.agregar(TandaPendiente(idCliente: tanda.idCliente, modeloId: tanda.modeloId,
                                    cantidad: tanda.cantidad, cuando: tanda.cuando ?? Date(),
                                    nombreModelo: nombre))
    }

    /// La hora de la tanda parecida más reciente, si hay.
    private func parecidaLocal(modeloId: Int, cantidad: Int, cuando: Date, cola: Envios) -> Date? {
        let guardada = tandas.first { t in
            guard t.modeloId == modeloId, let fecha = t.fecha else { return false }
            return ReglaParecida.esParecida(cantidad: cantidad, cuando: cuando,
                                            otraCantidad: t.cantidad, otroCuando: fecha)
        }?.fecha
        let enCola = cola.pendienteParecida(modeloId: modeloId, cantidad: cantidad, cuando: cuando)?.cuando
        switch (guardada, enCola) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// "Hace 40 minutos ya anotaste 50 de Medalla oro (hoy, 3:02 p. m.)."
    private func textoAviso(cantidad: Int, modelo: String, previa: Date?, minutos: Int) -> String {
        let cuandoPrevia = previa.map { " (\(Formato.dia($0).lowercased()), \(Formato.hora($0)))" } ?? ""
        let que = "\(Formato.num(cantidad)) de \(modelo)"
        if horaElegida {
            // Con una hora puesta a mano, la distancia es contra esa hora, no contra ahora.
            return "Ya anotaste \(que) a \(Formato.duracion(minutos: minutos)) de la hora que pusiste\(cuandoPrevia)."
        }
        return "Hace \(Formato.duracion(minutos: minutos)) ya anotaste \(que)\(cuandoPrevia)."
    }

    private func listo(_ tanda: TandaNueva, nombre: String, enCola: Bool) {
        intento = nil
        let texto = enCola
            ? "Sin señal: la tanda quedó en el iPhone y se envía sola cuando vuelva la señal."
            : "Tanda guardada: \(Formato.num(tanda.cantidad)) de \(nombre)"
        UIAccessibility.post(notification: .announcement, argument: texto)
        alGuardar(enCola)
        cerrar()
    }
}

#Preview("Anotar") {
    AnotarTandaVista(detalle: Muestras.detalle, modeloInicial: nil,
                     tandas: Muestras.detalle.ultimasTandas) { _ in }
        .environment(Envios())
}

#Preview("Anotar oscuro, letra grande") {
    AnotarTandaVista(detalle: Muestras.detalle, modeloInicial: nil,
                     tandas: Muestras.detalle.ultimasTandas) { _ in }
        .environment(Envios())
        .preferredColorScheme(.dark)
        .environment(\.dynamicTypeSize, .accessibility2)
}
