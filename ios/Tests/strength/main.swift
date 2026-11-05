import Foundation

// Comprobación en CI (5/11): el entrenador de fuerza en Swift (Strength.swift) da lo mismo que Android (Strength.kt):
// la biblioteca de ejercicios, lo que entiende del texto ("press banca 4x8 40 kg…"), el volumen efectivo y la carga muscular
// (la que entra en el esfuerzo) y que guardar/leer el archivo no cambia nada. expected.txt lo genera Kotlin con input.txt.
let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/strength"
Strength.dir = URL(fileURLWithPath: NSTemporaryDirectory())
let input = try! String(contentsOfFile: dir + "/input.txt", encoding: .utf8)
let expected = try! String(contentsOfFile: dir + "/expected.txt", encoding: .utf8).split(separator: "\n").map(String.init)
var out = [String]()
for e in Strength.library() { out.append("LIB|\(e.id)|\(e.name)|\(e.group)|\(e.equipment)|\(e.bodyweight)") }
let w = Strength.parse(input)
for e in w.exercises {
    out.append("PARSE|\(e.exId)|\(e.name)|\(e.superset)|\(e.sets.count)|\(e.sets[0].reps)|\(String(format: "%.2f", e.sets[0].kg))")
}
out.append("EFF|\(String(format: "%.4f", Strength.effectiveVolume(w, bodyKg: 68)))|\(String(format: "%.4f", Strength.muscleLoad(w, bodyKg: 68)))")
w.id = 7; w.startMs = 1000; w.endMs = 2000
let enc = Strength.encode([w], tag: "L")
out.append("ROUNDTRIP|\(Strength.encode(Strength.decode(enc, tag: "L"), tag: "L") == enc)")
var bad = 0
for i in 0..<max(out.count, expected.count) {
    let a = i < out.count ? out[i] : "(nada)", b = i < expected.count ? expected[i] : "(nada)"
    if a != b { bad += 1; print("::warning::Fuerza línea \(i + 1): Swift «\(a)» / Kotlin «\(b)»") }
}
print("::notice::Entrenador de fuerza: \(out.count - bad) de \(expected.count) líneas iguales a Android")
if bad > 0 { print("::error::El entrenador de fuerza en Swift no coincide con Android en \(bad) líneas"); exit(1) }
