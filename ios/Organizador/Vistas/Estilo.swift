// Colores y el "vidrio" de todas las pantallas: Liquid Glass en iOS 26 y, en
// iOS 17–25, el material translúcido que más se le parece.
import SwiftUI

extension Color {
    /// Naranja de PrintoVerse (#C2410C). Encima va texto blanco.
    static let acento = Color(red: 0xC2 / 255.0, green: 0x41 / 255.0, blue: 0x0C / 255.0)
    /// Verde de "completo" (#1F7A3D).
    static let completo = Color(red: 0x1F / 255.0, green: 0x7A / 255.0, blue: 0x3D / 255.0)
}

/// Esquinas de toda la app, para que tarjetas y botones no queden cada uno distinto.
enum Radio {
    static let tarjeta: CGFloat = 18
    static let icono: CGFloat = 22
}

extension View {
    /// Fondo de vidrio con la forma dada.
    @ViewBuilder
    func vidrio<Forma: Shape>(_ forma: Forma) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: forma)
        } else {
            self.background(.ultraThinMaterial, in: forma)
        }
    }

    /// Vidrio con la esquina de las tarjetas.
    func vidrio() -> some View {
        vidrio(RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
    }
}
