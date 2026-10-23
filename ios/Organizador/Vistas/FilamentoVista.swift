// Crear o editar un filamento (marca, tipo, color, precio por kilo y moneda),
// y la lista completa de filamentos que se abre desde Ajustes.
import SwiftUI
import UIKit

struct FilamentoVista: View {
    let editando: Filamento?

    @Environment(Catalogo.self) private var catalogo
    @Environment(\.dismiss) private var cerrar

    @State private var marca: String
    @State private var tipo: String
    @State private var color: String
    @State private var hex: String
    @State private var precio: String
    @State private var moneda: Moneda
    @State private var guardando = false
    @State private var fallo: String? = nil
    @State private var guardados = 0

    init(editando: Filamento?) {
        self.editando = editando
        _marca = State(initialValue: editando?.marca ?? "")
        _tipo = State(initialValue: editando?.tipo ?? "PLA")
        _color = State(initialValue: editando?.color ?? "")
        _hex = State(initialValue: editando?.hex ?? "")
        _precio = State(initialValue: editando.map { Formato.editable($0.precioKg) } ?? "")
        _moneda = State(initialValue: editando?.moneda ?? .cop)
    }

    // MARK: - Para mostrar en otras pantallas

    /// "CoLiDo PLA · Black"
    static func nombre(_ f: Filamento) -> String {
        "\(f.marca) \(f.tipo) · \(f.color)"
    }

    /// "$70.000/kg" o "US$25/kg".
    static func textoPrecio(_ f: Filamento) -> String {
        switch f.moneda {
        case .cop: return "\(Formato.pesos(f.precioKg))/kg"
        case .usd: return "US$\(Formato.decimal(f.precioKg))/kg"
        }
    }

    // MARK: - Validación (la misma del servidor, perfiles.py)

    private func limpio(_ texto: String) -> String {
        texto.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// '#RRGGBB' en mayúsculas, nil si está vacío; "" si no es válido.
    private var hexNormalizado: String? {
        var t = limpio(hex).uppercased()
        if t.isEmpty { return nil }
        if !t.hasPrefix("#") { t = "#" + t }
        let digitos = t.dropFirst()
        let validos = digitos.count == 6 && digitos.allSatisfy { "0123456789ABCDEF".contains($0) }
        return validos ? t : ""
    }

    private var problema: String? {
        let m = limpio(marca), t = limpio(tipo), c = limpio(color)
        if m.isEmpty { return "Escribe la marca." }
        if m.count > 60 { return "La marca puede tener hasta 60 letras." }
        if t.isEmpty { return "Escribe el tipo (PLA, PETG…)." }
        if t.count > 30 { return "El tipo puede tener hasta 30 letras." }
        if c.isEmpty { return "Escribe el color." }
        if c.count > 40 { return "El color puede tener hasta 40 letras." }
        if hexNormalizado == "" { return "El código de color va como #RRGGBB (por ejemplo #1A1A1A), o déjalo vacío." }
        guard let p = Formato.leerNumero(precio) else { return "Escribe el precio por kilo." }
        if p < 0 { return "El precio no puede ser negativo." }
        if p > 999_999_999_999 { return "El precio es demasiado grande." }
        return nil
    }

    // MARK: - Pantalla

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Marca (CoLiDo, eSun…)", text: $marca)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Marca")
                    TextField("Tipo (PLA, PETG…)", text: $tipo)
                        .textInputAutocapitalization(.characters)
                        .accessibilityLabel("Tipo")
                    TextField("Color (Black, Rojo…)", text: $color)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Color")
                }

                Section {
                    HStack(spacing: 12) {
                        MuestraColor(hex: hexNormalizado, lado: 28)
                        TextField("#1A1A1A", text: $hex)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .accessibilityLabel("Código de color, opcional")
                    }
                } header: {
                    Text("Código de color (opcional)")
                } footer: {
                    Text("Sirve para ver el color en las listas. Va como #RRGGBB.")
                }

                Section("Precio") {
                    HStack {
                        Text("Precio por kilo")
                        Spacer(minLength: 8)
                        TextField("0", text: $precio)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: 160)
                            .accessibilityLabel("Precio por kilo")
                    }
                    Picker("Moneda", selection: $moneda) {
                        Text("Pesos (COP)").tag(Moneda.cop)
                        Text("Dólares (USD)").tag(Moneda.usd)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Moneda")
                }

                if let aviso = fallo ?? problema {
                    Section {
                        Text(aviso)
                            .font(.footnote)
                            .foregroundStyle(fallo != nil ? Color.red : Color.secondary)
                    }
                }
            }
            .navigationTitle(editando == nil ? "Nuevo filamento" : "Editar filamento")
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

    private func guardar() {
        guard problema == nil, !guardando, let p = Formato.leerNumero(precio) else { return }
        guardando = true
        fallo = nil
        let codigo = hexNormalizado
        Task {
            do {
                if let f = editando {
                    var cambios = CambiosFilamento()
                    cambios.marca = limpio(marca)
                    cambios.tipo = limpio(tipo)
                    cambios.color = limpio(color)
                    cambios.precioKg = p
                    cambios.moneda = moneda
                    if let codigo {
                        cambios.hex = .poner(codigo)
                    } else if f.hex != nil {
                        cambios.hex = .borrar
                    }
                    _ = try await catalogo.editarFilamento(id: f.id, cambios)
                } else {
                    let nuevo = FilamentoNuevo(marca: limpio(marca), tipo: limpio(tipo), color: limpio(color),
                                               hex: codigo, precioKg: p, moneda: moneda)
                    _ = try await catalogo.crearFilamento(nuevo)
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

// MARK: - Muestra de color

extension Color {
    /// '#RRGGBB' -> Color; nil si no se puede leer.
    init?(hex: String?) {
        guard var t = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let n = UInt32(t, radix: 16) else { return nil }
        self.init(red: Double((n >> 16) & 0xFF) / 255.0,
                  green: Double((n >> 8) & 0xFF) / 255.0,
                  blue: Double(n & 0xFF) / 255.0)
    }
}

/// Círculo con el color del filamento; sin código, un círculo punteado.
struct MuestraColor: View {
    let hex: String?
    var lado: CGFloat = 24

    var body: some View {
        Group {
            if let color = Color(hex: hex) {
                Circle()
                    .fill(color)
                    .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 1))
            } else {
                Circle()
                    .strokeBorder(Color(.tertiaryLabel), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }
        .frame(width: lado, height: lado)
        // El nombre del color ya va en el texto de al lado.
        .accessibilityHidden(true)
    }
}

/// Una fila de filamento en las listas de Ajustes.
struct FilaDeFilamento: View {
    let filamento: Filamento

    var body: some View {
        HStack(spacing: 12) {
            MuestraColor(hex: filamento.hex)
            Text(FilamentoVista.nombre(filamento))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(FilamentoVista.textoPrecio(filamento))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Toca para editar")
    }
}

// MARK: - Lista completa

struct FilamentosVista: View {
    @Environment(Catalogo.self) private var catalogo

    @State private var hoja: HojaFilamento? = nil
    @State private var porBorrar: Filamento? = nil
    @State private var fallo: String? = nil

    var body: some View {
        List {
            Section {
                ForEach(catalogo.filamentos) { f in
                    Button {
                        hoja = .editar(f)
                    } label: {
                        FilaDeFilamento(filamento: f)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            porBorrar = f
                        } label: {
                            Label("Borrar", systemImage: "trash")
                        }
                        Button {
                            hoja = .editar(f)
                        } label: {
                            Label("Editar", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            } footer: {
                if catalogo.filamentos.isEmpty {
                    Text("Todavía no hay filamentos.")
                }
            }
        }
        .navigationTitle("Filamentos")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    hoja = .nuevo
                } label: {
                    Label("Agregar filamento", systemImage: "plus")
                }
            }
        }
        .sheet(item: $hoja) { h in
            switch h {
            case .nuevo: FilamentoVista(editando: nil)
            case .editar(let f): FilamentoVista(editando: f)
            }
        }
        .confirmacionBorrarFilamento($porBorrar, fallo: $fallo, catalogo: catalogo)
    }
}

enum HojaFilamento: Identifiable {
    case nuevo
    case editar(Filamento)

    var id: String {
        switch self {
        case .nuevo: return "nuevo"
        case .editar(let f): return "editar-\(f.id)"
        }
    }
}

extension View {
    /// La pregunta antes de borrar un filamento y el aviso si falla. La usan
    /// Ajustes y la lista completa.
    @MainActor
    func confirmacionBorrarFilamento(_ porBorrar: Binding<Filamento?>, fallo: Binding<String?>,
                                     catalogo: Catalogo) -> some View {
        self
            .confirmationDialog(
                "¿Borrar \(porBorrar.wrappedValue.map { FilamentoVista.nombre($0) } ?? "el filamento")?",
                isPresented: Binding(get: { porBorrar.wrappedValue != nil },
                                     set: { if !$0 { porBorrar.wrappedValue = nil } }),
                titleVisibility: .visible,
                presenting: porBorrar.wrappedValue
            ) { f in
                Button("Borrar", role: .destructive) {
                    Task {
                        do {
                            try await catalogo.borrarFilamento(f)
                        } catch {
                            if let texto = error.textoParaMostrar { fallo.wrappedValue = texto }
                        }
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: { _ in
                Text("Se borra del servidor. Los cálculos que lo usaban pasan al primer filamento de la lista.")
            }
            .alert("No se pudo", isPresented: Binding(get: { fallo.wrappedValue != nil },
                                                     set: { if !$0 { fallo.wrappedValue = nil } })) {
                Button("Aceptar", role: .cancel) {}
            } message: {
                Text(fallo.wrappedValue ?? "")
            }
    }
}
