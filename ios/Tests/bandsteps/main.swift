import Foundation
// Comprobación de BandSteps.swift (30/10): con las muestras reales del contador de pasos de la pulsera (historial 19–21/10, generadas
// con BandSteps.kt), el ciclo de WHOOP del 20/10 (19/10 21:11:19Z → 20/10 21:14:53Z) debe dar 6029 pasos, igual que Android (WHOOP 6015).
enum AppPaths { static func file(_ n: String) -> URL { return URL(fileURLWithPath: n) } }
struct MotionMinute { let minuteStartUnix: Int64; let steps: Int }

let band = BandSteps.read(url: URL(fileURLWithPath: "Tests/bandsteps/band_steps.csv"))
let cycle = BandSteps.merged(band, [], fromMs: 1792444279000, toMs: 1792530893000)
// Hueco sin historial con PulseApp contando de menos: se queda el mayor (la pulsera)
let imuFew = [MotionMinute(minuteStartUnix: 1792500000, steps: 10)]
let withImu = BandSteps.merged(band, imuFew, fromMs: 1792444279000, toMs: 1792530893000)
print("BandSteps Swift: ciclo 20/10 = \(cycle) (Android 6029, WHOOP 6015); con PulseApp en el hueco = \(withImu)")
if cycle != 6029 || withImu != 6029 { print("::error::BandSteps.swift no da lo mismo que Android"); exit(1) }
