// Números y fechas como los escribe la web (servidor/web/app.js): miles con
// punto, meses cortos en minúscula y horas "3:02 p. m.", siempre vistas desde
// Bogotá. Se arman a mano para que no cambien según el idioma del iPhone.
import Foundation

enum Formato {
    static let mesesCortos = ["ene", "feb", "mar", "abr", "may", "jun",
                              "jul", "ago", "sep", "oct", "nov", "dic"]
    static let mesesLargos = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
                              "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
    /// En el orden de Calendar: 1 es domingo.
    static let diasSemana = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]

    static let calendario: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Fechas.bogota
        c.locale = Locale(identifier: "es_CO")
        return c
    }()

    /// 2837 -> "2.837".
    static func num(_ n: Int) -> String {
        let digitos = String(n.magnitude)
        var salida = ""
        for (i, c) in digitos.enumerated() {
            if i > 0 && (digitos.count - i) % 3 == 0 { salida.append(".") }
            salida.append(c)
        }
        return n < 0 ? "-" + salida : salida
    }

    /// Más que esto no cabe en un Int al multiplicar por los decimales.
    private static let tope: Double = 1e12

    /// 945.4 -> "$945"; 1234567 -> "$1.234.567"; -50 -> "-$50".
    static func pesos(_ valor: Double) -> String {
        // Int() de un número gigante (alguien escribió 1e20 gramos) cerraría la app.
        let acotado = valor.isFinite ? min(max(valor, -tope), tope) : 0
        let n = Int(acotado.rounded())
        return (n < 0 ? "-$" : "$") + num(abs(n))
    }

    /// Para leer en pantalla, con miles: 2.5 -> "2,5"; 5000 -> "5.000".
    static func decimal(_ valor: Double, maxDecimales: Int = 2) -> String {
        let (negativo, entero, fraccion) = partes(valor, maxDecimales: maxDecimales)
        return (negativo ? "-" : "") + num(entero) + fraccion
    }

    /// Para poner en un campo que se edita: sin puntos de miles, porque al
    /// leerlo de vuelta "150.000" sería 150. 150000 -> "150000"; 2.5 -> "2,5".
    static func editable(_ valor: Double, maxDecimales: Int = 2) -> String {
        let (negativo, entero, fraccion) = partes(valor, maxDecimales: maxDecimales)
        return (negativo ? "-" : "") + String(entero) + fraccion
    }

    /// Lee lo que se escribió en un campo numérico. El teclado decimal del
    /// iPhone en español pone coma; se aceptan coma y punto como decimal.
    static func leerNumero(_ texto: String) -> Double? {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !limpio.isEmpty, let n = Double(limpio), n.isFinite else { return nil }
        return n
    }

    /// 195 -> "3 h 15 min"; 45 -> "45 min"; 120 -> "2 h".
    static func horasMinutos(_ minutos: Double) -> String {
        let total = minutos.isFinite ? Int(min(max(0, minutos), tope).rounded()) : 0
        let h = total / 60
        let m = total % 60
        if h == 0 { return "\(m) min" }
        if m == 0 { return "\(num(h)) h" }
        return "\(num(h)) h \(m) min"
    }

    private static func partes(_ valor: Double, maxDecimales: Int) -> (Bool, Int, String) {
        guard valor.isFinite else { return (false, 0, "") }
        let acotado = min(max(valor, -tope), tope)
        let digitos = max(0, min(maxDecimales, 6))
        var escala = 1
        for _ in 0..<digitos { escala *= 10 }
        let total = Int((abs(acotado) * Double(escala)).rounded())
        let entero = total / escala
        var fraccion = total % escala
        var quedan = digitos
        // Sin ceros de sobra: 2,50 -> 2,5 y 3,00 -> 3.
        while quedan > 0 && fraccion % 10 == 0 {
            fraccion /= 10
            quedan -= 1
        }
        var texto = ""
        if quedan > 0 {
            let cifras = String(fraccion)
            texto = "," + String(repeating: "0", count: max(0, quedan - cifras.count)) + cifras
        }
        return (acotado < 0 && total > 0, entero, texto)
    }

    static func plural(_ n: Int, _ uno: String, _ varios: String) -> String {
        n == 1 ? uno : varios
    }

    /// '2026-11-20' -> "20 nov" o, con año, "20 nov 2026".
    static func entrega(_ texto: String?, conAnio: Bool = false) -> String? {
        guard let p = partesDia(texto) else { return nil }
        return "\(p.dia) \(mesesCortos[p.mes - 1])" + (conAnio ? " \(p.anio)" : "")
    }

    /// '2026-11-20' -> "20 de noviembre", para VoiceOver.
    static func entregaLarga(_ texto: String?) -> String? {
        guard let p = partesDia(texto) else { return nil }
        return "\(p.dia) de \(mesesLargos[p.mes - 1])"
    }

    private static func partesDia(_ texto: String?) -> (anio: Int, mes: Int, dia: Int)? {
        guard let texto else { return nil }
        let partes = texto.split(separator: "-").compactMap { Int($0) }
        guard partes.count == 3, (1...12).contains(partes[1]) else { return nil }
        return (anio: partes[0], mes: partes[1], dia: partes[2])
    }

    /// "3:02 p. m."
    static func hora(_ fecha: Date) -> String {
        let p = calendario.dateComponents([.hour, .minute], from: fecha)
        let h = p.hour ?? 0
        let m = p.minute ?? 0
        let h12 = h % 12 == 0 ? 12 : h % 12
        let minutos = m < 10 ? "0\(m)" : "\(m)"
        return "\(h12):\(minutos) " + (h < 12 ? "a. m." : "p. m.")
    }

    /// "Hoy", "Ayer", "22 oct" o, si es de otro año, "22 oct 2025".
    static func dia(_ fecha: Date, ahora: Date = Date()) -> String {
        if calendario.isDate(fecha, inSameDayAs: ahora) { return "Hoy" }
        if let ayer = calendario.date(byAdding: .day, value: -1, to: ahora),
           calendario.isDate(fecha, inSameDayAs: ayer) { return "Ayer" }
        let p = calendario.dateComponents([.year, .month, .day], from: fecha)
        let anioHoy = calendario.component(.year, from: ahora)
        var texto = "\(p.day ?? 1) \(mesesCortos[(p.month ?? 1) - 1])"
        if let anio = p.year, anio != anioHoy { texto += " \(anio)" }
        return texto
    }

    /// "Hoy 3:02 p. m."
    static func cuando(_ fecha: Date) -> String {
        "\(dia(fecha)) \(hora(fecha))"
    }

    /// Encabezado del historial: "Hoy · jueves 23 oct" o "martes 21 oct".
    static func encabezadoDia(_ fecha: Date, ahora: Date = Date()) -> String {
        let p = calendario.dateComponents([.year, .month, .day, .weekday], from: fecha)
        var texto = "\(diasSemana[((p.weekday ?? 1) - 1) % 7]) \(p.day ?? 1) \(mesesCortos[(p.month ?? 1) - 1])"
        if let anio = p.year, anio != calendario.component(.year, from: ahora) { texto += " \(anio)" }
        let relativo = dia(fecha, ahora: ahora)
        if relativo == "Hoy" || relativo == "Ayer" { return "\(relativo) · \(texto)" }
        return texto
    }

    /// "menos de 1 minuto", "40 minutos", "1 hora", "2 horas y 5 minutos".
    static func duracion(minutos: Int) -> String {
        if minutos < 1 { return "menos de 1 minuto" }
        if minutos < 60 { return "\(minutos) \(plural(minutos, "minuto", "minutos"))" }
        let h = minutos / 60
        let m = minutos % 60
        let horas = "\(num(h)) \(plural(h, "hora", "horas"))"
        return m == 0 ? horas : "\(horas) y \(m) \(plural(m, "minuto", "minutos"))"
    }

    // MARK: - Ritmo

    enum Tono { case normal, vencido, completo }

    /// La pastilla de la lista de pedidos. Un pedido terminado no lleva nada.
    static func pastillaRitmo(_ p: PedidoResumen) -> (texto: String, tono: Tono)? {
        guard p.estado == .abierto else { return nil }
        guard let r = p.ritmo else {
            if p.entrega == nil { return (texto: "Sin fecha de entrega", tono: Tono.normal) }
            return nil
        }
        if r.estaCompleto { return (texto: "Pedido completo", tono: Tono.completo) }
        if r.estaVencido { return (texto: vencidaHace(r.vencidoHace ?? 0), tono: Tono.vencido) }
        let fecha = entrega(p.entrega) ?? ""
        return (texto: "Entrega \(fecha) · \(num(r.porDia ?? 0)) al día", tono: Tono.normal)
    }

    /// La línea del detalle, igual que ritmoTexto() de la web.
    static func lineaRitmo(_ d: PedidoDetalle) -> (texto: String, tono: Tono)? {
        guard d.estado == .abierto else { return nil }
        guard let r = d.ritmo else {
            if d.entrega == nil { return (texto: "Sin fecha de entrega", tono: Tono.normal) }
            return nil
        }
        if r.estaCompleto { return (texto: "Pedido completo", tono: Tono.completo) }
        if r.estaVencido { return (texto: vencidaHace(r.vencidoHace ?? 0), tono: Tono.vencido) }
        let dias = r.dias ?? 0
        let texto = "Faltan \(num(d.avance.faltan)) en \(num(dias)) \(plural(dias, "día", "días")): "
            + "\(num(r.porDia ?? 0)) al día"
        return (texto: texto, tono: Tono.normal)
    }

    private static func vencidaHace(_ n: Int) -> String {
        "Entrega vencida hace \(num(n)) \(plural(n, "día", "días"))"
    }

    /// "Faltan 188", "Completo" o "Completo · 12 de más".
    static func notaModelo(_ m: Modelo) -> String {
        if m.completo {
            return m.deMas > 0 ? "Completo · \(num(m.deMas)) de más" : "Completo"
        }
        return "Faltan \(num(m.faltan))"
    }

    /// Iniciales para el recuadro sin foto: "Prof Completo" -> "PC".
    static func iniciales(_ nombre: String) -> String {
        let letras = nombre.split(separator: " ").prefix(2).compactMap { $0.first }
        return letras.isEmpty ? "?" : String(letras).uppercased()
    }
}
