// Une la cola sin señal (Puro/ColaTandas.swift) con la API y con la red del
// iPhone. Se crea una vez en App.swift y baja por el entorno: así la cola es la
// misma aunque la sesión venza y Juan vuelva a entrar.
import Foundation
import Network
import Observation

@MainActor
@Observable
final class Envios {
    private(set) var pendientes: [TandaPendiente] = []
    private(set) var descartadas: [TandaDescartada] = []
    /// Sube cada vez que la cola logra mandar algo: las pantallas lo miran
    /// para recargar el avance.
    private(set) var enviadas = 0

    @ObservationIgnored private let cola: ColaTandas
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var habiaRed = true
    @ObservationIgnored private var reintento: Task<Void, Never>?

    init() {
        cola = ColaTandas(archivo: Almacen.carpeta.appendingPathComponent("cola-tandas.json"),
                          enviar: Envios.enviar)
        pendientes = cola.pendientes
        descartadas = cola.descartadas
        cola.alCambiar = { [weak self] in
            Task { @MainActor in self?.actualizar() }
        }
        monitor.pathUpdateHandler = { [weak self] camino in
            let hayRed = camino.status == .satisfied
            Task { @MainActor in self?.cambioDeRed(hayRed) }
        }
        monitor.start(queue: DispatchQueue(label: "store.printoverse.organizador.red"))
    }

    /// Manda lo pendiente si hay sesión. Se puede llamar cuantas veces sea: si
    /// ya hay un vaciado en curso, la cola no arranca otro.
    func vaciar() async {
        guard !pendientes.isEmpty, Llavero.leer() != nil else { return }
        await cola.vaciar()
        actualizar()
        programarReintento()
    }

    func agregar(_ tanda: TandaPendiente) {
        cola.agregar(tanda)
        actualizar()
        programarReintento()
    }

    func reintentarDescartadas() {
        cola.reintentarDescartadas()
        actualizar()
        Task { await vaciar() }
    }

    func olvidarDescartadas() {
        cola.olvidarDescartadas()
        actualizar()
    }

    /// Una tanda en la cola que se parece a la que se quiere anotar (dos
    /// toques sin señal).
    func pendienteParecida(modeloId: Int, cantidad: Int, cuando: Date) -> TandaPendiente? {
        pendientes.last { p in
            p.modeloId == modeloId && ReglaParecida.esParecida(
                cantidad: cantidad, cuando: cuando, otraCantidad: p.cantidad, otroCuando: p.cuando)
        }
    }

    // MARK: - Por dentro

    private func actualizar() {
        let antes = pendientes.count
        let ahora = cola.pendientes
        let nuevasDescartadas = cola.descartadas
        if ahora != pendientes { pendientes = ahora }
        if nuevasDescartadas != descartadas { descartadas = nuevasDescartadas }
        if ahora.count < antes { enviadas += 1 }
    }

    /// El iPhone puede decir que hay red y el servidor no contestar (wifi sin
    /// salida, servidor reiniciándose): entonces NWPathMonitor no vuelve a
    /// avisar. Mientras quede algo en la cola se reintenta a los 30 s, 1, 2 y
    /// después cada 5 minutos.
    private func programarReintento() {
        guard reintento == nil, !pendientes.isEmpty else { return }
        reintento = Task { [weak self] in
            var espera: UInt64 = 30
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: espera * 1_000_000_000)
                guard let self else { return }
                await self.vaciar()
                if self.pendientes.isEmpty {
                    self.reintento = nil
                    return
                }
                espera = min(espera * 2, 300)
            }
        }
    }

    private func cambioDeRed(_ hayRed: Bool) {
        let volvio = hayRed && !habiaRed
        habiaRed = hayRed
        if volvio { Task { await vaciar() } }
    }

    /// Lo que entra a la cola ya pasó por "¿es otra tanda?" (o no había nada
    /// parecido), por eso va con forzar: true.
    nonisolated private static func enviar(_ pendiente: TandaPendiente) async -> ResultadoEnvio {
        let tanda = TandaNueva(idCliente: pendiente.idCliente, modeloId: pendiente.modeloId,
                               cantidad: pendiente.cantidad, cuando: pendiente.cuando)
        do {
            _ = try await ClienteAPI.compartido.enviarTanda(tanda, forzar: true)
            return .enviada
        } catch is CancellationError {
            return .detener
        } catch let error as ErrorAPI {
            switch error {
            case .sinConexion, .sinSesion, .llavero:
                // La sesión vencida no borra nada: al volver a entrar se manda.
                return .detener
            case .datos:
                // enviarTanda ya toma un 2xx ilegible como guardada; un .datos
                // aquí es de antes de mandar y reintentar no lo arregla.
                return .descartar("La app no pudo armar el envío de esta tanda.")
            case .servidor(let texto), .noExiste(let texto):
                return .descartar(texto)
            }
        } catch {
            return .detener
        }
    }
}
