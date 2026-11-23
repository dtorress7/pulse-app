import SwiftUI

/// Más → "Datos para calibrar" (23/11, ver DataShare): enviar los tuyos y, si eres el administrador, descargar los de tus amigos.
struct FriendsDataView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = DataShare.enabled
    @State private var lastUpload = DataShare.lastUpload
    @State private var adminState: Bool? = nil
    @State private var people: [DataShare.Person] = []
    @State private var status = ""
    @State private var busy = false
    @State private var files: [URL] = []
    @State private var filesOwner = ""

    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd/MM HH:mm"; return f }()

    var body: some View {
        NavigationView {
            List {
                Section(footer: Text("Tu pulso, movimiento y pasos de la pulsera se envían a una carpeta privada que solo puede ver quien administra PulseApp, para ajustar los cálculos a tu WHOOP. Se manda solo lo nuevo, como mucho cada 3 horas.")) {
                    Toggle("Enviar mis datos para calibrar", isOn: $enabled)
                        .onChange(of: enabled) { v in DataShare.enabled = v; if v { DataShare.maybeUpload(force: true) } }
                    HStack {
                        Text("Último envío")
                        Spacer()
                        Text(lastUpload > 0 ? fmt.string(from: Date(timeIntervalSince1970: lastUpload)) : "nunca").foregroundColor(.secondary)
                    }
                    Button("Enviar ahora") {
                        DataShare.enabled = true; enabled = true
                        DataShare.maybeUpload(force: true)
                        status = "Enviando en segundo plano…"
                    }
                }
                Section(header: Text("Datos de amigos (administrador)")) {
                    if adminState == nil {
                        HStack { ProgressView(); Text("Conectando…").foregroundColor(.secondary) }
                    } else if adminState == false {
                        Text("Solo el administrador puede ver los datos de los demás.").foregroundColor(.secondary)
                        Button("Hacerme administrador (solo la primera vez)") { Task { await claim() } }
                    } else if people.isEmpty {
                        Text("Todavía nadie ha enviado datos.").foregroundColor(.secondary)
                    } else {
                        ForEach(people) { p in
                            Button {
                                Task { await download(p) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name + (p.platform.isEmpty ? "" : " (\(p.platform))")).foregroundColor(.primary)
                                    Text(p.updated > 0 ? "Último envío " + fmt.string(from: Date(timeIntervalSince1970: Double(p.updated) / 1000)) : "–")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .disabled(busy)
                        }
                    }
                    if !files.isEmpty {
                        ShareLink(items: files) { Label("Compartir archivos de \(filesOwner)", systemImage: "square.and.arrow.up") }
                    }
                }
                if !status.isEmpty { Section { Text(status).font(.footnote).foregroundColor(.secondary) } }
            }
            .navigationTitle("Datos para calibrar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            let admin = try await DataShare.isAdmin()
            if admin { people = try await DataShare.people() }
            adminState = admin
        } catch {
            adminState = false
            status = (error as? LocalizedError)?.errorDescription ?? "No se pudo conectar"
        }
    }

    private func claim() async {
        do {
            if try await DataShare.claimAdmin() { status = "Ya eres el administrador"; adminState = nil; await load() }
            else { status = "Ya hay otro administrador" }
        } catch { status = (error as? LocalizedError)?.errorDescription ?? "No se pudo conectar" }
    }

    private func download(_ p: DataShare.Person) async {
        busy = true; files = []; status = "Descargando…"
        do {
            let got = try await DataShare.download(p) { msg in Task { @MainActor in status = "Descargando " + msg } }
            files = got; filesOwner = p.name
            status = got.isEmpty ? "No hay archivos de \(p.name)" : "Listo: \(got.count) archivos de \(p.name). Pulsa «Compartir»."
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? "No se pudo descargar"
        }
        busy = false
    }
}
