// Crear un producto (maqueta NuevoProducto) o, con `editando`, cambiar uno que
// ya existe: nombre, foto y opciones. A cada opción nueva se le puede poner
// "¿Ya tienes hechos?": entra como una tanda inicial.
import SwiftUI
import PhotosUI
import UIKit

struct NuevoProductoVista: View {
    let editando: ProductoDetalle?
    let alGuardar: (ProductoDetalle) -> Void

    @Environment(\.dismiss) private var cerrar

    private struct FilaOpcion: Identifiable {
        /// También es el id_cliente de su tanda inicial: un reintento no la duplica.
        let id = UUID()
        /// nil = opción nueva, todavía no está en el servidor.
        var existenteId: Int?
        var nombre: String
        var hechos: String = ""
        var saldo: Int = 0
        /// La tanda inicial ya quedó en el servidor.
        var hechosEnviados = false
    }

    @State private var nombre: String
    @State private var opciones: [FilaOpcion]
    @State private var guardando = false
    @State private var fallo: String? = nil
    /// Las opciones como están en el servidor según lo último que se sabe. Se
    /// actualiza con cada paso que sale bien: si guardar falla a la mitad, el
    /// reintento solo hace lo que faltó (no duplica ni vuelve a borrar).
    @State private var originales: [OpcionProducto]
    /// El producto ya creado en un intento anterior que falló después (la
    /// foto, por ejemplo): el reintento lo completa en vez de crear otro.
    @State private var creado: ProductoDetalle? = nil
    /// Uno por formulario y el mismo en cada intento de crear.
    @State private var idCliente = UUID()
    @State private var eleccion: PhotosPickerItem? = nil
    /// JPEG reducido, listo para subir.
    @State private var foto: Data? = nil
    @State private var vistaFoto: UIImage? = nil

    private static let maxOpciones = 50

    init(editando: ProductoDetalle?, alGuardar: @escaping (ProductoDetalle) -> Void) {
        self.editando = editando
        self.alGuardar = alGuardar
        _nombre = State(initialValue: editando?.nombre ?? "")
        _originales = State(initialValue: editando?.opciones ?? [])
        if let d = editando {
            _opciones = State(initialValue: d.opciones.map {
                FilaOpcion(existenteId: $0.id, nombre: $0.nombre, saldo: $0.saldo)
            })
        } else {
            _opciones = State(initialValue: [FilaOpcion(existenteId: nil, nombre: "")])
        }
    }

    private func limpio(_ texto: String) -> String {
        texto.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil si está vacío; -1 si no es un número válido.
    private func hechos(_ texto: String) -> Int? {
        if texto.isEmpty { return nil }
        guard let n = Int(texto), (0...100_000).contains(n) else { return -1 }
        return n
    }

    /// Lo que falta para poder guardar, o nil si está todo bien.
    private var problema: String? {
        let n = limpio(nombre)
        if n.isEmpty { return "Escribe el nombre del producto." }
        if n.count > 120 { return "El nombre puede tener hasta 120 letras." }
        if opciones.isEmpty { return "Agrega al menos una opción." }
        var vistos = Set<String>()
        for o in opciones {
            let no = limpio(o.nombre)
            if no.isEmpty { return "Cada opción necesita un nombre." }
            if no.count > 80 { return "El nombre de una opción puede tener hasta 80 letras." }
            if !vistos.insert(no.lowercased()).inserted { return "Hay dos opciones llamadas \(no)." }
            if o.existenteId == nil, hechos(o.hechos) == -1 {
                return "Los ya hechos de \(no) deben ser un número de 0 a 100.000."
            }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Nombre") {
                        TextField("Ej.: Soporte de micrófono", text: $nombre)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Nombre")
                    }
                    PhotosPicker(selection: $eleccion, matching: .images) {
                        HStack(spacing: 12) {
                            miniatura
                            Text(vistaFoto == nil && editando?.fotoUrl == nil ? "Agregar foto" : "Cambiar foto")
                                .foregroundStyle(Color.acentoTexto)
                            Spacer()
                            Text("Opcional")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityLabel("Agregar foto del producto")
                }

                Section {
                    ForEach($opciones) { $o in
                        HStack(spacing: 12) {
                            TextField("Nombre de la opción", text: $o.nombre)
                                .accessibilityLabel("Nombre de la opción")
                            if o.existenteId == nil {
                                TextField("Ninguno", text: $o.hechos)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                    .frame(maxWidth: 110)
                                    .accessibilityLabel("Ya hechos de \(o.nombre.isEmpty ? "esta opción" : o.nombre)")
                            } else {
                                Text(Formato.saldo(o.saldo))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .onDelete { posiciones in
                        opciones.remove(atOffsets: posiciones)
                    }
                    Button {
                        opciones.append(FilaOpcion(existenteId: nil, nombre: ""))
                    } label: {
                        Label("Agregar opción", systemImage: "plus.circle.fill")
                            .frame(minHeight: 44)
                    }
                    .disabled(opciones.count >= NuevoProductoVista.maxOpciones)
                } header: {
                    HStack {
                        Text("Opciones · \(Formato.num(opciones.count))")
                        Spacer()
                        Text("¿Ya tienes hechos?")
                    }
                } footer: {
                    Text(editando == nil
                         ? "Las opciones son lo que el cliente elige en tu página: colores, tamaños… El «ya hechos» es opcional: si tienes stock guardado, ponlo y la cuenta arranca desde ahí."
                         : "Una opción que ya tiene ventas o tandas no se puede quitar.")
                }

                if let fallo {
                    Section {
                        Label(fallo, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(guardando)
            .navigationTitle(editando == nil ? "Nuevo producto" : "Editar producto")
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
                        .accessibilityLabel(editando == nil ? "Crear producto" : "Guardar cambios")
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
            .onChange(of: eleccion) { _, nueva in
                guard let nueva else { return }
                Task { await leerFoto(nueva) }
            }
        }
    }

    @ViewBuilder
    private var miniatura: some View {
        if let vistaFoto {
            Image(uiImage: vistaFoto)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let d = editando {
            MiniaturaModelo(nombre: d.nombre, fotoUrl: d.fotoUrl, indice: 0)
        } else {
            Image(systemName: "camera")
                .foregroundStyle(Color.acentoTexto)
                .frame(width: 44, height: 44)
                .background(Color.acento.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func leerFoto(_ item: PhotosPickerItem) async {
        defer { eleccion = nil }
        do {
            guard let datos = try await item.loadTransferable(type: Data.self),
                  let jpeg = Fotos.jpegReducido(datos) else {
                fallo = "No se pudo leer esa foto."
                return
            }
            foto = jpeg
            vistaFoto = UIImage(data: jpeg)
        } catch {
            fallo = error.textoParaMostrar
        }
    }

    // MARK: - Guardar

    private func guardar() async {
        guard problema == nil else { return }
        guardando = true
        fallo = nil
        defer { guardando = false }
        do {
            let resultado: ProductoDetalle
            if let base = editando ?? creado {
                resultado = try await guardarCambios(base)
            } else {
                let nuevo = ProductoNuevo(nombre: limpio(nombre), opciones: opciones.map {
                    OpcionNueva(nombre: limpio($0.nombre), hechos: hechos($0.hechos))
                }, idCliente: idCliente.uuidString.lowercased())
                let hecho = try await ClienteAPI.compartido.crearProducto(nuevo)
                creado = hecho
                originales = hecho.opciones
                // El servidor las devuelve en el mismo orden en que se mandaron.
                for (i, o) in hecho.opciones.enumerated() where i < opciones.count {
                    opciones[i].existenteId = o.id
                    opciones[i].saldo = o.saldo
                    opciones[i].hechosEnviados = true
                }
                // Solo queda la foto, si hay.
                resultado = try await guardarCambios(hecho)
            }
            alGuardar(resultado)
            cerrar()
        } catch {
            fallo = error.textoParaMostrar
            if let base = editando ?? creado { await recargarTrasFallo(base) }
        }
    }

    /// Un paso pudo quedar hecho en el servidor aunque la respuesta no llegó
    /// (timeout): se pregunta cómo quedó para que el reintento no lo repita.
    private func recargarTrasFallo(_ base: ProductoDetalle) async {
        guard let fresco = try? await ClienteAPI.compartido.producto(id: base.id) else { return }
        let conocidos = Set(originales.map { $0.id })
        var adoptadas = Set<Int>()
        for nueva in fresco.opciones where !conocidos.contains(nueva.id) {
            if let i = opciones.firstIndex(where: { $0.existenteId == nil && limpio($0.nombre) == nueva.nombre }) {
                opciones[i].existenteId = nueva.id
                adoptadas.insert(nueva.id)
            }
        }
        // Una opción que alguien agregó desde la web no entra: si entrara, el
        // reintento la borraría por no estar en la lista.
        originales = fresco.opciones.filter { conocidos.contains($0.id) || adoptadas.contains($0.id) }
    }

    /// Opciones (quitar, renombrar, agregar con sus ya hechos), nombre y foto;
    /// al final se pide el producto ya con todo y sus saldos.
    private func guardarCambios(_ base: ProductoDetalle) async throws -> ProductoDetalle {
        let api = ClienteAPI.compartido
        let quedan = Set(opciones.compactMap { $0.existenteId })
        for vieja in originales where !quedan.contains(vieja.id) {
            do {
                try await api.borrarOpcion(id: vieja.id)
            } catch ErrorAPI.noExiste {
                // Ya estaba borrada (un intento anterior o desde la web).
            } catch ErrorAPI.servidor(let texto) {
                // Tiene movimientos (409): vuelve a la lista para que no se pierda de vista.
                opciones.append(FilaOpcion(existenteId: vieja.id, nombre: vieja.nombre, saldo: vieja.saldo))
                throw ErrorAPI.servidor(texto)
            }
            originales.removeAll { $0.id == vieja.id }
        }
        for fila in opciones {
            let no = limpio(fila.nombre)
            var id = fila.existenteId
            if let existente = id {
                if let antes = originales.first(where: { $0.id == existente }), antes.nombre != no {
                    let nueva = try await api.renombrarOpcion(id: existente, nombre: no)
                    if let k = originales.firstIndex(where: { $0.id == existente }) { originales[k] = nueva }
                }
            } else {
                let nueva = try await api.agregarOpcion(productoId: base.id, nombre: no)
                originales.append(nueva)
                id = nueva.id
                if let i = opciones.firstIndex(where: { $0.id == fila.id }) { opciones[i].existenteId = nueva.id }
            }
            if let id, !fila.hechosEnviados, let n = hechos(fila.hechos), n > 0 {
                let inicial = MovimientoNuevo(idCliente: fila.id, opcionId: id, tipo: .tanda, cantidad: n, cuando: nil)
                _ = try await api.enviarMovimiento(inicial, forzar: true)
                if let i = opciones.firstIndex(where: { $0.id == fila.id }) { opciones[i].hechosEnviados = true }
            }
        }

        let n = limpio(nombre)
        if n != base.nombre {
            _ = try await api.renombrarProducto(id: base.id, nombre: n)
        }
        if let foto {
            _ = try await api.subirFoto(productoId: base.id, jpeg: foto)
            self.foto = nil
        }
        return try await api.producto(id: base.id)
    }
}
