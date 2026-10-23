// Crear o editar un perfil de costos: lo que cuesta la luz, el desgaste y los
// repuestos de una impresora, y el margen de error. Valida igual que el
// servidor (perfiles.py) para que el 422 casi nunca llegue.
import SwiftUI

struct PerfilVista: View {
    let editando: Perfil?

    @Environment(Catalogo.self) private var catalogo
    @Environment(\.dismiss) private var cerrar

    @State private var nombre: String
    @State private var precioKwh: String
    @State private var consumo: String
    @State private var vida: String
    @State private var repuestos: String
    @State private var margenError: String
    @State private var dolar: String
    @State private var usarAhora: Bool
    @State private var guardando = false
    @State private var fallo: String? = nil
    @State private var guardados = 0

    /// Numeric(14, 2) en la base: más que esto el servidor lo rechaza.
    private static let maximo: Double = 999_999_999_999

    init(editando: Perfil?) {
        self.editando = editando
        let texto: (Double?) -> String = { $0.map { Formato.editable($0) } ?? "" }
        _nombre = State(initialValue: editando?.nombre ?? "")
        _precioKwh = State(initialValue: texto(editando?.precioKwh))
        _consumo = State(initialValue: texto(editando?.consumoWatts))
        _vida = State(initialValue: texto(editando?.vidaMaquinaH))
        _repuestos = State(initialValue: texto(editando?.precioRepuestos))
        _margenError = State(initialValue: editando.map { Formato.editable($0.margenError) } ?? "30")
        _dolar = State(initialValue: texto(editando?.precioDolar))
        _usarAhora = State(initialValue: false)
    }

    // MARK: - Validación

    private var nombreLimpio: String {
        nombre.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Valores {
        var precioKwh: Double
        var consumo: Double
        var vida: Double
        var repuestos: Double
        var margenError: Double
        var dolar: Double?
    }

    /// Los números ya leídos, o el primer problema que hay que corregir.
    private var revisado: Result<Valores, Problema> {
        if nombreLimpio.isEmpty { return .failure(Problema("Escribe el nombre del perfil.")) }
        if nombreLimpio.count > 80 { return .failure(Problema("El nombre puede tener hasta 80 letras.")) }
        func leer(_ texto: String, _ que: String) -> Result<Double, Problema> {
            guard let n = Formato.leerNumero(texto) else { return .failure(Problema("Escribe \(que).")) }
            if n < 0 { return .failure(Problema("Revisa \(que): no puede ser negativo.")) }
            if n > PerfilVista.maximo { return .failure(Problema("Revisa \(que): es demasiado grande.")) }
            return .success(n)
        }
        let kwh: Double, watts: Double, horas: Double, rep: Double, margen: Double
        switch leer(precioKwh, "el precio del kWh") {
        case .success(let n): kwh = n
        case .failure(let p): return .failure(p)
        }
        switch leer(consumo, "el consumo de la impresora") {
        case .success(let n): watts = n
        case .failure(let p): return .failure(p)
        }
        switch leer(vida, "la vida útil de la máquina") {
        case .success(let n): horas = n
        case .failure(let p): return .failure(p)
        }
        // Es el divisor del desgaste por hora: con 0 la fórmula no sirve.
        if horas <= 0 { return .failure(Problema("La vida útil tiene que ser mayor que 0 horas.")) }
        switch leer(repuestos, "el precio de los repuestos") {
        case .success(let n): rep = n
        case .failure(let p): return .failure(p)
        }
        switch leer(margenError, "el margen de error") {
        case .success(let n): margen = n
        case .failure(let p): return .failure(p)
        }
        if margen > 1000 { return .failure(Problema("El margen de error va de 0 a 1.000 %.")) }
        var precioDolar: Double? = nil
        if !dolar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch leer(dolar, "el precio del dólar") {
            case .success(let n): precioDolar = n
            case .failure(let p): return .failure(p)
            }
        }
        return .success(Valores(precioKwh: kwh, consumo: watts, vida: horas, repuestos: rep,
                                margenError: margen, dolar: precioDolar))
    }

    private var problema: String? {
        if case .failure(let p) = revisado { return p.texto }
        return nil
    }

    // MARK: - Pantalla

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nombre (AD5M Casa…)", text: $nombre)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityLabel("Nombre del perfil")
                    if editando == nil {
                        Toggle("Usar este perfil ahora", isOn: $usarAhora)
                            .tint(Color.completo)
                    }
                }

                Section {
                    campo("Precio del kWh", $precioKwh, prefijo: "$", unidad: nil)
                    campo("Consumo de la impresora", $consumo, prefijo: nil, unidad: "W")
                    campo("Vida útil de la máquina", $vida, prefijo: nil, unidad: "h")
                    campo("Repuestos", $repuestos, prefijo: "$", unidad: nil)
                    campo("Margen de error", $margenError, prefijo: nil, unidad: "%")
                } header: {
                    Text("Costos")
                } footer: {
                    Text("El margen de error se suma al costo, al tiempo y a los gramos: es el peor caso.")
                }

                Section {
                    campo("Precio del dólar", $dolar, prefijo: "$", unidad: nil, ejemplo: "Opcional")
                } footer: {
                    Text("Para los filamentos que compras en dólares. Si lo dejas vacío se usa \(Formato.pesos(Catalogo.dolarPorDefecto)).")
                }

                if let aviso = fallo ?? problema {
                    Section {
                        Text(aviso)
                            .font(.footnote)
                            .foregroundStyle(fallo != nil ? Color.red : Color.secondary)
                    }
                }
            }
            .navigationTitle(editando == nil ? "Nuevo perfil" : "Editar perfil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { cerrar() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if guardando {
                        ProgressView()
                    } else {
                        Button("Guardar") { guardar() }
                            .disabled(problema != nil)
                    }
                }
            }
            .interactiveDismissDisabled(guardando)
            .sensoryFeedback(.success, trigger: guardados)
        }
    }

    private func campo(_ titulo: String, _ texto: Binding<String>, prefijo: String?, unidad: String?,
                       ejemplo: String = "0") -> some View {
        HStack(spacing: 8) {
            Text(titulo)
            Spacer(minLength: 8)
            if let prefijo {
                Text(prefijo).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            TextField(ejemplo, text: texto)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(maxWidth: 130)
                .accessibilityLabel(titulo)
            if let unidad {
                Text(unidad).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
    }

    private func guardar() {
        guard case .success(let v) = revisado, !guardando else { return }
        guardando = true
        fallo = nil
        let nombreFinal = nombreLimpio
        Task {
            do {
                if let p = editando {
                    var cambios = CambiosPerfil()
                    cambios.nombre = nombreFinal
                    cambios.precioKwh = v.precioKwh
                    cambios.consumoWatts = v.consumo
                    cambios.vidaMaquinaH = v.vida
                    cambios.precioRepuestos = v.repuestos
                    cambios.margenError = v.margenError
                    if let d = v.dolar {
                        cambios.precioDolar = .poner(d)
                    } else if p.precioDolar != nil {
                        cambios.precioDolar = .borrar
                    }
                    _ = try await catalogo.editarPerfil(id: p.id, cambios)
                } else {
                    let nuevo = PerfilNuevo(nombre: nombreFinal, precioKwh: v.precioKwh, consumoWatts: v.consumo,
                                            vidaMaquinaH: v.vida, precioRepuestos: v.repuestos,
                                            margenError: v.margenError, precioDolar: v.dolar, activo: usarAhora)
                    _ = try await catalogo.crearPerfil(nuevo)
                }
                guardados += 1
                guardando = false
                cerrar()
            } catch {
                guardando = false
                if let texto = error.textoParaMostrar { fallo = texto }
            }
        }
    }
}

/// Un texto de validación como Error, para poder usar Result.
struct Problema: Error {
    let texto: String
    init(_ texto: String) { self.texto = texto }
}
