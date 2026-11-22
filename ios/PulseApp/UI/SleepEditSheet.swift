import SwiftUI

/// "Editar sueño" (22/11, igual que Android `SleepEditDialog`), como en WHOOP: cambiar el inicio y el fin de una noche.
/// La noche pasa a ser exactamente ese tramo (`SleepEdits`); "Restablecer" vuelve a la detección automática.
struct SleepEditSheet: View {
    let date: String          // día del despertar (yyyy-MM-dd)
    let fromMillis: Int64
    let toMillis: Int64
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var end = Date()
    @State private var error: String? = nil

    private var dir: URL { AppPaths.baseDir }
    private var edited: Bool { SleepEdits.forDate(dir, date) != nil }

    /// Hora del reloj → instante de esa noche: de 12:00 a 23:59 es la víspera, de 00:00 a 11:59 el día del despertar.
    private func toMillis(_ d: Date) -> Int64 {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let h = c.hour ?? 0, m = c.minute ?? 0
        let base = h >= 12 ? Day.start(Day.add(date, -1)) : Day.start(date)
        return base + Int64(h * 60 + m) * 60_000
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Si te quedaste en la cama sin dormir (viendo una película, con el móvil…), pon la hora en que te dormiste y la de despertar. Las fases, la VFC y la recuperación se recalculan solo con ese tramo.")) {
                    DatePicker("Inicio del sueño", selection: $start, displayedComponents: .hourAndMinute)
                    DatePicker("Fin del sueño", selection: $end, displayedComponents: .hourAndMinute)
                }
                if let e = error { Text(e).foregroundColor(.red) }
                if edited {
                    Section {
                        Button("Restablecer (detección automática)", role: .destructive) {
                            SleepEdits.clear(dir, date); finish()
                        }
                    }
                }
            }
            .navigationTitle("Editar sueño")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        let a = toMillis(start), b = toMillis(end)
                        let min = (b - a) / 60_000
                        if min < 60 || min > 16 * 60 { error = "El sueño tiene que durar entre 1 y 16 horas."; return }
                        SleepEdits.save(dir, date, a, b); finish()
                    }
                }
            }
        }
        .onAppear {
            start = Date(timeIntervalSince1970: Double(fromMillis) / 1000)
            end = Date(timeIntervalSince1970: Double(toMillis) / 1000)
        }
    }

    private func finish() {
        let d = date
        DispatchQueue.global(qos: .userInitiated).async {
            StrengthSave.recalcDayOf(Day.start(d) + 12 * 3_600_000)
            DispatchQueue.main.async { onDone(); dismiss() }
        }
    }
}
