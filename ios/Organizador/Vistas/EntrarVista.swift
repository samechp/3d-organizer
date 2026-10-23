// Pantalla de entrar (maqueta Login): solo se ve la primera vez o cuando la
// sesión vence; después la app recuerda el token.
import SwiftUI
import UIKit

struct EntrarVista: View {
    @Environment(Sesion.self) private var sesion

    @State private var correo = ""
    @State private var clave = ""
    @State private var mensaje: String?
    @State private var enviando = false
    /// Sube con cada fallo: dispara la háptica de error.
    @State private var fallos = 0
    @FocusState private var foco: Campo?

    private enum Campo { case correo, clave }

    private var correoLimpio: String {
        correo.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var puedeEntrar: Bool {
        !enviando && !correoLimpio.isEmpty && !clave.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                encabezado
                campos
                botonEntrar
                if let mensaje {
                    Text(mensaje)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                Text("Solo una vez: después la app recuerda tu sesión.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 72)
            .padding(.bottom, 48)
            // En pantallas grandes no se estira de lado a lado.
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .sensoryFeedback(.error, trigger: fallos)
    }

    private var encabezado: some View {
        VStack(spacing: 24) {
            Image(systemName: "cube")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(Color.acento, in: RoundedRectangle(cornerRadius: Radio.icono, style: .continuous))
                .shadow(color: Color.acento.opacity(0.3), radius: 14, y: 12)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("3D Organizer")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Entra con tu cuenta del panel de PrintoVerse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
    }

    private var campos: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Correo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("tu@correo.com", text: $correo)
                    .font(.body)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($foco, equals: .correo)
                    .onSubmit { foco = .clave }
                    .frame(minHeight: 28)
                    .accessibilityLabel("Correo")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            // Toda la fila (también la etiqueta y los márgenes) lleva al campo,
            // no solo la línea de texto.
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { foco = .correo }

            Divider()
                .padding(.leading, 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("Contraseña")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                SecureField("Tu contraseña", text: $clave)
                    .font(.body)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($foco, equals: .clave)
                    .onSubmit { entrar() }
                    .frame(minHeight: 28)
                    .accessibilityLabel("Contraseña")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            // Toda la fila (también la etiqueta y los márgenes) lleva al campo,
            // no solo la línea de texto.
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { foco = .clave }
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Radio.tarjeta, style: .continuous))
    }

    private var botonEntrar: some View {
        Button {
            entrar()
        } label: {
            ZStack {
                if enviando {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Entrar")
                        .font(.headline)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.acento, in: Capsule())
            .opacity(puedeEntrar || enviando ? 1 : 0.5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!puedeEntrar)
        .accessibilityLabel(enviando ? "Entrando" : "Entrar")
    }

    private func entrar() {
        guard puedeEntrar else { return }
        mensaje = nil
        enviando = true
        foco = nil
        Task {
            do {
                // Si sale bien, RaizVista cambia sola a las pestañas.
                try await sesion.entrar(correo: correoLimpio, clave: clave)
            } catch {
                let texto = (error as? LocalizedError)?.errorDescription ?? "No se pudo entrar."
                mensaje = texto
                fallos += 1
                UIAccessibility.post(notification: .announcement, argument: texto)
            }
            enviando = false
        }
    }
}
