// Lo que va y viene de la API (servidor/app/pedidos.py y perfiles.py).
// Las propiedades van en camelCase: JSONDecoder.convertFromSnakeCase y
// JSONEncoder.convertToSnakeCase hacen la traducción (ver ClienteAPI).
import Foundation

// MARK: - Fechas

/// El servidor manda las horas como '2026-10-23T15:02:00-05:00' y las fechas de
/// entrega como '2026-10-30'. Se guardan como texto en los modelos (así un
/// formato inesperado no rompe toda la lista) y se convierten con esto.
enum Fechas {
    static let bogota = TimeZone(identifier: "America/Bogota") ?? TimeZone(secondsFromGMT: -5 * 3600)!

    private static let conZona: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = bogota
        return f
    }()

    private static let conFracciones: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = bogota
        return f
    }()

    private static let dia: DateFormatter = {
        let f = DateFormatter()
        // en_US_POSIX: sin esto, un iPhone con calendario budista o japonés
        // escribiría otro año.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = bogota
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Lee una hora ISO 8601 con desfase, con o sin fracciones de segundo.
    static func hora(_ texto: String?) -> Date? {
        guard let texto, !texto.isEmpty else { return nil }
        return conZona.date(from: texto) ?? conFracciones.date(from: texto)
    }

    /// Escribe una hora con el desfase de Bogotá, como la espera el servidor.
    static func textoHora(_ fecha: Date) -> String {
        conZona.string(from: fecha)
    }

    /// Lee una fecha de entrega ('2026-10-30') como medianoche en Bogotá.
    static func diaDeEntrega(_ texto: String?) -> Date? {
        guard let texto, !texto.isEmpty else { return nil }
        return dia.date(from: texto)
    }

    static func textoDia(_ fecha: Date) -> String {
        dia.string(from: fecha)
    }
}

// MARK: - Acceso

struct RespuestaAcceso: Decodable {
    let token: String
    let correo: String
}

struct RespuestaYo: Decodable {
    let correo: String
}

// MARK: - Pedidos

enum EstadoPedido: String, Codable, Hashable {
    case abierto, terminado
}

struct Avance: Codable, Hashable {
    let hechasTotal: Int
    let metaTotal: Int
    /// Cada modelo aporta como máximo su meta; por eso no es igual a hechasTotal.
    let contadas: Int
    let faltan: Int
    let porcentaje: Int
}

/// El servidor manda una de tres formas: {"completo": true},
/// {"dias", "por_dia", "vencido": false} o {"dias", "por_dia": null,
/// "vencido": true, "vencido_hace"}. Por eso todo es opcional.
struct Ritmo: Codable, Hashable {
    let completo: Bool?
    let dias: Int?
    let porDia: Int?
    let vencido: Bool?
    let vencidoHace: Int?

    var estaCompleto: Bool { completo ?? false }
    var estaVencido: Bool { vencido ?? false }
}

struct Modelo: Codable, Hashable, Identifiable {
    let id: Int
    let nombre: String
    let meta: Int
    let hechas: Int
    /// Ruta relativa ('/api/fotos/<hash>.jpg'); pide sesión, así que se baja con
    /// ClienteAPI.foto(ruta:) y no con AsyncImage.
    let fotoUrl: String?
    let completo: Bool
    let deMas: Int
    let faltan: Int
}

struct Tanda: Codable, Hashable, Identifiable {
    let id: Int
    let modeloId: Int
    /// Nombre del modelo, para las listas.
    let modelo: String
    let cantidad: Int
    let cuando: String
    let idCliente: String?

    var fecha: Date? { Fechas.hora(cuando) }
}

/// La tanda que ya existe y se parece a la que se quiso anotar (respuesta 409).
struct TandaParecida: Codable, Hashable, Identifiable {
    let id: Int
    let cantidad: Int
    let cuando: String
    let haceMinutos: Int

    var fecha: Date? { Fechas.hora(cuando) }
}

struct RespuestaParecida: Decodable {
    let parecida: TandaParecida
}

struct PedidoResumen: Codable, Hashable, Identifiable {
    let id: Int
    let nombre: String
    let cliente: String?
    /// 'yyyy-MM-dd' o nil.
    let entrega: String?
    let estado: EstadoPedido
    let numModelos: Int
    let avance: Avance
    /// nil si no hay fecha de entrega o el pedido está terminado.
    let ritmo: Ritmo?

    var fechaEntrega: Date? { Fechas.diaDeEntrega(entrega) }
}

struct PedidoDetalle: Codable, Hashable, Identifiable {
    let id: Int
    let nombre: String
    let cliente: String?
    let entrega: String?
    let estado: EstadoPedido
    let numModelos: Int
    let avance: Avance
    let ritmo: Ritmo?
    let nota: String?
    let terminadoEn: String?
    let modelos: [Modelo]
    let ultimasTandas: [Tanda]

    var fechaEntrega: Date? { Fechas.diaDeEntrega(entrega) }
}

// MARK: - Lo que se manda

/// Para los PATCH: distingue "no tocar" (no se manda la clave) de "borrar"
/// (se manda null), que el servidor trata distinto.
enum CampoOpcional<Valor: Encodable & Hashable>: Hashable {
    case sinCambio
    case borrar
    case poner(Valor)
}

extension KeyedEncodingContainer {
    mutating func codificar<Valor: Encodable & Hashable>(_ campo: CampoOpcional<Valor>, clave: Key) throws {
        switch campo {
        case .sinCambio: break
        case .borrar: try encodeNil(forKey: clave)
        case .poner(let valor): try encode(valor, forKey: clave)
        }
    }
}

struct ModeloNuevo: Codable, Hashable {
    var nombre: String
    var meta: Int
}

struct PedidoNuevo: Codable, Hashable {
    var nombre: String
    var cliente: String?
    /// 'yyyy-MM-dd' (Fechas.textoDia).
    var entrega: String?
    var nota: String?
    var modelos: [ModeloNuevo]
}

struct CambiosPedido: Encodable, Hashable {
    var nombre: String? = nil
    var cliente: CampoOpcional<String> = .sinCambio
    /// 'yyyy-MM-dd' (Fechas.textoDia).
    var entrega: CampoOpcional<String> = .sinCambio
    var nota: CampoOpcional<String> = .sinCambio
    var estado: EstadoPedido? = nil

    enum CodingKeys: String, CodingKey {
        case nombre, cliente, entrega, nota, estado
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(nombre, forKey: .nombre)
        try c.codificar(cliente, clave: .cliente)
        try c.codificar(entrega, clave: .entrega)
        try c.codificar(nota, clave: .nota)
        try c.encodeIfPresent(estado, forKey: .estado)
    }
}

struct CambiosModelo: Encodable, Hashable {
    var nombre: String? = nil
    var meta: Int? = nil
}

/// Una tanda por enviar. Es Codable para que la cola sin señal (Task 9) la
/// guarde en disco tal cual; a la API se manda con otra forma (CuerpoTanda).
struct TandaNueva: Codable, Hashable, Identifiable {
    /// Lo pone el iPhone una sola vez: si la tanda se reenvía (timeout, cola),
    /// el servidor la reconoce por esto y no la cuenta dos veces.
    var idCliente: UUID
    var modeloId: Int
    var cantidad: Int
    /// nil = ahora (la hora la pone el servidor).
    var cuando: Date?

    var id: UUID { idCliente }

    init(idCliente: UUID = UUID(), modeloId: Int, cantidad: Int, cuando: Date? = nil) {
        self.idCliente = idCliente
        self.modeloId = modeloId
        self.cantidad = cantidad
        self.cuando = cuando
    }
}

/// El JSON de POST /api/tandas.
struct CuerpoTanda: Encodable {
    let idCliente: String
    let modeloId: Int
    let cantidad: Int
    let cuando: String?
    let forzar: Bool

    init(_ tanda: TandaNueva, forzar: Bool) {
        idCliente = tanda.idCliente.uuidString.lowercased()
        modeloId = tanda.modeloId
        cantidad = tanda.cantidad
        cuando = tanda.cuando.map { Fechas.textoHora($0) }
        self.forzar = forzar
    }
}

struct CambiosTanda: Encodable, Hashable {
    var cantidad: Int? = nil
    /// Hora ISO con desfase (Fechas.textoHora).
    var cuando: String? = nil
}

// MARK: - Perfiles y filamentos

struct Perfil: Codable, Hashable, Identifiable {
    let id: Int
    let nombre: String
    let precioKwh: Double
    let consumoWatts: Double
    let vidaMaquinaH: Double
    let precioRepuestos: Double
    /// Porcentaje (30 = 30 %).
    let margenError: Double
    let precioDolar: Double?
    let activo: Bool

    /// Lo que necesita la fórmula de la calculadora.
    var calculo: PerfilCalculo {
        PerfilCalculo(precioKwh: precioKwh, consumoWatts: consumoWatts,
                      vidaMaquinaH: vidaMaquinaH, precioRepuestos: precioRepuestos,
                      margenError: margenError)
    }
}

struct PerfilNuevo: Codable, Hashable {
    var nombre: String
    var precioKwh: Double
    var consumoWatts: Double
    var vidaMaquinaH: Double
    var precioRepuestos: Double
    var margenError: Double
    var precioDolar: Double?
    var activo: Bool = false
}

struct CambiosPerfil: Encodable, Hashable {
    var nombre: String? = nil
    var precioKwh: Double? = nil
    var consumoWatts: Double? = nil
    var vidaMaquinaH: Double? = nil
    var precioRepuestos: Double? = nil
    var margenError: Double? = nil
    var precioDolar: CampoOpcional<Double> = .sinCambio
    var activo: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case nombre, precioKwh, consumoWatts, vidaMaquinaH, precioRepuestos, margenError, precioDolar, activo
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(nombre, forKey: .nombre)
        try c.encodeIfPresent(precioKwh, forKey: .precioKwh)
        try c.encodeIfPresent(consumoWatts, forKey: .consumoWatts)
        try c.encodeIfPresent(vidaMaquinaH, forKey: .vidaMaquinaH)
        try c.encodeIfPresent(precioRepuestos, forKey: .precioRepuestos)
        try c.encodeIfPresent(margenError, forKey: .margenError)
        try c.codificar(precioDolar, clave: .precioDolar)
        try c.encodeIfPresent(activo, forKey: .activo)
    }
}

enum Moneda: String, Codable, Hashable, CaseIterable {
    case cop = "COP"
    case usd = "USD"
}

struct Filamento: Codable, Hashable, Identifiable {
    let id: Int
    let marca: String
    let tipo: String
    let color: String
    /// '#RRGGBB' o nil.
    let hex: String?
    let precioKg: Double
    let moneda: Moneda
}

struct FilamentoNuevo: Codable, Hashable {
    var marca: String
    var tipo: String
    var color: String
    var hex: String?
    var precioKg: Double
    var moneda: Moneda
}

struct CambiosFilamento: Encodable, Hashable {
    var marca: String? = nil
    var tipo: String? = nil
    var color: String? = nil
    var hex: CampoOpcional<String> = .sinCambio
    var precioKg: Double? = nil
    var moneda: Moneda? = nil

    enum CodingKeys: String, CodingKey {
        case marca, tipo, color, hex, precioKg, moneda
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(marca, forKey: .marca)
        try c.encodeIfPresent(tipo, forKey: .tipo)
        try c.encodeIfPresent(color, forKey: .color)
        try c.codificar(hex, clave: .hex)
        try c.encodeIfPresent(precioKg, forKey: .precioKg)
        try c.encodeIfPresent(moneda, forKey: .moneda)
    }
}
