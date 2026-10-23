// Fotos de los modelos: se achican antes de subirlas y se guardan en memoria
// después de bajarlas (piden sesión, así que no sirve AsyncImage).
import Foundation
import UIKit

enum Fotos {
    /// Lado mayor de 800 px y JPEG al 70 %: se reconoce el modelo y la subida
    /// pesa unos 100 KB en vez de varios MB (el servidor acepta hasta 3).
    static func jpegReducido(_ datos: Data, ladoMaximo: CGFloat = 800) -> Data? {
        guard let imagen = UIImage(data: datos) else { return nil }
        let tamano = imagen.size
        let mayor = max(tamano.width, tamano.height)
        guard mayor > 0 else { return nil }
        let escala = min(1, ladoMaximo / mayor)
        let nuevo = CGSize(width: (tamano.width * escala).rounded(),
                           height: (tamano.height * escala).rounded())
        let formato = UIGraphicsImageRendererFormat.default()
        // Escala 1: los 800 son píxeles, no puntos (si no, en un iPhone 3x saldría de 2.400).
        formato.scale = 1
        let reducida = UIGraphicsImageRenderer(size: nuevo, format: formato).image { _ in
            // draw(in:) respeta la orientación de la foto: no sale de lado.
            imagen.draw(in: CGRect(origin: .zero, size: nuevo))
        }
        return reducida.jpegData(compressionQuality: 0.7)
    }

    private static let memoria: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 100
        return c
    }()

    static func enMemoria(_ ruta: String) -> UIImage? {
        memoria.object(forKey: ruta as NSString)
    }

    /// Baja la foto o la toma de la memoria. El nombre cambia si cambia la
    /// foto, así que lo guardado nunca queda viejo.
    static func cargar(_ ruta: String) async throws -> UIImage? {
        if let ya = enMemoria(ruta) { return ya }
        let datos = try await ClienteAPI.compartido.foto(ruta: ruta)
        guard let imagen = UIImage(data: datos) else { return nil }
        memoria.setObject(imagen, forKey: ruta as NSString)
        return imagen
    }
}
