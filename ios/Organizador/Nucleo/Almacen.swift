// Copia en disco de lo último que se vio de cada pedido: sin señal, la lista,
// el detalle y sus tandas se siguen viendo, y "¿ya la anotaste?" se puede
// revisar contra las tandas recientes. Va en Application Support (no en
// Caches) para que iOS no la borre justo cuando más falta hace.
import Foundation

enum Almacen {
    static let carpeta: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let carpeta = base.appendingPathComponent("Organizador", isDirectory: true)
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        return carpeta
    }()

    /// Tope de tandas por pedido: alcanza para el historial de varias semanas y
    /// el archivo sigue siendo pequeño.
    private static let maxTandas = 500

    private struct CopiaPedido: Codable {
        var detalle: PedidoDetalle?
        var tandas: [Tanda]?
    }

    // MARK: - Lista

    static func pedidos() -> [PedidoResumen]? {
        leer([PedidoResumen].self, "pedidos.json")
    }

    static func guardarPedidos(_ pedidos: [PedidoResumen]) {
        escribir(pedidos, "pedidos.json")
    }

    // MARK: - Un pedido

    static func detalle(id: Int) -> PedidoDetalle? {
        copia(id).detalle
    }

    static func guardarDetalle(_ detalle: PedidoDetalle) {
        var c = copia(detalle.id)
        c.detalle = detalle
        escribir(c, archivoPedido(detalle.id))
    }

    /// Todas las tandas guardadas del pedido o, si nunca se bajaron, las
    /// últimas que trae el detalle.
    static func tandas(pedidoId: Int) -> [Tanda] {
        let c = copia(pedidoId)
        return c.tandas ?? c.detalle?.ultimasTandas ?? []
    }

    static func guardarTandas(_ tandas: [Tanda], pedidoId: Int) {
        var c = copia(pedidoId)
        c.tandas = Array(tandas.prefix(maxTandas))
        escribir(c, archivoPedido(pedidoId))
    }

    /// Nombre de un modelo según lo guardado, para mostrar una tanda de la
    /// cola (que solo lleva el id).
    static func nombreModelo(id: Int) -> String? {
        let archivos = (try? FileManager.default.contentsOfDirectory(at: carpeta, includingPropertiesForKeys: nil)) ?? []
        for archivo in archivos where archivo.lastPathComponent.hasPrefix("pedido-") {
            guard let datos = try? Data(contentsOf: archivo),
                  let c = try? JSONDecoder().decode(CopiaPedido.self, from: datos) else { continue }
            if let m = c.detalle?.modelos.first(where: { $0.id == id }) { return m.nombre }
        }
        return nil
    }

    // MARK: - Productos

    static func productos() -> [ProductoResumen]? {
        leer([ProductoResumen].self, "productos.json")
    }

    static func guardarProductos(_ productos: [ProductoResumen]) {
        escribir(productos, "productos.json")
    }

    static func producto(id: Int) -> ProductoDetalle? {
        leer(ProductoDetalle.self, "producto-\(id).json")
    }

    static func guardarProducto(_ detalle: ProductoDetalle) {
        escribir(detalle, "producto-\(detalle.id).json")
    }

    // MARK: - Perfiles y filamentos

    /// Sin señal, la calculadora sale de aquí: por eso se guardan cada vez que
    /// llegan del servidor o se cambian desde Ajustes.
    static func perfiles() -> [Perfil]? {
        leer([Perfil].self, "perfiles.json")
    }

    static func guardarPerfiles(_ perfiles: [Perfil]) {
        escribir(perfiles, "perfiles.json")
    }

    static func filamentos() -> [Filamento]? {
        leer([Filamento].self, "filamentos.json")
    }

    static func guardarFilamentos(_ filamentos: [Filamento]) {
        escribir(filamentos, "filamentos.json")
    }

    /// Borra la copia de los pedidos y productos (al cerrar sesión). La cola sin señal,
    /// los perfiles y los filamentos se quedan: la app es de una sola cuenta y
    /// así la calculadora sirve sin señal apenas se vuelve a entrar.
    static func borrarTodo() {
        let archivos = (try? FileManager.default.contentsOfDirectory(at: carpeta, includingPropertiesForKeys: nil)) ?? []
        for archivo in archivos where archivo.lastPathComponent.hasPrefix("pedido")
            || archivo.lastPathComponent.hasPrefix("producto") {
            try? FileManager.default.removeItem(at: archivo)
        }
    }

    // MARK: - Por dentro

    private static func archivoPedido(_ id: Int) -> String { "pedido-\(id).json" }

    private static func copia(_ id: Int) -> CopiaPedido {
        leer(CopiaPedido.self, archivoPedido(id)) ?? CopiaPedido()
    }

    private static func leer<T: Decodable>(_ tipo: T.Type, _ nombre: String) -> T? {
        guard let datos = try? Data(contentsOf: carpeta.appendingPathComponent(nombre)) else { return nil }
        return try? JSONDecoder().decode(tipo, from: datos)
    }

    private static func escribir<T: Encodable>(_ valor: T, _ nombre: String) {
        guard let datos = try? JSONEncoder().encode(valor) else { return }
        try? datos.write(to: carpeta.appendingPathComponent(nombre), options: .atomic)
    }
}
