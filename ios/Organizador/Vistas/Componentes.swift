// Piezas que comparten varias pantallas de pedidos: la barra de avance, la
// pastilla del ritmo, la miniatura del modelo y las rutas de navegación.
import SwiftUI
import UIKit

/// Lo que se apila en la pestaña Pedidos.
enum Ruta: Hashable {
    case detalle(Int)
    case historial(Int)
}

extension Color {
    /// Texto naranja sobre fondo naranja claro: más oscuro en modo claro y más
    /// claro en modo oscuro, para que se lea en los dos.
    static let acentoTexto = Color(UIColor { rasgos in
        rasgos.userInterfaceStyle == .dark
            ? UIColor(red: 0xFB / 255.0, green: 0x92 / 255.0, blue: 0x3C / 255.0, alpha: 1)
            : UIColor(red: 0x9A / 255.0, green: 0x34 / 255.0, blue: 0x12 / 255.0, alpha: 1)
    })

    /// Verde de "completo" para texto, con la misma idea.
    static let completoTexto = Color(UIColor { rasgos in
        rasgos.userInterfaceStyle == .dark
            ? UIColor(red: 0x4A / 255.0, green: 0xDE / 255.0, blue: 0x80 / 255.0, alpha: 1)
            : UIColor(red: 0x1F / 255.0, green: 0x7A / 255.0, blue: 0x3D / 255.0, alpha: 1)
    })
}

struct BarraAvance: View {
    /// De 0 a 1; lo que pase de 1 se queda en la barra llena.
    let fraccion: Double
    let completo: Bool
    var alto: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemFill))
                Capsule()
                    .fill(completo ? Color.completo : Color.acento)
                    .frame(width: geo.size.width * min(1, max(0, fraccion)))
            }
        }
        .frame(height: alto)
        // El número ya va en el texto de al lado.
        .accessibilityHidden(true)
    }
}

struct PastillaRitmo: View {
    let texto: String
    let tono: Formato.Tono

    private var color: Color {
        switch tono {
        case .normal: return .acentoTexto
        case .vencido: return .red
        case .completo: return .completoTexto
        }
    }

    private var icono: String {
        switch tono {
        case .normal: return "calendar"
        case .vencido: return "exclamationmark.circle.fill"
        case .completo: return "checkmark.circle.fill"
        }
    }

    var body: some View {
        Label(texto, systemImage: icono)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Foto del modelo (o del producto) o, si no tiene, sus iniciales sobre un color.
struct MiniaturaModelo: View {
    let nombre: String
    let fotoUrl: String?
    /// Posición en el pedido: elige el color de fondo sin foto.
    let indice: Int
    var lado: CGFloat = 44

    init(nombre: String, fotoUrl: String?, indice: Int, lado: CGFloat = 44) {
        self.nombre = nombre
        self.fotoUrl = fotoUrl
        self.indice = indice
        self.lado = lado
    }

    init(modelo: Modelo, indice: Int, lado: CGFloat = 44) {
        self.init(nombre: modelo.nombre, fotoUrl: modelo.fotoUrl, indice: indice, lado: lado)
    }

    @State private var imagen: UIImage? = nil

    private static let fondos: [Color] = [.orange, .blue, .green, .purple]

    var body: some View {
        ZStack {
            if let imagen {
                Image(uiImage: imagen)
                    .resizable()
                    .scaledToFill()
            } else {
                MiniaturaModelo.fondos[indice % MiniaturaModelo.fondos.count].opacity(0.2)
                Text(Formato.iniciales(nombre))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .frame(width: lado, height: lado)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: fotoUrl) {
            guard let ruta = fotoUrl else {
                imagen = nil
                return
            }
            if let ya = Fotos.enMemoria(ruta) {
                imagen = ya
            } else if let bajada = try? await Fotos.cargar(ruta) {
                imagen = bajada
            }
        }
    }
}

/// Botón ancho de las acciones principales ("Anotar tanda", "Guardar ...").
struct BotonPrincipal: View {
    let titulo: String
    var icono: String? = nil
    var cargando = false
    let accion: () -> Void

    @Environment(\.isEnabled) private var habilitado

    var body: some View {
        Button(action: accion) {
            ZStack {
                if cargando {
                    ProgressView().tint(.white)
                } else if let icono {
                    Label(titulo, systemImage: icono)
                } else {
                    Text(titulo)
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.acento, in: Capsule())
            .opacity(habilitado || cargando ? 1 : 0.5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// La franja de abajo donde flota el botón principal: vidrio y respetando
    /// el área segura (iPhone SE sin muesca o con isla).
    func botonAbajo<Contenido: View>(@ViewBuilder _ contenido: () -> Contenido) -> some View {
        let vista = contenido()
        return safeAreaInset(edge: .bottom) {
            vista
                .padding(8)
                .vidrio(Capsule())
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }
}

extension Error {
    /// Texto para mostrar, o nil si no hay que mostrar nada (la tarea se canceló
    /// o la sesión venció: de eso ya se encarga la Sesion).
    var textoParaMostrar: String? {
        if self is CancellationError { return nil }
        if let e = self as? ErrorAPI {
            if e == .sinSesion { return nil }
            return e.errorDescription
        }
        return "Algo salió mal. Inténtalo de nuevo."
    }
}
