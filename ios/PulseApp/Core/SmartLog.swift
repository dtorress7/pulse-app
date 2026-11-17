import Foundation

/* 17/11: "Registro inteligente" del diario (WHOOP lo hace con su IA en la nube). Aquí, en el móvil: se parte el texto en frases y
   cada comportamiento del diario que aparece en una frase se marca sí, o no si la frase lleva "no", "sin", "nada", "ni" o "tampoco".
   Solo mira las preguntas que tienes en el diario. */
enum SmartLog {
    /// Palabras de cada comportamiento (además de las de su nombre), ya sin tildes.
    private static let synonyms: [String: [String]] = [
        "Alcohol": ["alcohol", "cerveza", "vino", "copa", "cubata", "birra", "chupito", "whisky", "ginebra"],
        "Cafeína": ["cafe", "cafeina", "red bull", "monster", "energetica", "cola"],
        "Desayuno": ["desayun"],
        "Almuerzo": ["almorc", "almorz", "almuerz", "comida del mediodia", "comi a mediodia"],
        "Cena": ["cene", "cena"],
        "Comida tardía": ["cene tarde", "comi tarde", "cena tarde", "antes de dormir", "antes de acostarme", "antes de irme a la cama"],
        "Comiste antes de entrenar": ["antes de entrenar", "antes del entreno", "antes de jugar", "antes del partido"],
        "Hidratación": ["agua", "hidrat", "litro"],
        "Dispositivo (por ejemplo, teléfono) en la cama": ["movil en la cama", "telefono en la cama", "pantalla en la cama", "tablet en la cama", "movil antes de dormir"],
        "¿Lees en la cama?": ["lei", "leer", "leyendo", "libro"],
        "Dormir en cama propia": ["mi cama", "cama de siempre"],
        "Cama compartida": ["con mi pareja", "con mi novia", "con mi novio", "compart"],
        "Restaurante": ["restaurante", "fuera a comer", "fuera a cenar", "comi fuera", "cene fuera"],
        "Cocinado en casa": ["casera", "cocine", "en casa"],
        "Snack de la tarde": ["merend", "snack por la tarde", "picoteo"],
        "Snack por la tarde": ["merend", "snack por la tarde"],
        "Frutas y verduras": ["fruta", "verdura", "ensalada"],
        "Proteína": ["proteina", "batido"],
        "Lácteos": ["leche", "yogur", "queso", "lacteo"],
        "Suplemento de magnesio": ["magnesio"],
        "Suplemento de Omega 3": ["omega"],
        "Creatina": ["creatina"],
        "Actividad sexual": ["sexo", "relaciones"],
        "Vacaciones": ["vacaciones"],
        "Videojuegos": ["videojuego", "playstation", "consola"],
        "Llamadas de trabajo": ["videollamada", "reunion", "llamadas"],
        "Desplazamiento al trabajo": ["fui al trabajo", "fui a trabajar", "oficina"],
        "Meditación": ["medit"],
        "Estrés": ["estres", "estresad"],
        "Siesta": ["siesta"]
    ]
    private static let negations: Set<String> = ["no", "sin", "nada", "ni", "tampoco", "ningun", "ninguna", "ninguno", "nunca"]
    private static let stop: Set<String> = ["para", "con", "del", "las", "los", "una", "por", "ejemplo", "que", "mas", "muy", "tus"]

    static func parse(_ text: String, questions: [String]) -> [String: Bool] {
        let t = " " + JournalCatalog.fold(text) + " "
        var clauses = [String]()
        for c in t.components(separatedBy: CharacterSet(charactersIn: ".,;:\n!?")) {
            for part in c.replacingOccurrences(of: " pero ", with: "|").replacingOccurrences(of: " y ", with: "|").components(separatedBy: "|") {
                clauses.append(" " + part.trimmingCharacters(in: .whitespaces) + " ")
            }
        }
        var out = [String: Bool]()
        for q in questions {
            let name = JournalCatalog.name(q)
            let syn = (synonyms[name] ?? []).map { JournalCatalog.fold($0) }
            // Palabras del nombre: tienen que salir TODAS en la frase ("Baño helado" = baño + helado)
            let own = JournalCatalog.fold(name).components(separatedBy: CharacterSet.letters.inverted)
                .filter { $0.count >= 4 && !stop.contains($0) }.map { $0.count > 5 ? String($0.dropLast()) : $0 }
            if syn.isEmpty && own.isEmpty { continue }
            for c in clauses {
                let words = c.split(separator: " ").map(String.init)
                func has(_ k: String) -> Bool { return k.contains(" ") ? c.contains(k) : words.contains { $0.hasPrefix(k) } }
                if syn.contains(where: has) || (!own.isEmpty && own.allSatisfy(has)) {
                    out[q] = !words.contains { negations.contains($0) }
                }
            }
        }
        return out
    }
}
