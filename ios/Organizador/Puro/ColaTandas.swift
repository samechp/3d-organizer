// Cola de tandas anotadas sin señal (o con la sesión vencida). Se guarda en
// disco con cada cambio: si la app se cierra antes de que vuelva la red, las
// tandas siguen ahí al abrirla.
//
// Solo Foundation: se compila también suelta con swiftc para las pruebas, con un
// enviador falso. Es una clase con cerrojo y no un actor para que las pruebas
// (síncronas) la usen sin más ceremonia; el cerrojo nunca se sostiene durante
// un envío, solo mientras se lee o cambia la lista.
import Foundation

struct TandaPendiente: Codable, Equatable {
    /// El mismo id con que se intentó la primera vez: si ese envío sí llegó
    /// (timeout), el servidor reconoce el reintento y no la cuenta dos veces.
    var idCliente: UUID
    var modeloId: Int
    var cantidad: Int
    /// Hora fija desde que se anotó: si se mandara sin hora, el servidor pondría
    /// la de cuando vuelve la señal.
    var cuando: Date
    /// Para mostrarla si el servidor la rechaza, aunque ya no esté guardado el
    /// pedido. Opcional: las colas escritas antes de existir este campo se
    /// siguen leyendo.
    var nombreModelo: String? = nil
}

/// Una tanda que el servidor rechazó (el modelo ya no existe, una cantidad no
/// válida). No se borra en silencio: se le muestra a Juan con el motivo.
struct TandaDescartada: Codable, Equatable {
    var tanda: TandaPendiente
    var motivo: String
}

enum ResultadoEnvio {
    /// Quedó guardada (o ya estaba): se quita de la cola.
    case enviada
    /// Sin red o sin sesión: se para aquí sin quitar nada y se reintenta después.
    case detener
    /// El servidor no la acepta y reintentar no lo va a cambiar.
    case descartar(String)
}

final class ColaTandas: @unchecked Sendable {
    private struct Contenido: Codable {
        var pendientes: [TandaPendiente] = []
        var descartadas: [TandaDescartada] = []
    }

    private let archivo: URL
    private let enviar: (TandaPendiente) async -> ResultadoEnvio
    private let cerrojo = NSLock()
    private var contenido = Contenido()
    private var vaciando = false

    /// Se llama (fuera del cerrojo, desde cualquier hilo) después de cada cambio.
    var alCambiar: (() -> Void)?

    init(archivo: URL, enviar: @escaping (TandaPendiente) async -> ResultadoEnvio) {
        self.archivo = archivo
        self.enviar = enviar
        if let datos = try? Data(contentsOf: archivo),
           let leido = try? JSONDecoder().decode(Contenido.self, from: datos) {
            contenido = leido
        }
    }

    var pendientes: [TandaPendiente] {
        conCerrojo { contenido.pendientes }
    }

    var descartadas: [TandaDescartada] {
        conCerrojo { contenido.descartadas }
    }

    func agregar(_ tanda: TandaPendiente) {
        cambiar { c in
            // La misma tanda dos veces (dos toques) sigue siendo una sola.
            guard !c.pendientes.contains(where: { $0.idCliente == tanda.idCliente }) else { return }
            c.pendientes.append(tanda)
        }
    }

    /// Manda las pendientes en el orden en que se anotaron. Si ya hay un
    /// vaciado en curso (vuelve la red y la app pasa a primer plano a la vez),
    /// este no hace nada: el otro ya las está mandando.
    func vaciar() async {
        guard tomarVaciado() else { return }
        defer { soltarVaciado() }
        while let tanda = primera() {
            let resultado = await enviar(tanda)
            switch resultado {
            case .enviada:
                cambiar { c in c.pendientes.removeAll { $0.idCliente == tanda.idCliente } }
            case .descartar(let motivo):
                cambiar { c in
                    c.pendientes.removeAll { $0.idCliente == tanda.idCliente }
                    c.descartadas.append(TandaDescartada(tanda: tanda, motivo: motivo))
                }
            case .detener:
                return
            }
        }
    }

    /// Vuelve a poner las descartadas en la cola (por ejemplo, después de un
    /// error del servidor que ya se arregló).
    func reintentarDescartadas() {
        cambiar { c in
            for d in c.descartadas where !c.pendientes.contains(where: { $0.idCliente == d.tanda.idCliente }) {
                c.pendientes.append(d.tanda)
            }
            c.descartadas.removeAll()
        }
    }

    func olvidarDescartadas() {
        cambiar { c in c.descartadas.removeAll() }
    }

    // MARK: - Por dentro

    // Funciones síncronas a propósito: el cerrojo no se puede tomar en una
    // función async (podría soltarse en otro hilo después de un await).
    private func conCerrojo<T>(_ hacer: () -> T) -> T {
        cerrojo.lock()
        defer { cerrojo.unlock() }
        return hacer()
    }

    private func tomarVaciado() -> Bool {
        conCerrojo {
            if vaciando { return false }
            vaciando = true
            return true
        }
    }

    private func soltarVaciado() {
        conCerrojo { vaciando = false }
    }

    private func primera() -> TandaPendiente? {
        conCerrojo { contenido.pendientes.first }
    }

    private func cambiar(_ hacer: (inout Contenido) -> Void) {
        conCerrojo {
            hacer(&contenido)
            guardar()
        }
        alCambiar?()
    }

    /// Escritura atómica: un corte a mitad deja el archivo anterior entero, no
    /// uno a medias que ya no se pueda leer.
    private func guardar() {
        guard let datos = try? JSONEncoder().encode(contenido) else { return }
        try? FileManager.default.createDirectory(at: archivo.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? datos.write(to: archivo, options: .atomic)
    }
}

/// La regla de "¿ya la anotaste?" de servidor/app/calculos.py (es_parecida):
/// misma cantidad y a 3 horas o menos, en cualquier dirección. Si cambia allá,
/// hay que cambiarla aquí.
enum ReglaParecida {
    static let ventana: TimeInterval = 3 * 60 * 60

    static func esParecida(cantidad: Int, cuando: Date, otraCantidad: Int, otroCuando: Date) -> Bool {
        cantidad == otraCantidad && abs(cuando.timeIntervalSince(otroCuando)) <= ventana
    }
}
