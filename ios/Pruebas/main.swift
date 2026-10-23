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
