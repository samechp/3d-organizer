// Ajustes (maqueta Ajustes): elegir el perfil activo, crear y editar perfiles
// y filamentos, y cerrar sesión. Todo se guarda en el servidor; el Catalogo
// deja la copia en el iPhone para la calculadora sin señal.
import SwiftUI

struct AjustesVista: View {
    @Environment(Sesion.self) private var sesion
    @Environment(Envios.self) private var envios
    @Environment(Catalogo.self) private var catalogo

    @State private var hojaPerfil: HojaPerfil? = nil
    @State private var hojaFilamento: HojaFilamento? = nil
    @State private var perfilPorBorrar: Perfil? = nil
    @State private var filamentoPorBorrar: Filamento? = nil
    @State private var fallo: String? = nil
    @State private var activando: Int? = nil
    @State private var cambiosDeActivo = 0
    @State private var confirmarSalida = false
    @State private var cerrando = false

    /// Cuántos filamentos se ven aquí; el resto, en "Ver los N".
    private static let filamentosVisibles = 3

    var body: some View {
        NavigationStack {
            List {
                if let aviso = catalogo.aviso {
                    Section {
                        Label(aviso, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                seccionPerfiles
                if let activo = catalogo.perfilActivo {
                    seccionDatos(activo)
                }
                seccionFilamentos
                seccionCuenta
            }
            .navigationTitle("Ajustes")
            .toolbarTitleDisplayMode(.inlineLarge)
            .refreshable { await catalogo.recargar() }
            .sheet(item: $hojaPerfil) { h in
                switch h {
                case .nuevo: PerfilVista(editando: nil)
                case .editar(let p): PerfilVista(editando: p)
                }
            }
            .sheet(item: $hojaFilamento) { h in
                switch h {
                case .nuevo: FilamentoVista(editando: nil)
                case .editar(let f): FilamentoVista(editando: f)
                }
            }
            .confirmationDialog(
                "¿Borrar el perfil \(perfilPorBorrar?.nombre ?? "")?",
                isPresented: Binding(get: { perfilPorBorrar != nil },
                                     set: { if !$0 { perfilPorBorrar = nil } }),
                titleVisibility: .visible,
                presenting: perfilPorBorrar
            ) { p in
                Button("Borrar", role: .destructive) { borrar(p) }
                Button("Cancelar", role: .cancel) {}
            } message: { p in
                Text(p.activo
                     ? "Es el perfil activo: el más antiguo que quede pasa a ser el activo."
                     : "Se borra del servidor y de la calculadora.")
            }
            .confirmacionBorrarFilamento($filamentoPorBorrar, fallo: $fallo, catalogo: catalogo)
            .confirmationDialog("¿Cerrar sesión?", isPresented: $confirmarSalida, titleVisibility: .visible) {
                Button("Cerrar sesión", role: .destructive) { salir() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(mensajeSalida)
            }
            .sensoryFeedback(.selection, trigger: cambiosDeActivo)
            .task {
                // Las sesiones abiertas antes de que la app guardara el correo
                // lo piden una vez; sin señal simplemente no se muestra.
                if sesion.correo == nil, let correo = try? await ClienteAPI.compartido.yo() {
                    sesion.recordarCorreo(correo)
                }
            }
        }
    }

    // MARK: - Perfiles

    private var seccionPerfiles: some View {
        Section {
            ForEach(catalogo.perfiles) { p in
                Button {
                    activar(p)
                } label: {
                    HStack(spacing: 12) {
                        Text(p.nombre)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        if activando == p.id {
                            ProgressView()
                        } else if p.activo {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.acentoTexto)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(p.activo ? .isSelected : [])
                .accessibilityHint(p.activo ? "Es el perfil activo" : "Toca para usarlo en la calculadora")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        perfilPorBorrar = p
                    } label: {
                        Label("Borrar", systemImage: "trash")
                    }
                    Button {
                        hojaPerfil = .editar(p)
                    } label: {
                        Label("Editar", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
            Button {
                hojaPerfil = .nuevo
            } label: {
                Label("Nuevo perfil", systemImage: "plus")
                    .foregroundStyle(Color.acentoTexto)
                    .frame(minHeight: 44)
            }
        } header: {
            Text("Perfiles")
        } footer: {
            if catalogo.perfiles.isEmpty {
                Text(catalogo.cargando ? "Bajando los perfiles…" : "Todavía no hay perfiles. Crea uno con los costos de tu impresora.")
            } else {
                Text("El perfil activo es el que usa la calculadora. Desliza un perfil para editarlo o borrarlo.")
            }
        }
    }

    private func seccionDatos(_ p: Perfil) -> some View {
        Section {
            dato("Precio del kWh", Formato.pesos(p.precioKwh))
            dato("Consumo de la impresora", "\(Formato.decimal(p.consumoWatts)) W")
            dato("Vida útil de la máquina", "\(Formato.decimal(p.vidaMaquinaH)) h")
            dato("Repuestos", Formato.pesos(p.precioRepuestos))
            dato("Margen de error", "\(Formato.decimal(p.margenError)) %")
            // 0 también es "sin definir": la calculadora usa el de siempre.
            dato("Precio del dólar", (p.precioDolar ?? 0) > 0 ? Formato.pesos(p.precioDolar ?? 0)
                 : "Sin definir (\(Formato.pesos(Catalogo.dolarPorDefecto)))")
            Button {
                hojaPerfil = .editar(p)
            } label: {
                Label("Editar datos", systemImage: "pencil")
                    .foregroundStyle(Color.acentoTexto)
                    .frame(minHeight: 44)
            }
        } header: {
            Text("Datos de \(p.nombre)")
        }
    }

    private func dato(_ titulo: String, _ valor: String) -> some View {
        LabeledContent(titulo) {
            Text(valor)
                .monospacedDigit()
        }
        .frame(minHeight: 36)
    }

    // MARK: - Filamentos

    private var seccionFilamentos: some View {
        Section {
            ForEach(catalogo.filamentos.prefix(AjustesVista.filamentosVisibles)) { f in
                Button {
                    hojaFilamento = .editar(f)
                } label: {
                    FilaDeFilamento(filamento: f)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        filamentoPorBorrar = f
                    } label: {
                        Label("Borrar", systemImage: "trash")
                    }
                    Button {
                        hojaFilamento = .editar(f)
                    } label: {
                        Label("Editar", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
            Button {
                hojaFilamento = .nuevo
            } label: {
                Label("Agregar filamento", systemImage: "plus")
                    .foregroundStyle(Color.acentoTexto)
                    .frame(minHeight: 44)
            }
            if catalogo.filamentos.count > AjustesVista.filamentosVisibles {
                NavigationLink {
                    FilamentosVista()
                } label: {
                    Text("Ver los \(Formato.num(catalogo.filamentos.count))")
                        .frame(minHeight: 44)
                }
            }
        } header: {
            Text("Filamentos · \(Formato.num(catalogo.filamentos.count))")
        }
    }

    // MARK: - Cuenta

    private var seccionCuenta: some View {
        Section("Cuenta") {
            if let correo = sesion.correo {
                LabeledContent("Correo", value: correo)
            }
            Button(role: .destructive) {
                confirmarSalida = true
            } label: {
                HStack {
                    Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                    if cerrando {
                        Spacer()
                        ProgressView()
                    }
                }
                .frame(minHeight: 44)
            }
            .disabled(cerrando)
        }
    }

    private var mensajeSalida: String {
        let n = envios.pendientes.count
        let volver = "Para volver a usar la app tendrás que entrar con tu correo y contraseña."
        guard n > 0 else { return volver }
        return "Tienes \(Formato.num(n)) \(Formato.plural(n, "envío pendiente", "envíos pendientes")). "
            + "No se pierden: se envían cuando vuelvas a entrar, pero mientras tanto no aparecen en la web. "
            + volver
    }

    // MARK: - Acciones

    private func activar(_ p: Perfil) {
        guard !p.activo, activando == nil else { return }
        activando = p.id
        Task {
            do {
                try await catalogo.activar(p)
                cambiosDeActivo += 1
            } catch {
                if let texto = error.textoParaMostrar { fallo = texto }
            }
            activando = nil
        }
    }

    private func borrar(_ p: Perfil) {
        Task {
            do {
                try await catalogo.borrarPerfil(p)
            } catch {
                // Borrar el último lo rechaza el servidor (409) con su propio texto.
                if let texto = error.textoParaMostrar { fallo = texto }
            }
        }
    }

    private func salir() {
        cerrando = true
        Task {
            await sesion.salir()
            cerrando = false
        }
    }
}

enum HojaPerfil: Identifiable {
    case nuevo
    case editar(Perfil)

    var id: String {
        switch self {
        case .nuevo: return "nuevo"
        case .editar(let p): return "editar-\(p.id)"
        }
    }
}
