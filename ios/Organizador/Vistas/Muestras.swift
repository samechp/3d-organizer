// Datos inventados para los #Preview de Xcode (los de la maqueta). La app
// nunca los muestra.
import Foundation

enum Muestras {
    static let resumen = PedidoResumen(
        id: 1, nombre: "Llaveros Ofero", cliente: "Ofero", entrega: "2026-11-20", estado: .abierto,
        numModelos: 4,
        avance: Avance(hechasTotal: 2849, metaTotal: 4000, contadas: 2837, faltan: 1163, porcentaje: 70),
        ritmo: Ritmo(completo: nil, dias: 29, porDia: 41, vencido: false, vencidoHace: nil))

    static let detalle = PedidoDetalle(
        id: 1, nombre: "Llaveros Ofero", cliente: "Ofero", entrega: "2026-11-20", estado: .abierto,
        numModelos: 4,
        avance: Avance(hechasTotal: 2849, metaTotal: 4000, contadas: 2837, faltan: 1163, porcentaje: 70),
        ritmo: Ritmo(completo: nil, dias: 29, porDia: 41, vencido: false, vencidoHace: nil),
        nota: nil, terminadoEn: nil,
        modelos: [
            Modelo(id: 1, nombre: "Prof Completo", meta: 1000, hechas: 812, fotoUrl: nil,
                   completo: false, deMas: 0, faltan: 188),
            Modelo(id: 2, nombre: "Prof Logo", meta: 1000, hechas: 645, fotoUrl: nil,
                   completo: false, deMas: 0, faltan: 355),
            Modelo(id: 3, nombre: "Rel Completo", meta: 1000, hechas: 1012, fotoUrl: nil,
                   completo: true, deMas: 12, faltan: 0),
            Modelo(id: 4, nombre: "Rel Logo", meta: 1000, hechas: 380, fotoUrl: nil,
                   completo: false, deMas: 0, faltan: 620),
        ],
        ultimasTandas: [
            Tanda(id: 2, modeloId: 1, modelo: "Prof Completo", cantidad: 50,
                  cuando: "2026-10-23T15:02:00-05:00", idCliente: nil),
            Tanda(id: 1, modeloId: 4, modelo: "Rel Logo", cantidad: 37,
                  cuando: "2026-10-23T11:18:00-05:00", idCliente: nil),
        ])
}
