// El token de la sesión va en el llavero del iPhone y no en UserDefaults:
// UserDefaults queda en texto plano dentro de las copias de seguridad.
import Foundation
import Security

enum Llavero {
    private static let servicio = "store.printoverse.organizador"
    private static let cuenta = "token"

    private static func consultaBase() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicio,
            kSecAttrAccount as String: cuenta,
        ]
    }

    static func guardar(_ token: String) {
        let datos = Data(token.utf8)
        // Se borra y se vuelve a añadir en vez de actualizar: así no hay que
        // distinguir entre "ya existía" y "es nuevo".
        SecItemDelete(consultaBase() as CFDictionary)
        var consulta = consultaBase()
        consulta[kSecValueData as String] = datos
        // AfterFirstUnlock: la app puede leerlo aunque se abra con el iPhone
        // bloqueado (por ejemplo, al reanudarse en segundo plano).
        consulta[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(consulta as CFDictionary, nil)
    }

    static func leer() -> String? {
        var consulta = consultaBase()
        consulta[kSecReturnData as String] = true
        consulta[kSecMatchLimit as String] = kSecMatchLimitOne
        var resultado: CFTypeRef?
        let estado = SecItemCopyMatching(consulta as CFDictionary, &resultado)
        guard estado == errSecSuccess, let datos = resultado as? Data else { return nil }
        let token = String(data: datos, encoding: .utf8)
        return (token?.isEmpty ?? true) ? nil : token
    }

    static func borrar() {
        SecItemDelete(consultaBase() as CFDictionary)
    }
}
