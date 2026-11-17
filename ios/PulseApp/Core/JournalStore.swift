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

    static let defaultQuestions = ["¿Tomas bebidas alcohólicas?", "¿Te hidrataste lo suficiente?", "¿Comiste algo cerca de la hora de dormir?",
                                   "¿Dormiste en la misma cama de siempre?", "¿Consumiste cafeína?", "¿Usaste un dispositivo con pantalla en la cama?",
                                   "¿Desayunaste?", "¿Cenaste?"]

    static func behaviorName(_ q: String) -> String { return JournalCatalog.name(q) }

    /// 0 = nada respondido, 1 = parte de las preguntas, 2 = todas (los círculos de "Mi diario").
    static func status(_ d: String, answers: [String: Bool]? = nil, questions qs: [String]? = nil) -> Int {
        let a = answers ?? day(d)
        if a.isEmpty { return 0 }
        let q = qs ?? questions()
        return q.allSatisfy { a[$0] != nil } ? 2 : 1
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
        return seen
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
