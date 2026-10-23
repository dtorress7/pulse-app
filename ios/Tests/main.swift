import Foundation

// Comprobación en CI (macOS): el modelo de fases en Swift da lo mismo que el entrenado en Python (ref = noches 17 y 23).
struct Night: Decodable { let secs: [[[JSONNum]]]; let mot: [[Double]?]; let stages: String }
enum JSONNum: Decodable {
    case n(Double), a([Double])
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let x = try? c.decode(Double.self) { self = .n(x) } else { self = .a(try c.decode([Double].self)) }
    }
}
let args = CommandLine.arguments
SleepModel.modelURL = URL(fileURLWithPath: args[2])
let ref = try! JSONDecoder().decode([String: Night].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
var ok = 0, tot = 0
for (d, night) in ref.sorted(by: { $0.key < $1.key }) {
    let secs: [[SleepModel.Second]] = night.secs.map { minute in minute.map { s in
        var bpm = 0.0; var rr = [Double]()
        if case .n(let b) = s[0] { bpm = b }
        if case .a(let r) = s[1] { rr = r }
        return SleepModel.Second(bpm: Int(bpm), rr: rr)
    } }
    let mot: [SleepModel.Minute?] = night.mot.map { m in m.map { SleepModel.Minute(still: $0[0], gyro: $0[1], steps: $0[2]) } }
    guard let st = SleepModel.classify(secs, mot) else { print("::error::no se pudo cargar el modelo"); exit(1) }
    let s = st.map { ["D", "L", "P", "R"][$0] }.joined()
    let same = zip(s, night.stages).filter { $0 == $1 }.count
    ok += same; tot += s.count
    print("::notice::Fases Swift vs Python noche \(d): \(same)/\(s.count) iguales")
}
if ok < tot { print("::error::El modelo de fases en Swift no coincide (\(ok)/\(tot))"); exit(1) }
