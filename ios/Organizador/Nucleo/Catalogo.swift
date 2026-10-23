// Perfiles de costos y filamentos: los usan la calculadora y Ajustes. Arranca
// con la copia del Almacen (así la calculadora sirve sin señal) y se refresca
// del servidor al abrir la app; cada cambio hecho desde Ajustes se guarda en
// la copia en cuanto el servidor lo acepta.
import Foundation
import Observation

@MainActor
@Observable
final class Catalogo {
    private(set) var perfiles: [Perfil]
    private(set) var filamentos: [Filamento]
    /// Nota pequeña cuando no se pudo refrescar (no bloquea nada).
    private(set) var aviso: String?
    private(set) var cargando = false

    @ObservationIgnored private let api = ClienteAPI.compartido

    /// Igual que la calculadora de escritorio cuando no tiene precio del dólar.
    static let dolarPorDefecto: Double = 3600

    init() {
        perfiles = Almacen.perfiles() ?? []
        filamentos = Almacen.filamentos() ?? []
    }

    /// El que el servidor marca como activo; si por algo no hay ninguno, el primero.
    var perfilActivo: Perfil? {
        perfiles.first(where: { $0.activo }) ?? perfiles.first
    }

    var hayDatos: Bool { !perfiles.isEmpty || !filamentos.isEmpty }

    /// Precio por kilo en pesos: la fórmula solo trabaja en COP. Un filamento
    /// en dólares se pasa con el precio del dólar del perfil.
    func precioKgCOP(_ filamento: Filamento, perfil: Perfil?) -> Double {
        switch filamento.moneda {
        case .cop:
            return filamento.precioKg
        case .usd:
            return filamento.precioKg * Catalogo.dolar(de: perfil)
        }
    }

    static func dolar(de perfil: Perfil?) -> Double {
        if let d = perfil?.precioDolar, d > 0 { return d }
        return dolarPorDefecto
    }

    // MARK: - Traer del servidor

    func recargar() async {
        guard !cargando else { return }
        cargando = true
        defer { cargando = false }
        var fallo: Error?
        do {
            let nuevos = try await api.perfiles()
            perfiles = nuevos
            Almacen.guardarPerfiles(nuevos)
        } catch {
            fallo = error
        }
        do {
            let nuevos = try await api.filamentos()
            filamentos = nuevos
            Almacen.guardarFilamentos(nuevos)
        } catch {
            fallo = fallo ?? error
        }
        if let fallo {
            if fallo is CancellationError { return }
            aviso = textoDeAviso(fallo)
        } else {
            aviso = nil
        }
    }

    // MARK: - Perfiles

    func activar(_ perfil: Perfil) async throws {
        let nuevo = try await api.editarPerfil(id: perfil.id, CambiosPerfil(activo: true))
        ponerPerfil(nuevo)
    }

    func crearPerfil(_ datos: PerfilNuevo) async throws -> Perfil {
        let nuevo = try await api.crearPerfil(datos)
        ponerPerfil(nuevo)
        return nuevo
    }

    func editarPerfil(id: Int, _ cambios: CambiosPerfil) async throws -> Perfil {
        let nuevo = try await api.editarPerfil(id: id, cambios)
        ponerPerfil(nuevo)
        return nuevo
    }

    func borrarPerfil(_ perfil: Perfil) async throws {
        do {
            try await api.borrarPerfil(id: perfil.id)
        } catch ErrorAPI.noExiste(_) {
            // Ya lo habían borrado (desde la web): el resultado es el mismo.
        }
        var quedan = perfiles.filter { $0.id != perfil.id }
        // El servidor le pasa la marca de activo al más antiguo que queda; se
        // hace igual aquí por si la recarga de abajo falla.
        if perfil.activo, let heredero = quedan.map(\.id).min() {
            quedan = quedan.map { $0.conActivo($0.id == heredero) }
        }
        perfiles = quedan
        Almacen.guardarPerfiles(quedan)
        if let delServidor = try? await api.perfiles() {
            perfiles = delServidor
            Almacen.guardarPerfiles(delServidor)
        }
    }

    // MARK: - Filamentos

    func crearFilamento(_ datos: FilamentoNuevo) async throws -> Filamento {
        let nuevo = try await api.crearFilamento(datos)
        filamentos.append(nuevo)
        Almacen.guardarFilamentos(filamentos)
        return nuevo
    }

    func editarFilamento(id: Int, _ cambios: CambiosFilamento) async throws -> Filamento {
        let nuevo = try await api.editarFilamento(id: id, cambios)
        if let i = filamentos.firstIndex(where: { $0.id == id }) {
            filamentos[i] = nuevo
        } else {
            filamentos.append(nuevo)
        }
        Almacen.guardarFilamentos(filamentos)
        return nuevo
    }

    func borrarFilamento(_ filamento: Filamento) async throws {
        do {
            try await api.borrarFilamento(id: filamento.id)
        } catch ErrorAPI.noExiste(_) {
            // Ya no estaba: se quita igual de la lista.
        }
        filamentos.removeAll { $0.id == filamento.id }
        Almacen.guardarFilamentos(filamentos)
    }

    // MARK: - Por dentro

    /// Pone el perfil que devolvió el servidor y, si quedó activo, apaga los
    /// demás (el servidor hace lo mismo en su lado).
    private func ponerPerfil(_ nuevo: Perfil) {
        var lista = perfiles
        if let i = lista.firstIndex(where: { $0.id == nuevo.id }) {
            lista[i] = nuevo
        } else {
            lista.append(nuevo)
        }
        if nuevo.activo {
            lista = lista.map { $0.id == nuevo.id ? $0 : $0.conActivo(false) }
        }
        perfiles = lista
        Almacen.guardarPerfiles(lista)
    }

    private func textoDeAviso(_ error: Error) -> String? {
        guard let e = error as? ErrorAPI else {
            return "No se pudieron actualizar los perfiles y filamentos."
        }
        let guardados = hayDatos ? " Se usan los datos guardados." : ""
        switch e {
        case .sinSesion:
            // De eso se encarga la Sesion: vuelve a la pantalla de entrar.
            return nil
        case .sinConexion:
            return "Sin conexión con el servidor." + guardados
        case .servidor(let texto), .noExiste(let texto):
            return texto + guardados
        case .datos, .llavero:
            return (e.errorDescription ?? "No se pudieron actualizar los datos.") + guardados
        }
    }
}

private extension Perfil {
    func conActivo(_ activo: Bool) -> Perfil {
        Perfil(id: id, nombre: nombre, precioKwh: precioKwh, consumoWatts: consumoWatts,
               vidaMaquinaH: vidaMaquinaH, precioRepuestos: precioRepuestos,
               margenError: margenError, precioDolar: precioDolar, activo: activo)
    }
}
