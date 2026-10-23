// Habla con https://sistema.printoverse.store. El token va en el llavero y se
// manda como 'Authorization: Bearer'; con Bearer el servidor no pide la
// cabecera X-Sistema (esa es solo para la cookie de la web).
// Si la tarea se cancela, los métodos lanzan CancellationError (no ErrorAPI).
import Foundation

enum ErrorAPI: Error, LocalizedError, Equatable {
    /// 401: la sesión venció o la cerraron desde otro lado; hay que entrar otra vez.
    case sinSesion
    /// Sin red, timeout o el servidor no contesta.
    case sinConexion
    /// El servidor contestó con un error; el texto ya viene listo para mostrar.
    case servidor(String)
    /// La respuesta no tiene la forma esperada.
    case datos
    /// El iPhone no dejó guardar el token en el llavero.
    case llavero

    var errorDescription: String? {
        switch self {
        case .sinSesion: return "La sesión se cerró. Vuelve a entrar."
        case .sinConexion: return "No hay conexión con el servidor. Revisa la señal e inténtalo de nuevo."
        case .servidor(let texto): return texto
        case .datos: return "El servidor respondió algo que la app no entiende."
        case .llavero: return "No se pudo guardar la sesión en este iPhone. Inténtalo de nuevo."
        }
    }
}

enum ResultadoTanda {
    case guardada(Tanda)
    /// No se guardó: ya hay una igual hace poco. Para guardarla igual, se
    /// reenvía con forzar: true.
    case parecida(TandaParecida)
}

extension Notification.Name {
    /// Se publica cuando el servidor responde 401: la Sesion la escucha y
    /// vuelve a la pantalla de entrar.
    static let sesionVencida = Notification.Name("store.printoverse.organizador.sesionVencida")
}

final class ClienteAPI {
    static let compartido = ClienteAPI()

    static let base = "https://sistema.printoverse.store"
    private let red: URLSession

    private let decodificador: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private let codificador: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        // Sin caché de URLSession: los pedidos cambian a cada tanda y una
        // respuesta vieja mostraría un avance que ya no es.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // El login también deja la cookie 'sesion' (es para la web). La app usa
        // solo el Bearer; sin esto la cookie viajaría sola en cada petición.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        red = URLSession(configuration: config)
    }

    // MARK: - Acceso

    /// Entra y guarda el token en el llavero. Devuelve el token.
    @discardableResult
    func entrar(correo: String, clave: String) async throws -> String {
        struct Credenciales: Encodable { let correo: String; let clave: String }
        let datos = try await pedir("POST", "/api/acceso", json: Credenciales(correo: correo, clave: clave),
                                    conSesion: false)
        let respuesta: RespuestaAcceso = try decodificar(datos)
        // Sin token guardado, la próxima petición daría "sin sesión": mejor
        // decirlo ahora que dejar entrar a medias.
        guard Llavero.guardar(respuesta.token) else { throw ErrorAPI.llavero }
        return respuesta.token
    }

    /// Cierra la sesión en el servidor si se puede; el token local se borra
    /// siempre, haya red o no.
    func salir() async {
        _ = try? await pedir("POST", "/api/salir", conSesion: false)
        Llavero.borrar()
    }

    func yo() async throws -> String {
        let r: RespuestaYo = try decodificar(try await pedir("GET", "/api/yo"))
        return r.correo
    }

    // MARK: - Pedidos

    func pedidos(estado: EstadoPedido? = nil) async throws -> [PedidoResumen] {
        var consulta: [URLQueryItem] = []
        if let estado { consulta.append(URLQueryItem(name: "estado", value: estado.rawValue)) }
        return try decodificar(try await pedir("GET", "/api/pedidos", consulta: consulta))
    }

    func pedido(id: Int) async throws -> PedidoDetalle {
        try decodificar(try await pedir("GET", "/api/pedidos/\(id)"))
    }

    func crearPedido(_ nuevo: PedidoNuevo) async throws -> PedidoDetalle {
        try decodificar(try await pedir("POST", "/api/pedidos", json: nuevo))
    }

    func editarPedido(id: Int, _ cambios: CambiosPedido) async throws -> PedidoDetalle {
        try decodificar(try await pedir("PATCH", "/api/pedidos/\(id)", json: cambios))
    }

    // MARK: - Modelos

    func agregarModelo(pedidoId: Int, _ nuevo: ModeloNuevo) async throws -> Modelo {
        try decodificar(try await pedir("POST", "/api/pedidos/\(pedidoId)/modelos", json: nuevo))
    }

    func editarModelo(id: Int, _ cambios: CambiosModelo) async throws -> Modelo {
        try decodificar(try await pedir("PATCH", "/api/modelos/\(id)", json: cambios))
    }

    func borrarModelo(id: Int) async throws {
        _ = try await pedir("DELETE", "/api/modelos/\(id)")
    }

    /// Sube la foto del modelo (JPEG, máximo 3 MB) y devuelve el modelo con su foto_url nueva.
    func subirFoto(modeloId: Int, jpeg: Data) async throws -> Modelo {
        let limite = "Limite-\(UUID().uuidString)"
        var cuerpo = Data()
        cuerpo.append(Data("--\(limite)\r\n".utf8))
        cuerpo.append(Data("Content-Disposition: form-data; name=\"foto\"; filename=\"foto.jpg\"\r\n".utf8))
        cuerpo.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        cuerpo.append(jpeg)
        cuerpo.append(Data("\r\n--\(limite)--\r\n".utf8))
        let datos = try await pedir("PUT", "/api/modelos/\(modeloId)/foto", cuerpo: cuerpo,
                                    tipo: "multipart/form-data; boundary=\(limite)", espera: 60)
        return try decodificar(datos)
    }

    /// Baja una foto (foto_url de un Modelo). Pide sesión, por eso no sirve AsyncImage.
    func foto(ruta: String) async throws -> Data {
        try await pedir("GET", ruta)
    }

    // MARK: - Tandas

    func tandas(pedidoId: Int, modeloId: Int? = nil) async throws -> [Tanda] {
        var consulta: [URLQueryItem] = []
        if let modeloId { consulta.append(URLQueryItem(name: "modelo_id", value: String(modeloId))) }
        return try decodificar(try await pedir("GET", "/api/pedidos/\(pedidoId)/tandas", consulta: consulta))
    }

    /// Anota una tanda. Reenviar la misma (mismo idCliente) es seguro: el
    /// servidor devuelve la que ya quedó y no la cuenta dos veces.
    func enviarTanda(_ tanda: TandaNueva, forzar: Bool = false) async throws -> ResultadoTanda {
        do {
            let datos = try await pedir("POST", "/api/tandas", json: CuerpoTanda(tanda, forzar: forzar))
            return .guardada(try decodificar(datos))
        } catch ErrorInterno.conflicto(let datos) {
            // Un 409 con {"parecida": {...}} no es un error: es la pregunta
            // "¿ya la anotaste?". Cualquier otro 409 sí se muestra como error.
            if let r = try? decodificador.decode(RespuestaParecida.self, from: datos) {
                return .parecida(r.parecida)
            }
            throw ErrorAPI.servidor(ClienteAPI.textoDeError(datos, codigo: 409))
        }
    }

    func editarTanda(id: Int, _ cambios: CambiosTanda) async throws -> Tanda {
        try decodificar(try await pedir("PATCH", "/api/tandas/\(id)", json: cambios))
    }

    func borrarTanda(id: Int) async throws {
        _ = try await pedir("DELETE", "/api/tandas/\(id)")
    }

    // MARK: - Perfiles

    func perfiles() async throws -> [Perfil] {
        try decodificar(try await pedir("GET", "/api/perfiles"))
    }

    func crearPerfil(_ nuevo: PerfilNuevo) async throws -> Perfil {
        try decodificar(try await pedir("POST", "/api/perfiles", json: nuevo))
    }

    func editarPerfil(id: Int, _ cambios: CambiosPerfil) async throws -> Perfil {
        try decodificar(try await pedir("PATCH", "/api/perfiles/\(id)", json: cambios))
    }

    func borrarPerfil(id: Int) async throws {
        _ = try await pedir("DELETE", "/api/perfiles/\(id)")
    }

    // MARK: - Filamentos

    func filamentos() async throws -> [Filamento] {
        try decodificar(try await pedir("GET", "/api/filamentos"))
    }

    func crearFilamento(_ nuevo: FilamentoNuevo) async throws -> Filamento {
        try decodificar(try await pedir("POST", "/api/filamentos", json: nuevo))
    }

    func editarFilamento(id: Int, _ cambios: CambiosFilamento) async throws -> Filamento {
        try decodificar(try await pedir("PATCH", "/api/filamentos/\(id)", json: cambios))
    }

    func borrarFilamento(id: Int) async throws {
        _ = try await pedir("DELETE", "/api/filamentos/\(id)")
    }

    // MARK: - Por dentro

    /// Solo lo usa enviarTanda: un 409 que hay que leer antes de decidir si es error.
    private enum ErrorInterno: Error {
        case conflicto(Data)
    }

    private func pedir<Cuerpo: Encodable>(_ metodo: String, _ ruta: String, json: Cuerpo,
                                          conSesion: Bool = true) async throws -> Data {
        let cuerpo: Data
        do {
            cuerpo = try codificador.encode(json)
        } catch {
            throw ErrorAPI.datos
        }
        return try await pedir(metodo, ruta, cuerpo: cuerpo, tipo: "application/json", conSesion: conSesion)
    }

    /// Hace la petición y devuelve el cuerpo de una respuesta 2xx. Todo lo
    /// demás sale como ErrorAPI.
    private func pedir(_ metodo: String, _ ruta: String, consulta: [URLQueryItem] = [],
                       cuerpo: Data? = nil, tipo: String? = nil, espera: TimeInterval = 20,
                       conSesion: Bool = true) async throws -> Data {
        // Las rutas empiezan con '/': se pegan al texto de la base tal cual.
        guard var partes = URLComponents(string: ClienteAPI.base + ruta) else { throw ErrorAPI.datos }
        if !consulta.isEmpty { partes.queryItems = consulta }
        guard let url = partes.url else { throw ErrorAPI.datos }

        var peticion = URLRequest(url: url)
        peticion.httpMethod = metodo
        peticion.timeoutInterval = espera
        peticion.setValue("application/json", forHTTPHeaderField: "Accept")
        if let tipo { peticion.setValue(tipo, forHTTPHeaderField: "Content-Type") }
        peticion.httpBody = cuerpo
        // /api/salir también lleva el token (para borrar la sesión en el
        // servidor), aunque un 401 ahí no cuenta como sesión vencida.
        let token = Llavero.leer()
        if let token { peticion.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if conSesion && token == nil {
            avisarSesionVencida(tokenUsado: nil)
            throw ErrorAPI.sinSesion
        }

        let resultado: (Data, URLResponse)
        do {
            resultado = try await red.data(for: peticion)
        } catch is CancellationError {
            // Cancelar (la vista se fue, se recargó) no es "sin conexión": quien
            // llama lo ignora en vez de mostrar un error.
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Sin red, timeout, certificado: no llegó al servidor.
            throw ErrorAPI.sinConexion
        }
        let (datos, respuesta) = resultado
        guard let http = respuesta as? HTTPURLResponse else { throw ErrorAPI.datos }

        switch http.statusCode {
        case 200...299:
            return datos
        case 401 where conSesion:
            avisarSesionVencida(tokenUsado: token)
            throw ErrorAPI.sinSesion
        case 409 where ruta == "/api/tandas" && metodo == "POST":
            throw ErrorInterno.conflicto(datos)
        case 502, 503, 504:
            // Es nginx diciendo que la app de atrás no contesta (reinicio,
            // despliegue): para quien llama es lo mismo que no tener señal, y así
            // la cola sin señal reintenta en vez de descartar la tanda.
            throw ErrorAPI.sinConexion
        default:
            throw ErrorAPI.servidor(ClienteAPI.textoDeError(datos, codigo: http.statusCode))
        }
    }

    private func decodificar<T: Decodable>(_ datos: Data) throws -> T {
        do {
            return try decodificador.decode(T.self, from: datos)
        } catch {
            throw ErrorAPI.datos
        }
    }

    /// Solo cuenta si el token rechazado sigue siendo el del llavero: un 401
    /// tardío de una petición hecha con el token viejo no debe borrar el
    /// nuevo de un login que pasó mientras tanto.
    private func avisarSesionVencida(tokenUsado: String?) {
        guard Llavero.leer() == tokenUsado else { return }
        if tokenUsado != nil { Llavero.borrar() }
        NotificationCenter.default.post(name: .sesionVencida, object: nil)
    }

    /// FastAPI manda {"detail": "texto"} en los errores propios, que ya están
    /// en español, y {"detail": [{"loc": [...], "msg": "..."}]} en los 422 de
    /// validación, cuyo texto viene en inglés: para esos se arma uno propio.
    static func textoDeError(_ datos: Data, codigo: Int) -> String {
        let objeto = try? JSONSerialization.jsonObject(with: datos)
        let detalle = (objeto as? [String: Any])?["detail"]
        if let texto = detalle as? String, !texto.isEmpty {
            return texto
        }
        if let lista = detalle as? [[String: Any]] {
            let campos = lista.compactMap { error -> String? in
                guard let loc = error["loc"] as? [Any], let ultimo = loc.last else { return nil }
                return nombreDeCampo(String(describing: ultimo))
            }
            if let primero = campos.first {
                return "Revisa \(primero): el valor no es válido."
            }
            return "Revisa los datos: hay un valor que no es válido."
        }
        switch codigo {
        case 404: return "Eso ya no existe en el servidor."
        case 413: return "La foto pesa demasiado."
        case 429: return "Demasiados intentos. Prueba de nuevo en 15 minutos."
        case 500...599: return "El servidor tuvo un problema. Inténtalo en un momento."
        default: return "El servidor respondió con un error (\(codigo))."
        }
    }

    private static func nombreDeCampo(_ clave: String) -> String {
        switch clave {
        case "cantidad": return "la cantidad"
        case "meta": return "la meta"
        case "nombre": return "el nombre"
        case "cliente": return "el cliente"
        case "entrega": return "la fecha de entrega"
        case "cuando": return "la hora"
        case "nota": return "la nota"
        case "correo": return "el correo"
        case "clave": return "la contraseña"
        case "precio_kwh": return "el precio del kWh"
        case "consumo_watts": return "el consumo"
        case "vida_maquina_h": return "la vida de la máquina"
        case "precio_repuestos": return "el precio de repuestos"
        case "margen_error": return "el margen de error"
        case "precio_dolar": return "el precio del dólar"
        case "precio_kg": return "el precio por kilo"
        case "hex": return "el color"
        case "marca": return "la marca"
        case "tipo": return "el tipo"
        case "color": return "el color"
        case "moneda": return "la moneda"
        default: return "los datos"
        }
    }
}
