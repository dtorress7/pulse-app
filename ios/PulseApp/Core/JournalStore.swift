import Foundation

/* 17/11: Diario como WHOOP (vídeo del usuario). Respuestas sí/no por día en journal.json (no entra en ningún cálculo de la app;
   solo en "Información sobre comportamientos"). Comprobado con el export del usuario (189 días, 29 preguntas): WHOOP guarda cada
   respuesta en el ciclo que EMPIEZA esa noche, y el % de impacto encaja con la recuperación de ESE MISMO día (sí − no, correlación
   0,85 con sus números; con la del día siguiente 0,0). Por eso aquí la respuesta del día D (lo de ayer y anoche) va con la
   recuperación del día D. */
enum JournalStore {
    static let fileName = "journal.json"
    private static let questionsKey = "pulseapp_journal_questions"
    private static let lock = NSLock()

    /// Preguntas conocidas → nombre del comportamiento (como lo muestra WHOOP).
    static let catalog: [(q: String, name: String)] = [
        ("¿Dormiste en la misma cama de siempre?", "Dormir en cama propia"),
        ("¿Compartiste tu cama?", "Cama compartida"),
        ("¿Te hidrataste lo suficiente?", "Hidratación"),
        ("¿Tomas bebidas alcohólicas?", "Alcohol"),
        ("¿Desayunaste?", "Desayuno"),
        ("¿Almorzaste?", "Almuerzo"),
        ("¿Cenaste?", "Cena"),
        ("¿Comiste un snack por la tarde?", "Snack de la tarde"),
        ("¿Comiste algo cerca de la hora de dormir?", "Comida tardía"),
        ("¿Comiste antes de entrenar?", "Comer antes de entrenar"),
        ("¿Comiste en un restaurante?", "Restaurante"),
        ("¿Comiste comida casera?", "Cocinado en casa"),
        ("¿Consumiste proteína?", "Proteína"),
        ("¿Consumiste lácteos?", "Lácteos"),
        ("¿Consumiste frutas o verduras?", "Frutas y verduras"),
        ("¿Tomaste creatina?", "Creatina"),
        ("¿Tomaste un suplemento de magnesio?", "Suplemento de magnesio"),
        ("¿Consumiste magnesio?", "Suplemento de magnesio"),
        ("¿Tomaste un suplemento de omega 3?", "Omega 3"),
        ("¿Tomaste medicamento para la alergia?", "Medicamento para la alergia"),
        ("¿Has experimentado antojos de comida?", "Antojos de comida"),
        ("¿Has notado adelgazamiento o pérdida del cabello?", "Pérdida de cabello"),
        ("¿Te masturbaste?", "Masturbación"),
        ("¿Tuviste relaciones sexuales?", "Actividad sexual"),
        ("¿Lees (sin pantalla) mientras estás en la cama?", "Leer en la cama"),
        ("¿Usaste pantallas en la cama?", "Pantallas en la cama"),
        ("¿Tomaste cafeína por la tarde?", "Cafeína tardía"),
        ("¿Tienes una lesión o herida?", "Lesión"),
        ("¿Fuiste al trabajo?", "Desplazamiento al trabajo"),
        ("¿Pasaste tiempo en videollamadas de trabajo?", "Videollamadas de trabajo"),
        ("¿Tomaste un día de vacaciones?", "Vacaciones"),
        ("¿Jugaste videojuegos?", "Videojuegos")
    ]

    static let defaultQuestions = ["¿Tomas bebidas alcohólicas?", "¿Te hidrataste lo suficiente?", "¿Comiste algo cerca de la hora de dormir?",
                                   "¿Dormiste en la misma cama de siempre?", "¿Tomaste cafeína por la tarde?", "¿Usaste pantallas en la cama?",
                                   "¿Desayunaste?", "¿Cenaste?"]

    static func behaviorName(_ q: String) -> String {
        if let n = catalog.first(where: { $0.q == q })?.name { return n }
        return q.trimmingCharacters(in: CharacterSet(charactersIn: "¿?"))
    }

    // MARK: Respuestas

    static func all() -> [String: [String: Bool]] {
        lock.lock(); defer { lock.unlock() }
        return readLocked()
    }

    static func day(_ d: String) -> [String: Bool] { return all()[d] ?? [:] }

    static func save(_ d: String, _ answers: [String: Bool]) {
        lock.lock(); defer { lock.unlock() }
        var a = readLocked()
        if answers.isEmpty { a.removeValue(forKey: d) } else { a[d] = answers }
        writeLocked(a)
    }

    private static func readLocked() -> [String: [String: Bool]] {
        guard let data = try? Data(contentsOf: AppPaths.file(fileName)),
              let j = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) else { return [:] }
        return j
    }

    private static func writeLocked(_ a: [String: [String: Bool]]) {
        if let data = try? JSONEncoder().encode(a) { try? data.write(to: AppPaths.file(fileName), options: .atomic) }
    }

    // MARK: Preguntas activas

    static func questions() -> [String] {
        if let q = UserDefaults.standard.stringArray(forKey: questionsKey), !q.isEmpty { return q }
        // Sin elegir: las que respondiste en los últimos 30 días (p. ej. las importadas de WHOOP) o las de por defecto
        let recent = all().filter { $0.key >= TimeUtil.dayKey(TimeUtil.nowMillis() - 30 * 86_400_000) }
        var seen = [String]()
        for (_, a) in recent.sorted(by: { $0.key > $1.key }) { for q in a.keys where !seen.contains(q) { seen.append(q) } }
        if seen.isEmpty { return defaultQuestions }
        let order = catalog.map { $0.q }
        return seen.sorted { (order.firstIndex(of: $0) ?? 999) < (order.firstIndex(of: $1) ?? 999) }
    }

    static func setQuestions(_ q: [String]) { UserDefaults.standard.set(q, forKey: questionsKey) }

    // MARK: Importar el diario del export de WHOOP (journal_entries.csv)

    /// Filas con "Hora de inicio del ciclo", "Texto de la pregunta" y "Respondió "Sí"". El día es el de la mañana del ciclo
    /// (inicio + 12 h). No pisa los días que ya respondiste en PulseApp. Devuelve los días añadidos.
    static func importWhoop(_ rows: [[String: String]]) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var add = [String: [String: Bool]]()
        for r in rows {
            guard let start = r["Hora de inicio del ciclo"], let q = r["Texto de la pregunta"], !q.isEmpty,
                  let yes = r["Respondió \"Sí\""] ?? r["Respondió Sí"], let date = f.date(from: String(start.prefix(19))) else { continue }
            let key = TimeUtil.dayKey(Int64((date.timeIntervalSince1970 + 12 * 3600) * 1000))
            add[key, default: [:]][q.precomposedStringWithCanonicalMapping] = yes.lowercased() == "true"
        }
        lock.lock(); defer { lock.unlock() }
        var a = readLocked()
        var n = 0
        for (d, answers) in add where a[d] == nil { a[d] = answers; n += 1 }
        writeLocked(a)
        return n
    }
}
