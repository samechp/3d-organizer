// Fórmula de la calculadora de escritorio (calculate() en calculadora-3d/web_app/app.js),
// con mano de obra, horas invertidas, operario y preparación de máquina en 0.
// Solo Foundation: se compila suelto con swiftc en CI, sin SwiftUI.
import Foundation

/// Datos de la máquina y del taller que entran a la fórmula (no es el modelo de la API).
struct PerfilCalculo: Codable, Equatable {
    var precioKwh: Double
    var consumoWatts: Double
    var vidaMaquinaH: Double
    var precioRepuestos: Double
    /// Porcentaje (30 = 30 %).
    var margenError: Double
}

struct UsoFilamento: Equatable {
    var gramos: Double
    var precioKg: Double
}

/// Otra impresión de la misma pieza: suma sus horas y gramos a la cama.
struct ParteExtra: Equatable {
    var minutos: Double
    var filamentos: [UsoFilamento]
}

/// Se redondea hacia arriba, en múltiplos de COP.
enum Redondeo: Equatable {
    case ninguno, a500, a1000, a5000

    var multiplo: Double? {
        switch self {
        case .ninguno: return nil
        case .a500: return 500
        case .a1000: return 1000
        case .a5000: return 5000
        }
    }

    /// Igual que applyRedondeo del escritorio, en pesos.
    func aplicar(_ valor: Double) -> Double {
        guard let m = multiplo else { return valor }
        return (valor / m).rounded(.up) * m
    }
}

struct EntradaCalculo: Equatable {
    /// Minutos de impresión de la cama principal.
    var minutos: Double
    var filamentos: [UsoFilamento]
    var partes: [ParteExtra] = []
    var unidadesCama: Double
    /// Multiplicador sobre el costo base (3 = cobrar el triple).
    var margenGanancia: Double
    var insumos: Double = 0
    var insumosACobrar: Double? = nil
    var redondeo: Redondeo = .ninguno
}

struct ResultadoCalculo: Equatable {
    var costoBaseCama: Double
    var cobrarCama: Double
    var precioPieza: Double
    var costoPieza: Double
    var gananciaPieza: Double
    var horasConMargen: Double
    var gramosConMargen: Double
    var gramos: Double
}

func calcular(_ e: EntradaCalculo, perfil: PerfilCalculo) -> ResultadoCalculo {
    // Todo se calcula por cama; al final se reparte entre las unidades que caben.
    // Gramos <= 0 no cuentan (en el escritorio un filamento sin gramos no entra).
    let usos = (e.filamentos + e.partes.flatMap { $0.filamentos }).filter { $0.gramos > 0 }
    let gramos = usos.reduce(0) { $0 + $1.gramos }
    let costoMaterial = usos.reduce(0) { $0 + $1.gramos * $1.precioKg / 1000 }

    let minutosTotales = e.minutos + e.partes.reduce(0) { $0 + $1.minutos }
    let horas = minutosTotales / 60

    // Como en el escritorio, una vida de máquina en 0 se trata como 1 y 0 unidades como 1.
    let vida = perfil.vidaMaquinaH > 0 ? perfil.vidaMaquinaH : 1
    let unidades = e.unidadesCama > 0 ? e.unidadesCama : 1

    let costoLuz = (perfil.precioKwh * perfil.consumoWatts / 1000) * horas
    let costoDesgaste = (perfil.precioRepuestos / vida) * horas
    let costoError = (costoMaterial + costoLuz + costoDesgaste) * (perfil.margenError / 100)
    let costoBaseCama = costoMaterial + costoLuz + costoDesgaste + costoError

    // Si no se indica cuánto cobrar por los insumos (vacío o <= 0), se cobran al costo.
    let insumosCobrados: Double
    if let aCobrar = e.insumosACobrar, aCobrar > 0 {
        insumosCobrados = aCobrar
    } else {
        insumosCobrados = e.insumos
    }
    let cobrarCama = costoBaseCama * e.margenGanancia + insumosCobrados

    // El redondeo se aplica al precio de cada pieza, no a la cama.
    let precioPieza = e.redondeo.aplicar(cobrarCama / unidades)
    let costoPieza = costoBaseCama / unidades
    // La ganancia parte del precio ya redondeado y descuenta lo que costaron los insumos.
    let gananciaPieza = precioPieza - costoPieza - e.insumos / unidades

    // Margen de error también sobre tiempo y gramos: es el peor escenario que se le muestra al usuario.
    let factor = 1 + perfil.margenError / 100

    return ResultadoCalculo(
        costoBaseCama: costoBaseCama,
        cobrarCama: cobrarCama,
        precioPieza: precioPieza,
        costoPieza: costoPieza,
        gananciaPieza: gananciaPieza,
        horasConMargen: horas * factor,
        gramosConMargen: gramos * factor,
        gramos: gramos)
}
