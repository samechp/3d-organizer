// Pruebas de la lógica pura. En CI (desde ios/) se compilan con:
//   swiftc Organizador/Puro/*.swift Pruebas/main.swift -o pruebas && ./pruebas
// Cada prueba devuelve la lista de fallos (vacía si pasó); para sumar pruebas,
// basta con agregar otro `Prueba(...)` a la lista antes del bloque que las corre.
import Foundation

struct Prueba {
    let nombre: String
    let correr: () -> [String]
}

/// Compara con tolerancia de 0,01 (los valores de referencia vienen de la calculadora de escritorio).
func esperarCerca(_ etiqueta: String, _ real: Double, _ esperado: Double) -> String? {
    abs(real - esperado) <= 0.01 ? nil : "\(etiqueta): salió \(real), se esperaba \(esperado)"
}

// Perfil AD5M Casa y PLA a 70.000 por kg: los de los valores de referencia.
let perfilAD5M = PerfilCalculo(
    precioKwh: 655, consumoWatts: 350, vidaMaquinaH: 5000,
    precioRepuestos: 150000, margenError: 30)
let pla = UsoFilamento(gramos: 60, precioKg: 70000)

func entradaBase() -> EntradaCalculo {
    EntradaCalculo(minutos: 150, filamentos: [pla], unidadesCama: 20, margenGanancia: 3)
}

var pruebas: [Prueba] = []

pruebas.append(Prueba(nombre: "caso base sin redondeo") {
    let r = calcular(entradaBase(), perfil: perfilAD5M)
    return [
        esperarCerca("costoBaseCama", r.costoBaseCama, 6302.5625),
        esperarCerca("cobrarCama", r.cobrarCama, 18907.6875),
        esperarCerca("precioPieza", r.precioPieza, 945.384375),
        esperarCerca("costoPieza", r.costoPieza, 315.128125),
        esperarCerca("gananciaPieza", r.gananciaPieza, 630.25625),
        esperarCerca("horasConMargen", r.horasConMargen, 3.25),
        esperarCerca("gramosConMargen", r.gramosConMargen, 78),
        esperarCerca("gramos", r.gramos, 60),
    ].compactMap { $0 }
})

pruebas.append(Prueba(nombre: "insumos 2000 cobrando 3000") {
    var e = entradaBase()
    e.insumos = 2000
    e.insumosACobrar = 3000
    let r = calcular(e, perfil: perfilAD5M)
    return [
        esperarCerca("cobrarCama", r.cobrarCama, 21907.6875),
        esperarCerca("gananciaPieza", r.gananciaPieza, 680.25625),
    ].compactMap { $0 }
})

pruebas.append(Prueba(nombre: "insumos 2000 sin a cobrar: se cobran los insumos") {
    var e = entradaBase()
    e.insumos = 2000
    let r = calcular(e, perfil: perfilAD5M)
    return [esperarCerca("cobrarCama", r.cobrarCama, 20907.6875)].compactMap { $0 }
})

pruebas.append(Prueba(nombre: "insumos a cobrar en 0 o negativo cae a insumos") {
    var e = entradaBase()
    e.insumos = 2000
    e.insumosACobrar = 0
    var fallos = [esperarCerca("con 0", calcular(e, perfil: perfilAD5M).cobrarCama, 20907.6875)]
    e.insumosACobrar = -5
    fallos.append(esperarCerca("con -5", calcular(e, perfil: perfilAD5M).cobrarCama, 20907.6875))
    return fallos.compactMap { $0 }
})

pruebas.append(Prueba(nombre: "parte extra de 60 min y 20 g") {
    var e = entradaBase()
    e.partes = [ParteExtra(minutos: 60, filamentos: [UsoFilamento(gramos: 20, precioKg: 70000)])]
    let r = calcular(e, perfil: perfilAD5M)
    return [
        esperarCerca("costoBaseCama", r.costoBaseCama, 8459.5875),
        esperarCerca("precioPieza", r.precioPieza, 1268.938125),
        esperarCerca("horasConMargen", r.horasConMargen, 4.55),
        esperarCerca("gramos", r.gramos, 80),
        esperarCerca("gramosConMargen", r.gramosConMargen, 104),
    ].compactMap { $0 }
})

pruebas.append(Prueba(nombre: "redondeo a 500 sube el precio y la ganancia lo usa") {
    var e = entradaBase()
    e.redondeo = .a500
    let r = calcular(e, perfil: perfilAD5M)
    return [
        esperarCerca("precioPieza", r.precioPieza, 1000),
        esperarCerca("gananciaPieza", r.gananciaPieza, 1000 - 315.128125),
    ].compactMap { $0 }
})

pruebas.append(Prueba(nombre: "redondeo a 1000 y a 5000") {
    var e = entradaBase()
    e.redondeo = .a1000
    var fallos = [esperarCerca("a1000", calcular(e, perfil: perfilAD5M).precioPieza, 1000)]
    e.redondeo = .a5000
    fallos.append(esperarCerca("a5000", calcular(e, perfil: perfilAD5M).precioPieza, 5000))
    return fallos.compactMap { $0 }
})

pruebas.append(Prueba(nombre: "unidades 0 o vida de la maquina 0 no dividen entre cero") {
    var e = entradaBase()
    e.unidadesCama = 0
    var perfil = perfilAD5M
    perfil.vidaMaquinaH = 0
    let r = calcular(e, perfil: perfil)
    let finito = r.precioPieza.isFinite && r.costoPieza.isFinite && r.gananciaPieza.isFinite
    return finito ? [] : ["el resultado no es finito"]
})

// MARK: - Cola de tandas sin señal

/// Corre una prueba async desde el arnés síncrono. El trabajo va en una tarea
/// suelta (no en el hilo principal, que queda esperando).
final class Caja<T>: @unchecked Sendable {
    var valor: T
    init(_ valor: T) { self.valor = valor }
}

func esperar(_ trabajo: @escaping () async -> [String]) -> [String] {
    let listo = DispatchSemaphore(value: 0)
    let resultado = Caja<[String]>([])
    Task.detached {
        resultado.valor = await trabajo()
        listo.signal()
    }
    listo.wait()
    return resultado.valor
}

/// Lo que el enviador falso recibió. Con cerrojo: dos vaciados podrían llamarlo a la vez.
final class Registro: @unchecked Sendable {
    private let cerrojo = NSLock()
    private var lista: [TandaPendiente] = []
    func anotar(_ t: TandaPendiente) { cerrojo.lock(); lista.append(t); cerrojo.unlock() }
    var enviadas: [TandaPendiente] { cerrojo.lock(); defer { cerrojo.unlock() }; return lista }
}

func archivoTemporal() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cola-prueba-\(UUID().uuidString).json")
}

func tandaDePrueba(_ cantidad: Int) -> TandaPendiente {
    TandaPendiente(idCliente: UUID(), modeloId: 7, cantidad: cantidad,
                   cuando: Date(timeIntervalSince1970: 1_800_000_000 + Double(cantidad)))
}

pruebas.append(Prueba(nombre: "pruebaColaEnviaEnOrden") {
    esperar {
        let registro = Registro()
        let cola = ColaTandas(archivo: archivoTemporal()) { t in
            registro.anotar(t)
            return .enviada
        }
        let tandas = [tandaDePrueba(50), tandaDePrueba(37), tandaDePrueba(80)]
        tandas.forEach { cola.agregar($0) }
        await cola.vaciar()
        var fallos: [String] = []
        if registro.enviadas != tandas { fallos.append("el orden de envío no es el de anotación") }
        if !cola.pendientes.isEmpty { fallos.append("quedaron \(cola.pendientes.count) pendientes") }
        return fallos
    }
})

/// Con el enviador deteniéndose en la segunda: la primera sale y las otras quedan.
func pruebaSeDetiene() -> [String] {
    esperar {
        let registro = Registro()
        let cola = ColaTandas(archivo: archivoTemporal()) { t in
            registro.anotar(t)
            return registro.enviadas.count == 1 ? .enviada : .detener
        }
        let tandas = [tandaDePrueba(1), tandaDePrueba(2), tandaDePrueba(3)]
        tandas.forEach { cola.agregar($0) }
        await cola.vaciar()
        var fallos: [String] = []
        if cola.pendientes != Array(tandas.dropFirst()) {
            fallos.append("se esperaban las 2 últimas pendientes, hay \(cola.pendientes.count)")
        }
        if registro.enviadas.count != 2 { fallos.append("siguió enviando después de detenerse") }
        if !cola.descartadas.isEmpty { fallos.append("descartó algo al detenerse") }
        return fallos
    }
}

// En la app, sinConexion y sinSesion llegan los dos como .detener (Nucleo/Envios.swift).
pruebas.append(Prueba(nombre: "pruebaColaSinConexionNoBorra") { pruebaSeDetiene() })
pruebas.append(Prueba(nombre: "pruebaColaSinSesionNoBorra") { pruebaSeDetiene() })

pruebas.append(Prueba(nombre: "pruebaColaSobreviveReinicio") {
    let archivo = archivoTemporal()
    let primera = ColaTandas(archivo: archivo) { _ in .detener }
    let tandas = [tandaDePrueba(50), tandaDePrueba(12)]
    tandas.forEach { primera.agregar($0) }
    let segunda = ColaTandas(archivo: archivo) { _ in .detener }
    return segunda.pendientes == tandas ? [] : ["la cola leída del archivo no es la misma"]
})

pruebas.append(Prueba(nombre: "pruebaDosVaciadosALaVezEnvianUnaVez") {
    esperar {
        let registro = Registro()
        let cola = ColaTandas(archivo: archivoTemporal()) { t in
            registro.anotar(t)
            // Lento a propósito: el segundo vaciado arranca mientras el primero espera.
            try? await Task.sleep(nanoseconds: 50_000_000)
            return .enviada
        }
        cola.agregar(tandaDePrueba(50))
        cola.agregar(tandaDePrueba(37))
        async let uno: Void = cola.vaciar()
        async let dos: Void = cola.vaciar()
        _ = await (uno, dos)
        var fallos: [String] = []
        if registro.enviadas.count != 2 { fallos.append("se enviaron \(registro.enviadas.count) en vez de 2") }
        if !cola.pendientes.isEmpty { fallos.append("quedaron pendientes") }
        return fallos
    }
})

pruebas.append(Prueba(nombre: "descartada se quita de la cola y se guarda con su motivo") {
    esperar {
        let archivo = archivoTemporal()
        let cola = ColaTandas(archivo: archivo) { t in
            t.cantidad == 2 ? .descartar("No existe ese modelo") : .enviada
        }
        [tandaDePrueba(1), tandaDePrueba(2), tandaDePrueba(3)].forEach { cola.agregar($0) }
        await cola.vaciar()
        let releida = ColaTandas(archivo: archivo) { _ in .detener }
        var fallos: [String] = []
        if !cola.pendientes.isEmpty { fallos.append("quedaron pendientes") }
        if releida.descartadas.map({ $0.motivo }) != ["No existe ese modelo"] {
            fallos.append("la descartada no quedó guardada con su motivo")
        }
        return fallos
    }
})

pruebas.append(Prueba(nombre: "cola escrita antes de nombreModelo se sigue leyendo") {
    // Lo que escribía la versión 5f80d44: sin nombreModelo.
    let viejo = """
    {"pendientes":[{"idCliente":"8F2D3B1C-0000-4000-8000-000000000001","modeloId":7,"cantidad":50,"cuando":800000000}],
     "descartadas":[{"tanda":{"idCliente":"8F2D3B1C-0000-4000-8000-000000000002","modeloId":7,"cantidad":3,"cuando":800000000},"motivo":"No existe ese modelo"}]}
    """
    let archivo = archivoTemporal()
    do {
        try Data(viejo.utf8).write(to: archivo)
    } catch {
        return ["no se pudo escribir el archivo de prueba"]
    }
    let cola = ColaTandas(archivo: archivo) { _ in .detener }
    var fallos: [String] = []
    if cola.pendientes.map({ $0.cantidad }) != [50] { fallos.append("no leyó la pendiente vieja") }
    if cola.pendientes.first?.nombreModelo != nil { fallos.append("nombreModelo debería quedar en nil") }
    if cola.descartadas.map({ $0.motivo }) != ["No existe ese modelo"] { fallos.append("no leyó la descartada vieja") }
    return fallos
})

pruebas.append(Prueba(nombre: "el nombre del modelo se guarda con la tanda") {
    let archivo = archivoTemporal()
    var t = tandaDePrueba(50)
    t.nombreModelo = "Prof Completo"
    ColaTandas(archivo: archivo) { _ in .detener }.agregar(t)
    let releida = ColaTandas(archivo: archivo) { _ in .detener }
    return releida.pendientes.first?.nombreModelo == "Prof Completo" ? [] : ["se perdió el nombre del modelo"]
})

pruebas.append(Prueba(nombre: "regla de 3 horas igual a la del servidor") {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var fallos: [String] = []
    if !ReglaParecida.esParecida(cantidad: 50, cuando: base, otraCantidad: 50,
                                 otroCuando: base.addingTimeInterval(-3 * 3600)) {
        fallos.append("a 3 h justas debería ser parecida")
    }
    if ReglaParecida.esParecida(cantidad: 50, cuando: base, otraCantidad: 50,
                                otroCuando: base.addingTimeInterval(3 * 3600 + 60)) {
        fallos.append("a 3 h 1 min no debería ser parecida")
    }
    if ReglaParecida.esParecida(cantidad: 50, cuando: base, otraCantidad: 49, otroCuando: base) {
        fallos.append("con otra cantidad no debería ser parecida")
    }
    return fallos
})

// Corre todo y sale con código distinto de cero si algo falló.
var huboFallas = false
for prueba in pruebas {
    let fallos = prueba.correr()
    if fallos.isEmpty {
        print("OK \(prueba.nombre)")
    } else {
        huboFallas = true
        print("FALLA \(prueba.nombre)")
        for fallo in fallos { print("    \(fallo)") }
    }
}
if huboFallas { exit(1) }
