// Calculadora de precios (maqueta Calculadora): arriba el resultado, abajo los
// datos de la pieza. Usa la misma fórmula que la calculadora de escritorio
// (Puro/Calculo.swift) y recalcula con cada cambio. Lo escrito se guarda en el
// iPhone, así al volver a la pestaña sigue el último cálculo.
import SwiftUI
import UIKit

// MARK: - Lo que se guarda

enum OpcionRedondeo: String, Codable, CaseIterable, Identifiable {
    case ninguno, a500, a1000, a5000

    var id: String { rawValue }

    var redondeo: Redondeo {
        switch self {
        case .ninguno: return .ninguno
        case .a500: return .a500
        case .a1000: return .a1000
        case .a5000: return .a5000
        }
    }

    var titulo: String {
        switch self {
        case .ninguno: return "Sin redondeo"
        case .a500: return "A $500"
        case .a1000: return "A $1.000"
        case .a5000: return "A $5.000"
        }
    }
}

/// Todo va como texto, tal cual está en los campos: así un campo a medio
/// escribir ("2,") no se pierde al guardar.
struct DatosCalculadora: Codable, Equatable {
    struct FilaFilamento: Codable, Equatable, Identifiable {
        var id = UUID()
        /// nil = el primero de la lista.
        var filamentoId: Int? = nil
        var gramos = ""
    }

    struct Parte: Codable, Equatable, Identifiable {
        var id = UUID()
        var horas = "0"
        var minutos = "30"
        var filamentos: [FilaFilamento] = [FilaFilamento(gramos: "10")]
    }

    /// nil = el perfil activo.
    var perfilId: Int? = nil
    var horas = "2"
    var minutos = "30"
    var principal = FilaFilamento(gramos: "60")
    var varios = false
    var extras: [FilaFilamento] = []
    var unidades = "1"
    var margen = "3"
    var partes: [Parte] = []
    var conInsumos = false
    var insumos = ""
    var insumosACobrar = ""
    var redondeo: OpcionRedondeo = .ninguno

    private static let clave = "calculadora.datos.v1"

    static func guardados() -> DatosCalculadora {
        guard let datos = UserDefaults.standard.data(forKey: clave),
              let leidos = try? JSONDecoder().decode(DatosCalculadora.self, from: datos) else {
            return DatosCalculadora()
        }
        return leidos
    }

    func guardar() {
        if let datos = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(datos, forKey: DatosCalculadora.clave)
        }
    }
}

// MARK: - Pantalla

struct CalculadoraVista: View {
    @Environment(Catalogo.self) private var catalogo

    @State private var datos = DatosCalculadora.guardados()
    /// Sube con cada toque de − o +: dispara la háptica.
    @State private var pasos = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    tarjetaResultado
                    if let aviso = catalogo.aviso {
                        Label(aviso, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    grupoPrincipal
                    if datos.varios { grupoVarios }
                    grupoCama
                    ForEach($datos.partes) { $parte in
                        grupoParte($parte)
                    }
                    if datos.conInsumos { grupoInsumos }
                    botonesAgregar
                    grupoRedondeo
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .refreshable { await catalogo.recargar() }
            .navigationTitle("Calculadora")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Listo") { ocultarTeclado() }
                }
            }
            .sensoryFeedback(.selection, trigger: pasos)
            .onChange(of: datos) { _, nuevos in nuevos.guardar() }
        }
    }

    // MARK: - Datos elegidos

    private var perfil: Perfil? {
        if let id = datos.perfilId, let p = catalogo.perfiles.first(where: { $0.id == id }) { return p }
        return catalogo.perfilActivo
    }

    /// Si el filamento elegido ya no existe (lo borraron), se usa el primero.
    private func filamento(_ id: Int?) -> Filamento? {
        if let id, let f = catalogo.filamentos.first(where: { $0.id == id }) { return f }
        return catalogo.filamentos.first
    }

    /// Todo número escrito pasa por aquí, acotado: un número pegado de 20
    /// cifras haría caer la app al convertirlo a Int.
    private static let tope: Double = 1e9

    private func numero(_ texto: String) -> Double {
        min(max(0, Formato.leerNumero(texto) ?? 0), CalculadoraVista.tope)
    }

    private func totalMinutos(_ horas: String, _ minutos: String) -> Double {
        numero(horas) * 60 + numero(minutos)
    }

    private func usos(_ filas: [DatosCalculadora.FilaFilamento], perfil: Perfil) -> [UsoFilamento] {
        filas.map { fila in
            let precio = filamento(fila.filamentoId).map { catalogo.precioKgCOP($0, perfil: perfil) } ?? 0
            return UsoFilamento(gramos: numero(fila.gramos), precioKg: precio)
        }
    }

    /// Es un conteo de piezas: entero y al menos 1, el mismo para la fórmula y para "Por cama (N)".
    private var unidades: Int { max(1, Int(numero(datos.unidades).rounded())) }

    private var resultado: ResultadoCalculo? {
        guard let elegido = perfil else { return nil }
        var filas = [datos.principal]
        if datos.varios { filas += datos.extras }
        let entrada = EntradaCalculo(
            minutos: totalMinutos(datos.horas, datos.minutos),
            filamentos: usos(filas, perfil: elegido),
            partes: datos.partes.map {
                ParteExtra(minutos: totalMinutos($0.horas, $0.minutos), filamentos: usos($0.filamentos, perfil: elegido))
            },
            unidadesCama: Double(unidades),
            margenGanancia: numero(datos.margen),
            insumos: datos.conInsumos ? numero(datos.insumos) : 0,
            insumosACobrar: datos.conInsumos ? Formato.leerNumero(datos.insumosACobrar).map { min($0, CalculadoraVista.tope) } : nil,
            redondeo: datos.redondeo.redondeo)
        return calcular(entrada, perfil: elegido.calculo)
    }

    // MARK: - Resultado

    @ViewBuilder
    private var tarjetaResultado: some View {
        if let r = resultado, let elegido = perfil {
            let margen = Formato.decimal(elegido.margenError)
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        precioPieza(r)
                        Spacer(minLength: 12)
                        precioCama(r, alineacion: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        precioPieza(r)
                        precioCama(r, alineacion: .leading)
                    }
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        dato("Costo pieza", Formato.pesos(r.costoPieza))
                        dato("Ganancia pieza", Formato.pesos(r.gananciaPieza),
                             color: r.gananciaPieza < 0 ? .red : .completoTexto)
                    }
                    GridRow {
                        dato("Tiempo (+\(margen) %)", Formato.horasMinutos(r.horasConMargen * 60))
                        dato("Filamento (+\(margen) %)", "\(Formato.num(Int(min(r.gramosConMargen, 1e12).rounded()))) g")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vidrio()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "printer")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(catalogo.cargando ? "Bajando los perfiles…" : "Todavía no hay perfiles")
                    .font(.headline)
                Text("La calculadora necesita un perfil con los costos de la impresora. Se bajan del servidor la primera vez que hay señal, o puedes crear uno en Ajustes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .vidrio()
        }
    }

    private func precioPieza(_ r: ResultadoCalculo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Precio por pieza")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Formato.pesos(r.precioPieza))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.acentoTexto)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
    }

    private func precioCama(_ r: ResultadoCalculo, alineacion: HorizontalAlignment) -> some View {
        let n = unidades
        let total = r.precioPieza * Double(n)
        // Lo que se cobra por la cama entera: el precio de cada pieza (ya
        // redondeado) por las que caben.
        return VStack(alignment: alineacion, spacing: 2) {
            Text("Por cama (\(Formato.num(n)))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Formato.pesos(total))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Por cama de \(Formato.num(n)) \(Formato.plural(n, "pieza", "piezas")): \(Formato.pesos(total))")
    }

    private func dato(_ titulo: String, _ valor: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titulo)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(valor)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Datos de la pieza

    private var grupoPrincipal: some View {
        Grupo {
            selectorPerfil
            Separador()
            filaTiempo(titulo: "Tiempo de impresión", horas: $datos.horas, minutos: $datos.minutos, que: "de impresión")
            Separador()
            selectorFilamento(titulo: "Filamento", id: $datos.principal.filamentoId)
            filaGramos(titulo: "Gramos", texto: $datos.principal.gramos, que: "del filamento principal")
            Separador()
            Toggle(isOn: Binding(
                get: { datos.varios },
                set: { activo in
                    datos.varios = activo
                    if activo && datos.extras.isEmpty {
                        datos.extras.append(DatosCalculadora.FilaFilamento(gramos: "10"))
                    }
                })) {
                Text("Varios filamentos")
            }
            .tint(Color.completo)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            if catalogo.filamentos.isEmpty {
                Separador()
                Text("No hay filamentos guardados: el material cuenta como $0. Agrégalos en Ajustes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var selectorPerfil: some View {
        if catalogo.perfiles.isEmpty {
            FilaTexto(titulo: "Perfil", valor: "Sin perfiles")
        } else {
            FilaSelector(titulo: "Perfil") {
                Picker("Perfil", selection: Binding<Int?>(
                    get: { perfil?.id },
                    set: { nuevo in
                        // Elegir el activo deja "nil": así, si se cambia el activo
                        // en Ajustes, la calculadora lo sigue.
                        datos.perfilId = (nuevo == catalogo.perfilActivo?.id) ? nil : nuevo
                    })) {
                    ForEach(catalogo.perfiles) { p in
                        Text(p.nombre).tag(Optional(p.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectorFilamento(titulo: String, id: Binding<Int?>) -> some View {
        if catalogo.filamentos.isEmpty {
            FilaTexto(titulo: titulo, valor: "Sin filamentos")
        } else {
            FilaSelector(titulo: titulo) {
                Picker(titulo, selection: Binding<Int?>(
                    get: { filamento(id.wrappedValue)?.id },
                    set: { id.wrappedValue = $0 })) {
                    ForEach(catalogo.filamentos) { f in
                        Text(FilamentoVista.nombre(f)).tag(Optional(f.id))
                    }
                }
            }
        }
    }

    private var grupoVarios: some View {
        Grupo {
            Encabezado(texto: "Otros filamentos de la cama")
            ForEach(Array(datos.extras.enumerated()), id: \.element.id) { i, fila in
                Separador()
                if let indice = datos.extras.firstIndex(where: { $0.id == fila.id }) {
                    selectorFilamento(titulo: "Filamento \(i + 2)", id: $datos.extras[indice].filamentoId)
                    filaGramos(titulo: "Gramos", texto: $datos.extras[indice].gramos, que: "del filamento \(i + 2)")
                    BotonQuitar(titulo: "Quitar filamento \(i + 2)") {
                        datos.extras.removeAll { $0.id == fila.id }
                        if datos.extras.isEmpty { datos.varios = false }
                    }
                }
            }
            Separador()
            BotonAgregar(titulo: "Otro filamento") {
                datos.extras.append(DatosCalculadora.FilaFilamento(gramos: "10"))
            }
        }
    }

    private var grupoCama: some View {
        Grupo {
            FilaPasos(titulo: "Unidades por cama",
                      menos: "Una unidad menos", mas: "Una unidad más",
                      alMenos: { cambiar($datos.unidades, en: -1, minimo: 1, entero: true) },
                      alMas: { cambiar($datos.unidades, en: 1, minimo: 1, entero: true) }) {
                CampoNumero(texto: $datos.unidades, teclado: .numberPad, nombre: "Unidades por cama")
            }
            Separador()
            FilaPasos(titulo: "Margen de ganancia",
                      menos: "Bajar el margen 0,5", mas: "Subir el margen 0,5",
                      alMenos: { cambiar($datos.margen, en: -0.5, minimo: 1) },
                      alMas: { cambiar($datos.margen, en: 0.5, minimo: 1) }) {
                HStack(spacing: 2) {
                    Text("×")
                        .font(.body.weight(.semibold))
                        .accessibilityHidden(true)
                    CampoNumero(texto: $datos.margen, teclado: .decimalPad, nombre: "Margen de ganancia, veces el costo")
                }
            }
        }
    }

    private func grupoParte(_ parte: Binding<DatosCalculadora.Parte>) -> some View {
        let numeroParte = (datos.partes.firstIndex(where: { $0.id == parte.wrappedValue.id }) ?? 0) + 1
        let idParte = parte.wrappedValue.id
        return Grupo {
            HStack {
                Encabezado(texto: "Parte extra \(numeroParte)")
                Spacer()
                Button(role: .destructive) {
                    datos.partes.removeAll { $0.id == idParte }
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Quitar parte extra \(numeroParte)")
                .padding(.trailing, 4)
            }
            Separador()
            filaTiempo(titulo: "Tiempo", horas: parte.horas, minutos: parte.minutos,
                       que: "de la parte extra \(numeroParte)")
            ForEach(Array(parte.wrappedValue.filamentos.enumerated()), id: \.element.id) { i, fila in
                Separador()
                if let indice = parte.wrappedValue.filamentos.firstIndex(where: { $0.id == fila.id }) {
                    selectorFilamento(titulo: "Filamento \(i + 1)", id: parte.filamentos[indice].filamentoId)
                    filaGramos(titulo: "Gramos", texto: parte.filamentos[indice].gramos,
                               que: "del filamento \(i + 1) de la parte extra \(numeroParte)")
                    if parte.wrappedValue.filamentos.count > 1 {
                        BotonQuitar(titulo: "Quitar filamento \(i + 1) de la parte extra \(numeroParte)") {
                            parte.wrappedValue.filamentos.removeAll { $0.id == fila.id }
                        }
                    }
                }
            }
            Separador()
            BotonAgregar(titulo: "Filamento a esta parte") {
                parte.wrappedValue.filamentos.append(DatosCalculadora.FilaFilamento(gramos: "10"))
            }
        }
    }

    private var grupoInsumos: some View {
        Grupo {
            HStack {
                Encabezado(texto: "Insumos")
                Spacer()
                Button(role: .destructive) {
                    datos.conInsumos = false
                    datos.insumos = ""
                    datos.insumosACobrar = ""
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Quitar insumos")
                .padding(.trailing, 4)
            }
            Separador()
            FilaCampoPesos(titulo: "Costo", texto: $datos.insumos, nombre: "Costo de los insumos")
            Separador()
            FilaCampoPesos(titulo: "A cobrar (opcional)", texto: $datos.insumosACobrar,
                           nombre: "Cuánto cobrar por los insumos, opcional")
            Text("Imanes, argollas, cajas… Si no pones cuánto cobrar, se cobran a lo que costaron.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var botonesAgregar: some View {
        // Columnas iguales: el texto de uno no empuja al otro.
        Grid(horizontalSpacing: 12) {
            GridRow {
                BotonGrande(titulo: "Parte extra", icono: "plus") {
                    datos.partes.append(DatosCalculadora.Parte())
                }
                BotonGrande(titulo: "Insumos", icono: "plus") {
                    datos.conInsumos = true
                }
                .disabled(datos.conInsumos)
            }
        }
    }

    private var grupoRedondeo: some View {
        Grupo {
            FilaSelector(titulo: "Redondeo") {
                Picker("Redondeo", selection: $datos.redondeo) {
                    ForEach(OpcionRedondeo.allCases) { o in
                        Text(o.titulo).tag(o)
                    }
                }
            }
        }
    }

    // MARK: - Filas con − y +

    private func filaTiempo(titulo: String, horas: Binding<String>, minutos: Binding<String>, que: String) -> some View {
        FilaPasos(titulo: titulo,
                  menos: "Restar 15 minutos", mas: "Sumar 15 minutos",
                  alMenos: { moverTiempo(horas: horas, minutos: minutos, en: -15) },
                  alMas: { moverTiempo(horas: horas, minutos: minutos, en: 15) }) {
            HStack(spacing: 4) {
                CampoNumero(texto: horas, teclado: .numberPad, nombre: "Horas \(que)", ancho: 44)
                Text("h").foregroundStyle(.secondary).accessibilityHidden(true)
                CampoNumero(texto: minutos, teclado: .numberPad, nombre: "Minutos \(que)", ancho: 44)
                Text("min").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
    }

    private func filaGramos(titulo: String, texto: Binding<String>, que: String) -> some View {
        FilaPasos(titulo: titulo,
                  menos: "Restar 5 gramos", mas: "Sumar 5 gramos",
                  alMenos: { cambiar(texto, en: -5, minimo: 0) },
                  alMas: { cambiar(texto, en: 5, minimo: 0) }) {
            HStack(spacing: 4) {
                CampoNumero(texto: texto, teclado: .decimalPad, nombre: "Gramos \(que)")
                Text("g").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
    }

    private func moverTiempo(horas: Binding<String>, minutos: Binding<String>, en delta: Double) {
        let total = max(0, totalMinutos(horas.wrappedValue, minutos.wrappedValue) + delta)
        let enteros = Int(min(total, 1e9).rounded())
        horas.wrappedValue = String(enteros / 60)
        minutos.wrappedValue = String(enteros % 60)
        pasos += 1
    }

    private func cambiar(_ texto: Binding<String>, en delta: Double, minimo: Double, entero: Bool = false) {
        var valor = (Formato.leerNumero(texto.wrappedValue) ?? minimo) + delta
        valor = max(minimo, min(valor, 1e9))
        texto.wrappedValue = entero ? String(Int(valor.rounded())) : Formato.editable(valor)
        pasos += 1
    }

    private func ocultarTeclado() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - Piezas de la pantalla

/// Un grupo de filas sobre fondo de tarjeta, como las listas de Ajustes.
private struct Grupo<Contenido: View>: View {
    @ViewBuilder let contenido: Contenido

    var body: some View {
        VStack(spacing: 0) {
            contenido
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
    }
}

private struct Separador: View {
    var body: some View {
        Divider().padding(.leading, 16)
    }
}

private struct Encabezado: View {
    let texto: String

    var body: some View {
        Text(texto)
            .font(.headline)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Título a la izquierda y −, campo, + a la derecha. Si no cabe en una línea
/// (iPhone SE, letra grande), los controles bajan debajo del título.
private struct FilaPasos<Campo: View>: View {
    let titulo: String
    let menos: String
    let mas: String
    let alMenos: () -> Void
    let alMas: () -> Void
    @ViewBuilder let campo: Campo

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(titulo)
                Spacer(minLength: 8)
                controles
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(titulo)
                controles
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
    }

    private var controles: some View {
        HStack(spacing: 8) {
            BotonPaso(simbolo: "minus", etiqueta: menos, accion: alMenos)
            campo
            BotonPaso(simbolo: "plus", etiqueta: mas, accion: alMas)
        }
    }
}

private struct BotonPaso: View {
    let simbolo: String
    let etiqueta: String
    let accion: () -> Void

    var body: some View {
        Button(action: accion) {
            Image(systemName: simbolo)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Color(.tertiarySystemFill), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(etiqueta)
    }
}

private struct CampoNumero: View {
    @Binding var texto: String
    let teclado: UIKeyboardType
    let nombre: String
    var ancho: CGFloat = 64

    @ScaledMetric(relativeTo: .body) private var escala: CGFloat = 1

    var body: some View {
        TextField("0", text: $texto)
            .keyboardType(teclado)
            .multilineTextAlignment(.center)
            .font(.body.weight(.semibold).monospacedDigit())
            .frame(width: ancho * escala)
            .frame(minHeight: 44)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(nombre)
    }
}

/// Título y un selector de menú a la derecha (o debajo, si no cabe).
private struct FilaSelector<Eleccion: View>: View {
    let titulo: String
    @ViewBuilder let selector: Eleccion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(titulo)
                Spacer(minLength: 8)
                menu
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo)
                menu
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(minHeight: 50)
    }

    private var menu: some View {
        selector
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Color.acentoTexto)
            .frame(minHeight: 44)
    }
}

private struct FilaTexto: View {
    let titulo: String
    let valor: String

    var body: some View {
        HStack {
            Text(titulo)
            Spacer()
            Text(valor).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }
}

private struct FilaCampoPesos: View {
    let titulo: String
    @Binding var texto: String
    let nombre: String

    var body: some View {
        HStack(spacing: 12) {
            Text(titulo)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Text("$").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("0", text: $texto)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: 140)
                    .accessibilityLabel(nombre)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
    }
}

private struct BotonAgregar: View {
    let titulo: String
    let accion: () -> Void

    var body: some View {
        Button(action: accion) {
            Label(titulo, systemImage: "plus.circle.fill")
                .foregroundStyle(Color.acentoTexto)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}

private struct BotonQuitar: View {
    let titulo: String
    let accion: () -> Void

    var body: some View {
        Button(role: .destructive, action: accion) {
            Label(titulo, systemImage: "minus.circle")
                .font(.subheadline)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}

/// "+ Parte extra" y "+ Insumos": mismo ancho y alto, esquinas de tarjeta.
private struct BotonGrande: View {
    let titulo: String
    let icono: String
    let accion: () -> Void

    @Environment(\.isEnabled) private var habilitado

    var body: some View {
        Button(action: accion) {
            Label(titulo, systemImage: icono)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.acentoTexto)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 50)
                .padding(.horizontal, 8)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
                .opacity(habilitado ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
