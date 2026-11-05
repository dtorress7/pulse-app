import Foundation

/// Entrenador de fuerza (5/11), port 1:1 de Strength.kt: ejercicios con series (repeticiones, peso y, si se cronometran con
/// "Comenzar / Finalizar serie", su hora para sacar el pulso de cada serie). Archivos de texto separados por tabuladores:
/// strength_logs.tsv (series de cada actividad), strength_templates.tsv (Mis entrenamientos), strength_custom.tsv
/// (ejercicios personalizados) y strength_live.tsv (el entrenamiento en curso).
enum Strength {

    // MARK: Modelo
    final class SetEntry {
        var reps: Int; var kg: Double; var startMs: Int64?; var endMs: Int64?; var done: Bool
        init(_ reps: Int, _ kg: Double, _ startMs: Int64? = nil, _ endMs: Int64? = nil, _ done: Bool = false) {
            self.reps = reps; self.kg = kg; self.startMs = startMs; self.endMs = endMs; self.done = done
        }
        func copy() -> SetEntry { return SetEntry(reps, kg, startMs, endMs, done) }
        var volume: Double { return Double(reps) * kg }
    }

    final class ExerciseEntry {
        let exId: String; var name: String; var superset: Int; var sets: [SetEntry]
        init(_ exId: String, _ name: String, _ superset: Int = 0, _ sets: [SetEntry] = []) {
            self.exId = exId; self.name = name; self.superset = superset; self.sets = sets
        }
        func copy() -> ExerciseEntry { return ExerciseEntry(exId, name, superset, sets.map { $0.copy() }) }
        var reps: Int { return sets.reduce(0) { $0 + $1.reps } }
        var volume: Double { return sets.reduce(0) { $0 + $1.volume } }
    }

    final class Workout {
        var id: Int64; var startMs: Int64; var endMs: Int64; var name: String; var exercises: [ExerciseEntry]
        init(_ id: Int64, _ startMs: Int64, _ endMs: Int64, _ name: String = "", _ exercises: [ExerciseEntry] = []) {
            self.id = id; self.startMs = startMs; self.endMs = endMs; self.name = name; self.exercises = exercises
        }
        func copy() -> Workout { return Workout(id, startMs, endMs, name, exercises.map { $0.copy() }) }
        var setCount: Int { return exercises.reduce(0) { $0 + $1.sets.count } }
        var reps: Int { return exercises.reduce(0) { $0 + $1.reps } }
        var volume: Double { return exercises.reduce(0) { $0 + $1.volume } }
    }

    struct Exercise { let id: String; let name: String; let group: String; let equipment: String; let bodyweight: Double }

    // MARK: Biblioteca (mismos nombres y fracciones de peso corporal que Android)
    private static let lib: [Exercise] = {
        var l = [Exercise]()
        func e(_ name: String, _ group: String, _ eq: String, _ bw: Double = 0) { l.append(Exercise(id: slug(name), name: name, group: group, equipment: eq, bodyweight: bw)) }
        e("Press de banca - Barra", "Pecho", "Barra"); e("Press de banca - Mancuerna", "Pecho", "Mancuernas")
        e("Press de banca - Inclinado - Barra", "Pecho", "Barra"); e("Press de banca - Inclinado - Mancuerna", "Pecho", "Mancuernas")
        e("Press de banca - Declinado - Barra", "Pecho", "Barra"); e("Press de banca - Declinado - Mancuerna", "Pecho", "Mancuernas")
        e("Press de pecho - Máquina", "Pecho", "Máquina"); e("Press de banca - Multipower", "Pecho", "Máquina")
        e("Aperturas - Mancuernas", "Pecho", "Mancuernas"); e("Aperturas - Inclinado - Mancuernas", "Pecho", "Mancuernas")
        e("Cruce de poleas", "Pecho", "Polea"); e("Contractora de pecho - Máquina", "Pecho", "Máquina")
        e("Flexiones", "Pecho", "Peso corporal", 0.64); e("Flexiones - Inclinadas", "Pecho", "Peso corporal", 0.45)
        e("Flexiones - Declinadas", "Pecho", "Peso corporal", 0.74); e("Flexiones diamante", "Tríceps", "Peso corporal", 0.64)
        e("Fondos en paralelas", "Pecho", "Peso corporal", 0.9); e("Pullover - Mancuerna", "Pecho", "Mancuernas")
        e("Dominada", "Espalda", "Peso corporal", 0.95); e("Dominada supina", "Espalda", "Peso corporal", 0.95)
        e("Dominada asistida - Máquina", "Espalda", "Máquina", 0.95); e("Jalón al pecho - Polea", "Espalda", "Polea")
        e("Jalón al pecho - Agarre estrecho - Polea", "Espalda", "Polea"); e("Remo con barra", "Espalda", "Barra")
        e("Remo con mancuerna - Un brazo", "Espalda", "Mancuernas"); e("Remo sentado - Polea", "Espalda", "Polea")
        e("Remo agachado de un solo brazo - I - Cable", "Espalda", "Polea"); e("Remo agachado de un solo brazo - D - Cable", "Espalda", "Polea")
        e("Remo inclinado con un solo brazo - I - Cable", "Espalda", "Polea"); e("Remo inclinado con un solo brazo - D - Cable", "Espalda", "Polea")
        e("Remo en máquina", "Espalda", "Máquina"); e("Remo en T", "Espalda", "Barra"); e("Remo invertido", "Espalda", "Peso corporal", 0.6)
        e("Remo Pendlay", "Espalda", "Barra"); e("Pulldown con brazos rectos - Polea", "Espalda", "Polea")
        e("Peso muerto - Barra", "Espalda", "Barra"); e("Peso muerto rumano - Barra", "Piernas", "Barra")
        e("Peso muerto rumano - Mancuernas", "Piernas", "Mancuernas"); e("Peso muerto sumo", "Piernas", "Barra")
        e("Hiperextensiones", "Espalda", "Peso corporal", 0.5); e("Buenos días - Barra", "Espalda", "Barra")
        e("Encogimientos - Mancuernas", "Espalda", "Mancuernas"); e("Encogimientos - Barra", "Espalda", "Barra")
        e("Press de hombros - Sentado - Mancuernas", "Hombros", "Mancuernas"); e("Press de hombros - De pie - Mancuernas", "Hombros", "Mancuernas")
        e("Press militar - Barra", "Hombros", "Barra"); e("Press de hombros - Máquina", "Hombros", "Máquina")
        e("Arnold Press - Sentado - Mancuerna", "Hombros", "Mancuernas"); e("Elevaciones laterales - Mancuernas", "Hombros", "Mancuernas")
        e("Elevaciones laterales - Polea", "Hombros", "Polea"); e("Elevaciones frontales - Mancuernas", "Hombros", "Mancuernas")
        e("Pájaros - Mancuernas", "Hombros", "Mancuernas"); e("Face pull - Polea", "Hombros", "Polea")
        e("Remo al mentón - Barra", "Hombros", "Barra"); e("Aperturas inversas - Máquina", "Hombros", "Máquina")
        e("Flexiones en pica", "Hombros", "Peso corporal", 0.5); e("Alrededor del mundo - Mancuernas", "Hombros", "Mancuernas")
        e("Curl de bíceps - Barra", "Bíceps", "Barra"); e("Curl de bíceps - Mancuernas", "Bíceps", "Mancuernas")
        e("Curl martillo - Mancuernas", "Bíceps", "Mancuernas"); e("Curl concentrado - Mancuerna", "Bíceps", "Mancuernas")
        e("Curl en banco Scott", "Bíceps", "Barra"); e("Curl de bíceps - Polea", "Bíceps", "Polea")
        e("Curl inclinado - Mancuernas", "Bíceps", "Mancuernas"); e("Curl con barra Z", "Bíceps", "Barra")
        e("Extensión de tríceps - Polea", "Tríceps", "Polea"); e("Extensión de tríceps con cuerda - Polea", "Tríceps", "Polea")
        e("Press francés - Barra", "Tríceps", "Barra"); e("Extensión de tríceps sobre la cabeza - Mancuerna", "Tríceps", "Mancuernas")
        e("Patada de tríceps - Mancuerna", "Tríceps", "Mancuernas"); e("Press de banca agarre estrecho", "Tríceps", "Barra")
        e("Fondos de tríceps en el suelo", "Tríceps", "Peso corporal", 0.5); e("Fondos de tríceps en banco", "Tríceps", "Peso corporal", 0.6)
        e("Sentadilla - Barra", "Piernas", "Barra"); e("Sentadilla frontal - Barra", "Piernas", "Barra")
        e("Sentadilla goblet - Mancuerna", "Piernas", "Mancuernas"); e("Sentadilla - Peso corporal", "Piernas", "Peso corporal", 0.7)
        e("Sentadilla búlgara - Mancuernas", "Piernas", "Mancuernas", 0.4); e("Sentadilla hack - Máquina", "Piernas", "Máquina")
        e("Sentadilla - Multipower", "Piernas", "Máquina"); e("Prensa de piernas", "Piernas", "Máquina")
        e("Zancadas - Mancuernas", "Piernas", "Mancuernas", 0.4); e("Zancadas - Barra", "Piernas", "Barra", 0.4)
        e("Zancadas caminando", "Piernas", "Peso corporal", 0.6); e("Subida al banco - Mancuernas", "Piernas", "Mancuernas", 0.5)
        e("Extensión de cuádriceps - Máquina", "Piernas", "Máquina"); e("Curl femoral tumbado - Máquina", "Piernas", "Máquina")
        e("Curl femoral sentado - Máquina", "Piernas", "Máquina"); e("Curl nórdico", "Piernas", "Peso corporal", 0.5)
        e("Elevación de gemelos de pie", "Piernas", "Máquina"); e("Elevación de gemelos sentado", "Piernas", "Máquina")
        e("Abductores - Máquina", "Piernas", "Máquina"); e("Aductores - Máquina", "Piernas", "Máquina")
        e("Sentadilla con salto", "Piernas", "Peso corporal", 0.8); e("Pistol squat", "Piernas", "Peso corporal", 0.8)
        e("Hip thrust - Barra", "Glúteos", "Barra"); e("Hip thrust - Máquina", "Glúteos", "Máquina")
        e("Puente de glúteo", "Glúteos", "Peso corporal", 0.4); e("Patada de glúteo - Polea", "Glúteos", "Polea")
        e("Peso muerto a una pierna - Mancuerna", "Glúteos", "Mancuernas", 0.3)
        e("Abdominales", "Core", "Peso corporal", 0.3); e("Abdominales en bicicleta", "Core", "Peso corporal", 0.3)
        e("Abdominales en la máquina GHD", "Core", "Máquina", 0.5); e("Crunch - Polea", "Core", "Polea")
        e("Plancha", "Core", "Peso corporal", 0.5); e("Plancha lateral", "Core", "Peso corporal", 0.4)
        e("Copenhague", "Core", "Peso corporal", 0.3); e("Elevación de piernas colgado", "Core", "Peso corporal", 0.35)
        e("Elevación de piernas tumbado", "Core", "Peso corporal", 0.25); e("Rueda abdominal", "Core", "Otro", 0.4)
        e("Russian twist", "Core", "Peso corporal", 0.25); e("Pallof press - Polea", "Core", "Polea")
        e("Leñador - Polea", "Core", "Polea"); e("Dead bug", "Core", "Peso corporal", 0.2)
        e("Mountain climbers", "Core", "Peso corporal", 0.3); e("Hollow hold", "Core", "Peso corporal", 0.3)
        e("Swing - Pesa rusa", "Cuerpo completo", "Pesa rusa"); e("Arrancada con un solo brazo - I - Pesa rusa", "Cuerpo completo", "Pesa rusa")
        e("Arrancada con un solo brazo - D - Pesa rusa", "Cuerpo completo", "Pesa rusa"); e("Clean - Pesa rusa", "Cuerpo completo", "Pesa rusa")
        e("Turkish get-up - Pesa rusa", "Cuerpo completo", "Pesa rusa", 0.2); e("Thruster - Barra", "Cuerpo completo", "Barra", 0.2)
        e("Thruster - Mancuernas", "Cuerpo completo", "Mancuernas", 0.2); e("Cargada de potencia - Barra", "Cuerpo completo", "Barra")
        e("Arrancada - Barra", "Cuerpo completo", "Barra"); e("Dos tiempos - Barra", "Cuerpo completo", "Barra")
        e("Burpees", "Cuerpo completo", "Peso corporal", 0.6); e("Paseo del granjero - Mancuernas", "Cuerpo completo", "Mancuernas")
        e("Wall ball", "Cuerpo completo", "Otro", 0.5); e("Box jump", "Piernas", "Peso corporal", 0.7)
        e("Battle ropes", "Cuerpo completo", "Otro"); e("Saltos a la comba", "Cardio", "Otro", 0.1)
        e("Remo - Ergómetro", "Cardio", "Máquina"); e("Bicicleta de asalto", "Cardio", "Máquina")
        return l.sorted { norm($0.name) < norm($1.name) }
    }()

    static func library() -> [Exercise] { return (lib + customExercises()).sorted { norm($0.name) < norm($1.name) } }
    static func exercise(_ id: String) -> Exercise? { return lib.first { $0.id == id } ?? customExercises().first { $0.id == id } }

    static let groups = ["Pecho", "Espalda", "Hombros", "Bíceps", "Tríceps", "Piernas", "Glúteos", "Core", "Cuerpo completo", "Cardio"]
    static let equipment = ["Barra", "Mancuernas", "Polea", "Máquina", "Peso corporal", "Pesa rusa", "Otro"]

    static func norm(_ s: String) -> String {
        return s.lowercased().folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func slug(_ s: String) -> String {
        return norm(s).replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    // MARK: Archivos
    static var dir: URL? = nil
    private static func file(_ name: String) -> URL? { return (dir ?? AppPaths.baseDir).appendingPathComponent(name) }
    private static var logCache: [Workout]? = nil
    private static var customCache: [Exercise]? = nil
    private static let lock = NSLock()

    private static func clean(_ s: String) -> String {
        return s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    static func encode(_ list: [Workout], tag: String) -> String {
        var sb = "#pulseapp_strength v1\n"
        for w in list {
            sb += "\(tag)\t\(w.id)\t\(w.startMs)\t\(w.endMs)\t\(clean(w.name))\n"
            for e in w.exercises {
                sb += "E\t\(e.exId)\t\(e.superset)\t\(clean(e.name))\n"
                for s in e.sets {
                    sb += "S\t\(s.reps)\t\(String(format: "%.2f", s.kg))\t\(s.startMs.map { String($0) } ?? "")\t\(s.endMs.map { String($0) } ?? "")\t\(s.done ? "1" : "0")\n"
                }
            }
        }
        return sb
    }

    static func decode(_ text: String, tag: String) -> [Workout] {
        var out = [Workout]()
        var w: Workout? = nil
        var e: ExerciseEntry? = nil
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            let p = line.components(separatedBy: "\t")
            func at(_ i: Int) -> String? { return i < p.count ? p[i] : nil }
            if p[0] == tag {
                let nw = Workout(Int64(at(1) ?? "") ?? 0, Int64(at(2) ?? "") ?? 0, Int64(at(3) ?? "") ?? 0, at(4) ?? "")
                out.append(nw); w = nw; e = nil
            } else if p[0] == "E", let ww = w {
                let ne = ExerciseEntry(at(1) ?? "", at(3) ?? "", Int(at(2) ?? "") ?? 0)
                ww.exercises.append(ne); e = ne
            } else if p[0] == "S", let ee = e {
                ee.sets.append(SetEntry(Int(at(1) ?? "") ?? 0, Double(at(2) ?? "") ?? 0, Int64(at(3) ?? ""), Int64(at(4) ?? ""), at(5) == "1"))
            }
        }
        return out
    }

    private static func read(_ name: String, tag: String) -> [Workout] {
        guard let f = file(name), let t = try? String(contentsOf: f, encoding: .utf8) else { return [] }
        return decode(t, tag: tag)
    }

    private static func write(_ name: String, _ text: String) {
        guard let f = file(name) else { return }
        try? text.data(using: .utf8)?.write(to: f, options: .atomic)
    }

    static func logs() -> [Workout] {
        lock.lock(); defer { lock.unlock() }
        if let c = logCache { return c }
        let l = read("strength_logs.tsv", tag: "L").sorted { $0.startMs < $1.startMs }
        logCache = l
        return l
    }

    static func logFor(_ sessionId: Int64) -> Workout? { return logs().first { $0.id == sessionId } }

    /// El registro que más se solapa con [start, end] (al menos la mitad del más corto).
    static func logOverlapping(_ start: Int64, _ end: Int64) -> Workout? {
        var best: Workout? = nil; var bestOv: Int64 = 0
        for w in logs() {
            let ov = min(end, w.endMs) - max(start, w.startMs)
            let shorter = min(end - start, w.endMs - w.startMs)
            if ov > 0 && ov * 2 >= shorter && ov > bestOv { best = w; bestOv = ov }
        }
        return best
    }

    static func saveLog(_ w: Workout) {
        var list = logs().filter { $0.id != w.id }
        if !w.exercises.isEmpty { list.append(w) }
        list.sort { $0.startMs < $1.startMs }
        write("strength_logs.tsv", encode(list, tag: "L"))
        lock.lock(); logCache = list; lock.unlock()
    }

    static func deleteLog(_ sessionId: Int64) {
        let list = logs().filter { $0.id != sessionId }
        write("strength_logs.tsv", encode(list, tag: "L"))
        lock.lock(); logCache = list; lock.unlock()
    }

    static func templates() -> [Workout] { return read("strength_templates.tsv", tag: "T").sorted { $0.startMs > $1.startMs } }
    static func saveTemplate(_ t: Workout) {
        var list = templates().filter { $0.id != t.id }
        list.append(t)
        write("strength_templates.tsv", encode(list, tag: "T"))
    }
    static func deleteTemplate(_ id: Int64) { write("strength_templates.tsv", encode(templates().filter { $0.id != id }, tag: "T")) }

    static func customExercises() -> [Exercise] {
        if let c = customCache { return c }
        var l = [Exercise]()
        if let f = file("strength_custom.tsv"), let t = try? String(contentsOf: f, encoding: .utf8) {
            for line in t.components(separatedBy: "\n") {
                let p = line.components(separatedBy: "\t")
                if p.count >= 6 && p[0] == "C" { l.append(Exercise(id: p[1], name: p[5], group: p[2], equipment: p[3], bodyweight: Double(p[4]) ?? 0)) }
            }
        }
        customCache = l
        return l
    }

    @discardableResult
    static func addCustomExercise(_ name: String, group: String, equipment eq: String, bodyweight: Double) -> Exercise {
        let ex = Exercise(id: "custom_" + slug(name) + "_" + String(TimeUtil.nowMillis() % 100000), name: clean(name), group: group,
                          equipment: eq, bodyweight: bodyweight)
        let all = customExercises() + [ex]
        write("strength_custom.tsv", "#pulseapp_strength_custom v1\n" + all.map { "C\t\($0.id)\t\($0.group)\t\($0.equipment)\t\($0.bodyweight)\t\(clean($0.name))\n" }.joined())
        customCache = all
        return ex
    }

    static func live() -> Workout? { return read("strength_live.tsv", tag: "L").first }
    static func saveLive(_ w: Workout?) {
        guard let w = w else { if let f = file("strength_live.tsv") { try? FileManager.default.removeItem(at: f) }; return }
        write("strength_live.tsv", encode([w], tag: "L"))
    }

    // MARK: Carga muscular (5/11, calibrada con el entreno del 4/11: WHOOP 8,1 → 0,04225 por kg de volumen efectivo)
    static let loadPerKg = 0.04225

    static func effectiveVolume(_ w: Workout, bodyKg: Double) -> Double {
        return w.exercises.reduce(0.0) { acc, e in
            let bw = exercise(e.exId)?.bodyweight ?? 0
            return acc + e.sets.reduce(0.0) { $0 + Double($1.reps) * ($1.kg + bw * bodyKg) }
        }
    }

    static func muscleLoad(_ w: Workout, bodyKg: Double) -> Double { return loadPerKg * effectiveVolume(w, bodyKg: bodyKg) }

    static func cardioMuscleSplit(_ cardio: Double, _ muscle: Double) -> (Int, Int) {
        let tot = cardio + muscle
        if tot <= 0 { return (100, 0) }
        let c = Int((cardio * 100 / tot).rounded())
        return (c, 100 - c)
    }

    // MARK: Récords (IA de WHOOP 5/11: con peso, el mayor peso; sin peso, más repeticiones; el volumen no da medalla)
    static func setScore(_ s: SetEntry) -> Double { return s.kg > 0 ? s.kg * 1000 + Double(s.reps) : Double(s.reps) }

    static func records(_ w: Workout) -> [[Bool]] {
        let earlier = logs().filter { $0.startMs < w.startMs && $0.id != w.id }
        return w.exercises.map { e in
            let prev = earlier.flatMap { o in o.exercises.filter { $0.exId == e.exId }.flatMap { $0.sets } }
            if prev.isEmpty { return e.sets.map { _ in false } }
            var bestKg = prev.map { $0.kg }.max() ?? 0
            var bestReps = prev.filter { $0.kg <= 0 }.map { $0.reps }.max() ?? 0
            return e.sets.map { s in
                if s.kg > 0 { if s.kg > bestKg + 1e-9 { bestKg = s.kg; return true }; return false }
                if bestKg <= 0 && s.reps > bestReps { bestReps = s.reps; return true }
                return false
            }
        }
    }

    static let milestones = [1, 3, 5, 10, 25, 50, 100, 250, 500]
    static func milestone(_ count: Int) -> (Int, Int) { return (count, milestones.first { $0 > count } ?? (count + 100)) }

    static func lastSetsOf(_ exId: String, before: Int64 = Int64.max) -> [SetEntry]? {
        for w in logs().filter({ $0.startMs < before }).sorted(by: { $0.startMs > $1.startMs }) {
            if let e = w.exercises.first(where: { $0.exId == exId }) { return e.sets.map { SetEntry($0.reps, $0.kg) } }
        }
        return nil
    }

    // MARK: Generar desde un texto (igual que Android)
    private static func firstMatch(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
    private static func replace(_ pattern: String, _ s: String, _ with: String = " ") -> String {
        return s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
    }

    static func parse(_ text: String) -> Workout {
        let w = Workout(TimeUtil.nowMillis(), 0, 0, "")
        var group = 0
        var parts = [String]()
        for line in text.components(separatedBy: CharacterSet(charactersIn: "\n;")) {
            let pieces = line.components(separatedBy: ",")
            let multi = pieces.count > 1 && pieces.filter { firstMatch("\\d", $0) != nil && firstMatch("[a-zA-ZáéíóúñÁÉÍÓÚÑ]{3,}", $0) != nil }.count >= 2
            if multi { parts.append(contentsOf: pieces) } else { parts.append(line) }
        }
        for raw in parts {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let f = line.first, "-•*·".contains(f) { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let joins = line.hasPrefix("+")
            if joins { while line.hasPrefix("+") { line.removeFirst() }; line = line.trimmingCharacters(in: .whitespaces) }
            let n = norm(line).replacingOccurrences(of: ",", with: ".")
            var sets = 3, reps = 10, kg = 0.0
            if let m = firstMatch("(\\d+)\\s*[x×*]\\s*(\\d+)", n) { sets = Int(m[1]) ?? 3; reps = Int(m[2]) ?? 10 }
            else if let m = firstMatch("(\\d+)\\s*series?\\s*(?:de\\s*)?(\\d+)", n) { sets = Int(m[1]) ?? 3; reps = Int(m[2]) ?? 10 }
            else {
                if let m = firstMatch("(\\d+)\\s*series?", n) { sets = Int(m[1]) ?? 3 }
                if let m = firstMatch("(\\d+)\\s*(?:rep|repeticion)", n) { reps = Int(m[1]) ?? 10 }
            }
            if let m = firstMatch("(\\d+(?:\\.\\d+)?)\\s*(kg|kilos?)", n) { kg = Double(m[1]) ?? 0 }
            var nameText = replace("\\d+(?:\\.\\d+)?\\s*(kg|kilos?)", n)
            nameText = replace("\\d+\\s*[x×*]\\s*\\d+", nameText)
            nameText = replace("\\d+\\s*series?\\s*(de\\s*)?\\d*", nameText)
            nameText = replace("\\d+\\s*(reps?|repeticiones?)", nameText)
            nameText = replace("\\b(con|de|del|la|el|en|a|al|y|los|las)\\b", nameText)
            nameText = replace("[^a-z ]", nameText).trimmingCharacters(in: .whitespaces)
            if nameText.isEmpty { continue }
            let ex = bestMatch(nameText)
            let entry = ExerciseEntry(ex?.id ?? ("custom_" + slug(nameText)), ex?.name ?? (nameText.prefix(1).uppercased() + nameText.dropFirst()))
            if joins, let prev = w.exercises.last {
                if prev.superset == 0 { group += 1; prev.superset = group }
                entry.superset = prev.superset
            }
            for _ in 0..<min(max(sets, 1), 12) { entry.sets.append(SetEntry(min(max(reps, 1), 100), min(max(kg, 0), 500))) }
            w.exercises.append(entry)
        }
        return w
    }

    private static let stop: Set<String> = ["de", "la", "el", "en", "con", "un", "una", "solo", "a", "y", "al", "del", "los", "las"]
    private static func stem(_ t: String) -> String {
        var s = t
        if s.hasSuffix("es") { s.removeLast(2) }
        if s.hasSuffix("s") { s.removeLast() }
        return s
    }
    private static func tokens(_ s: String) -> Set<String> {
        return Set(norm(s).components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
            .filter { !$0.isEmpty && !stop.contains($0) }.map { stem($0) })
    }

    static func bestMatch(_ q: String) -> Exercise? {
        let qt = tokens(q)
        if qt.isEmpty { return nil }
        var best: Exercise? = nil; var bestScore = 0.0
        for ex in library() {
            let et = tokens(ex.name)
            if et.isEmpty { continue }
            let common = qt.filter { a in et.contains { b in a == b || (a.count >= 4 && b.hasPrefix(a)) || (b.count >= 4 && a.hasPrefix(b)) } }.count
            if common == 0 { continue }
            let score = Double(common) / Double(qt.count) + 0.3 * Double(common) / Double(et.count)
            if score > bestScore + 1e-9 { bestScore = score; best = ex }
        }
        return bestScore >= 0.5 ? best : nil
    }

    // MARK: Entrenamientos de ejemplo
    static func presets() -> [Workout] {
        func w(_ name: String, _ ex: [(String, Int, Int)]) -> Workout {
            let wk = Workout(-1, 0, 0, name)
            for (n, sets, reps) in ex {
                guard let e = lib.first(where: { $0.name == n }) else { continue }
                wk.exercises.append(ExerciseEntry(e.id, e.name, 0, (0..<sets).map { _ in SetEntry(reps, 0) }))
            }
            return wk
        }
        return [
            w("Torso: empuje", [("Press de banca - Mancuerna", 4, 8), ("Press de banca - Inclinado - Mancuerna", 3, 10),
                                ("Press de hombros - Sentado - Mancuernas", 3, 10), ("Elevaciones laterales - Mancuernas", 3, 12),
                                ("Extensión de tríceps - Polea", 3, 12)]),
            w("Torso: tirón", [("Dominada", 4, 8), ("Remo con barra", 4, 8), ("Jalón al pecho - Polea", 3, 10),
                               ("Face pull - Polea", 3, 15), ("Curl de bíceps - Mancuernas", 3, 12)]),
            w("Pierna", [("Sentadilla - Barra", 4, 8), ("Peso muerto rumano - Barra", 3, 10), ("Prensa de piernas", 3, 12),
                         ("Curl femoral tumbado - Máquina", 3, 12), ("Elevación de gemelos de pie", 4, 15)]),
            w("Cuerpo completo", [("Sentadilla goblet - Mancuerna", 3, 10), ("Press de banca - Mancuerna", 3, 10),
                                  ("Remo con mancuerna - Un brazo", 3, 10), ("Hip thrust - Barra", 3, 10), ("Plancha", 3, 1)]),
            w("Peso corporal", [("Flexiones", 4, 12), ("Dominada", 4, 6), ("Sentadilla - Peso corporal", 4, 20),
                                ("Zancadas caminando", 3, 12), ("Abdominales en bicicleta", 3, 20)]),
            w("Core", [("Plancha", 3, 1), ("Elevación de piernas colgado", 3, 10), ("Russian twist", 3, 20),
                       ("Dead bug", 3, 12), ("Copenhague", 3, 8)])
        ]
    }
}
