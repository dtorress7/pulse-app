import Foundation
import SwiftUI

/* 17/11: "Vista de tendencias" como WHOOP (vídeo del usuario). Al tocar un dato de Inicio (pasos, VFC…) se abre con ese dato;
   arriba se elige cualquier otro. S / M / 6 M, promedio, % frente al periodo anterior, frase, gráfica (barras o línea con tu
   rango típico), desglose por niveles y "¿Qué es…?". Solo muestra lo que ya calcula PulseApp: no cambia ningún cálculo. */

struct TrendMetric {
    enum Kind { case avg, weekSum }
    enum Style { case bars, line }
    let key: String
    let name: String
    let icon: String
    let group: String
    let unit: String
    let kind: Kind
    let style: Style
    let goodWhenHigh: Bool?
    let format: (Double) -> String
    let value: (DayRecord, [ActivitySession]) -> Double?
    let whatTitle: String
    let whatText: String
    var breakdownTitle: String? = nil
    var breakdown: [(String, Color, (Double) -> Bool)] = []
    var color: (Double) -> Color = { _ in Theme.strainBlue }
    /// Otra pantalla en lugar de la gráfica (WHOOP Age, estrés).
    var route: Route? = nil
}

enum TrendCatalog {
    static let groups = ["Esfuerzo", "Recuperación", "Sueño", "Salud", "Estrés"]

    private static func hm(_ v: Double) -> String { return Fmt.hm(Int(v.rounded())) }
    private static func pct(_ v: Double) -> String { return String(format: "%.0f %%", v) }
    private static func int0(_ v: Double) -> String { return Fmt.int(v) }
    private static func thousands(_ v: Double) -> String { return Fmt.thousands(Int64(v.rounded())) }

    /// Minutos del día en las zonas [zs] (1…5): del pulso del día si lo hay, si no de las actividades (días importados de WHOOP).
    private static func zoneMinutes(_ r: DayRecord, _ s: [ActivitySession], _ zs: [Int]) -> Double? {
        if let z = r.zones, z.totalSeconds > 0 {
            let secs = [0, z.z1, z.z2, z.z3, z.z4, z.z5]
            return Double(zs.reduce(0) { $0 + secs[$1] }) / 60.0
        }
        if s.isEmpty { return r.strain != nil ? 0 : nil }
        return Double(s.reduce(0) { acc, x in
            let m = [x.minutesZone0, x.minutesZone1, x.minutesZone2, x.minutesZone3, x.minutesZone4, x.minutesZone5]
            return acc + zs.reduce(0) { $0 + m[$1] }
        })
    }

    static func strengthMinutes(_ s: [ActivitySession]) -> Double {
        return s.filter { Formulas.isStrength($0.type) || Formulas.isWeights($0.type) }
            .reduce(0.0) { $0 + Double($1.endMillis - $1.startMillis) / 60_000.0 }
    }

    static let all: [TrendMetric] = [
        // ---------- Esfuerzo ----------
        TrendMetric(key: PanelKeys.strain, name: "Esfuerzo del día", icon: "flame.fill", group: "Esfuerzo", unit: "", kind: .avg, style: .bars,
                    goodWhenHigh: nil, format: { Fmt.comma($0) }, value: { r, _ in r.strain },
                    whatTitle: "¿Qué es Esfuerzo del día?",
                    whatText: "El esfuerzo del día mide el esfuerzo total acumulado a lo largo de todo el día, tanto el cardiovascular como el muscular, en una escala de 0 a 21.\n\nCualquier cosa que aumente tu frecuencia cardíaca suma esfuerzo cardiovascular; por eso puedes levantarte con un esfuerzo de 0 a 4. El esfuerzo muscular mide lo que exiges a tus músculos en actividades como el levantamiento de pesas. Conocerlo te ayuda a entrenar con más eficacia y a descansar cuando lo necesitas.",
                    breakdownTitle: "Desglose del esfuerzo",
                    breakdown: [("Esfuerzo total (>18,0)", Color(hex: 0x0B5FA8), { $0 > 18 }),
                                ("Extenuante (14,1-18,0)", Color(hex: 0x1683D6), { $0 > 14 && $0 <= 18 }),
                                ("Moderado (10,1-14,0)", Color(hex: 0x3FA6F2), { $0 > 10 && $0 <= 14 }),
                                ("Ligero (<10,0)", Color(hex: 0x86C8F7), { $0 <= 10 })]),
        TrendMetric(key: PanelKeys.steps, name: "Pasos", icon: "figure.walk", group: "Esfuerzo", unit: "", kind: .avg, style: .bars,
                    goodWhenHigh: true, format: TrendCatalog.thousands, value: { r, _ in r.steps.map { Double($0) } },
                    whatTitle: "¿Qué son los pasos?",
                    whatText: "Los pasos que das cada día, contados por la pulsera (o por el movimiento que recibe PulseApp cuando no hay historial de la pulsera). Moverte más cada día mejora tu salud a largo plazo."),
        TrendMetric(key: PanelKeys.z13, name: "Zonas de frecuencia cardíaca 1-3", icon: "heart.circle", group: "Esfuerzo", unit: "hr",
                    kind: .weekSum, style: .bars, goodWhenHigh: true, format: TrendCatalog.hm, value: { r, s in TrendCatalog.zoneMinutes(r, s, [1, 2, 3]) },
                    whatTitle: "¿Qué son las zonas de FC 1-3?",
                    whatText: "El tiempo que pasas a intensidad baja o moderada (del 38,5 % al 80 % de tu reserva de FC). Acumular tiempo semanal en estas zonas mejora tu base aeróbica y tu salud cardiovascular. Se cuenta todo el día, no solo las actividades."),
        TrendMetric(key: PanelKeys.z45, name: "Zonas de frecuencia cardíaca 4-5", icon: "bolt.heart.fill", group: "Esfuerzo", unit: "hr",
                    kind: .weekSum, style: .bars, goodWhenHigh: true, format: TrendCatalog.hm, value: { r, s in TrendCatalog.zoneMinutes(r, s, [4, 5]) },
                    whatTitle: "¿Qué son las zonas de FC 4-5?",
                    whatText: "El tiempo que pasas a intensidad alta (por encima del 80 % de tu reserva de FC). Un poco cada semana mejora tu capacidad aeróbica y tu VO₂ máx.",
                    color: { _ in Theme.alertAmber }),
        TrendMetric(key: PanelKeys.strength, name: "Tiempo de actividad de fuerza", icon: "dumbbell.fill", group: "Esfuerzo", unit: "hr",
                    kind: .weekSum, style: .bars, goodWhenHigh: true, format: TrendCatalog.hm,
                    value: { r, s in r.strain != nil || !s.isEmpty ? TrendCatalog.strengthMinutes(s) : nil },
                    whatTitle: "¿Qué es el tiempo de actividad de fuerza?",
                    whatText: "Los minutos de tus actividades de fuerza (entrenamiento funcional, pesas, gimnasio…) de cada semana. El trabajo de fuerza mantiene la masa muscular y la salud ósea con los años."),
        TrendMetric(key: PanelKeys.kcal, name: "Calorías", icon: "flame", group: "Esfuerzo", unit: "", kind: .avg, style: .bars,
                    goodWhenHigh: nil, format: TrendCatalog.thousands, value: { r, _ in r.kcal },
                    whatTitle: "¿Qué son las calorías?",
                    whatText: "La energía que gastas en el día: tu gasto en reposo más lo que suman tus actividades según su pulso."),
        TrendMetric(key: PanelKeys.vo2, name: "VO₂ máx", icon: "lungs.fill", group: "Esfuerzo", unit: "", kind: .avg, style: .line,
                    goodWhenHigh: true, format: TrendCatalog.int0, value: { r, _ in r.vo2 },
                    whatTitle: "¿Qué es el VO₂ máx?",
                    whatText: "La cantidad máxima de oxígeno que tu cuerpo puede usar durante el ejercicio (ml/kg/min). Es uno de los mejores indicadores de tu forma física. PulseApp lo estima con tu FC máxima y tu FC en reposo y lo actualiza los martes."),
        // ---------- Recuperación ----------
        TrendMetric(key: "recovery", name: "Recuperación", icon: "bolt.circle", group: "Recuperación", unit: "%", kind: .avg, style: .bars,
                    goodWhenHigh: true, format: TrendCatalog.pct, value: { r, _ in r.recovery.map { Double($0) } },
                    whatTitle: "¿Qué es la recuperación?",
                    whatText: "Lo preparado que está tu cuerpo para rendir hoy, de 1 a 99 %. Sale de tu VFC y tu FC en reposo de esta noche frente a tu media de las últimas semanas: más VFC y menos pulso que de costumbre, más recuperación.",
                    breakdownTitle: "Desglose de la recuperación",
                    breakdown: [("Verde (67-99 %)", Theme.wRecoveryHigh, { $0 >= 67 }),
                                ("Amarillo (34-66 %)", Color(hex: 0xFFDE00), { $0 >= 34 && $0 < 67 }),
                                ("Rojo (1-33 %)", Color(hex: 0xFF0026), { $0 < 34 })],
                    color: { Theme.wRecoveryColor(Int($0.rounded())) }),
        TrendMetric(key: PanelKeys.hrv, name: "Variabilidad de la frecuencia cardíaca", icon: "waveform.path.ecg", group: "Recuperación", unit: "ms",
                    kind: .avg, style: .line, goodWhenHigh: true, format: TrendCatalog.int0, value: { r, _ in r.hrv },
                    whatTitle: "¿Qué es la variabilidad de la frecuencia cardíaca?",
                    whatText: "La variabilidad de la frecuencia cardíaca (VFC) es la variación del tiempo entre los latidos del corazón mientras duermes. Es un buen indicador de cómo se adapta tu cuerpo al estrés: por lo general, una VFC más alta que tu media indica que estás más recuperado."),
        TrendMetric(key: PanelKeys.rhr, name: "Frecuencia cardíaca en reposo", icon: "heart.fill", group: "Recuperación", unit: "lpm",
                    kind: .avg, style: .line, goodWhenHigh: false, format: TrendCatalog.int0, value: { r, _ in r.rhr.map { Double($0) } },
                    whatTitle: "¿Qué es la frecuencia cardíaca en reposo?",
                    whatText: "El número de veces que late tu corazón por minuto en reposo, medido mientras duermes. Una FC en reposo más baja que tu media suele indicar buena recuperación; más alta puede venir de entrenar fuerte, alcohol, estrés o enfermedad."),
        TrendMetric(key: "resp", name: "Frecuencia respiratoria", icon: "lungs", group: "Recuperación", unit: "rpm",
                    kind: .avg, style: .line, goodWhenHigh: nil, format: { Fmt.comma($0) }, value: { r, _ in r.resp },
                    whatTitle: "¿Qué es la frecuencia respiratoria?",
                    whatText: "Las respiraciones por minuto mientras duermes. Suele ser muy estable; una subida clara sobre tu rango habitual puede ser señal de que te estás poniendo enfermo."),
        // ---------- Sueño ----------
        TrendMetric(key: PanelKeys.sleepScore, name: "Calificación del sueño", icon: "moon", group: "Sueño", unit: "%", kind: .avg, style: .bars,
                    goodWhenHigh: true, format: TrendCatalog.pct, value: { r, _ in r.sleepScore.map { Double($0) } },
                    whatTitle: "¿Qué es la calificación del sueño?",
                    whatText: "Lo bien que dormiste, de 0 a 100 %: combina las horas que dormiste frente a lo que necesitabas, tu eficiencia y tu regularidad.",
                    breakdownTitle: "Desglose del sueño",
                    breakdown: [("Óptimo (≥85 %)", Theme.wMint, { $0 >= 85 }),
                                ("Suficiente (70-85 %)", Color(hex: 0xFFDE00), { $0 >= 70 && $0 < 85 }),
                                ("Deficiente (<70 %)", Theme.alertAmber, { $0 < 70 })],
                    color: { _ in Theme.wRingSleep }),
        TrendMetric(key: "sleep_hours", name: "Horas de sueño", icon: "bed.double.fill", group: "Sueño", unit: "hr", kind: .avg, style: .bars,
                    goodWhenHigh: true, format: TrendCatalog.hm, value: { r, _ in r.sleepMinutes.map { Double($0) } },
                    whatTitle: "¿Qué son las horas de sueño?",
                    whatText: "El tiempo que pasaste dormido: el tiempo en cama sin los ratos despierto.", color: { _ in Theme.wRingSleep }),
        TrendMetric(key: "in_bed", name: "Tiempo en cama", icon: "bed.double", group: "Sueño", unit: "hr", kind: .avg, style: .bars,
                    goodWhenHigh: nil, format: TrendCatalog.hm, value: { r, _ in r.inBed.map { Double($0) } },
                    whatTitle: "¿Qué es el tiempo en cama?",
                    whatText: "Desde que te duermes hasta que te despiertas, incluidos los ratos despierto.", color: { _ in Theme.wRingSleep }),
        TrendMetric(key: "hours_vs_need", name: "Horas vs. lo necesario (%)", icon: "percent", group: "Sueño", unit: "%", kind: .avg, style: .bars,
                    goodWhenHigh: true, format: TrendCatalog.pct, value: { r, _ in r.hoursVsNeedPct.map { Double($0) } },
                    whatTitle: "¿Qué es horas vs. lo necesario?",
                    whatText: "Lo que dormiste frente a lo que necesitabas esa noche (tu referencia por edad, más lo que pide el esfuerzo de la víspera y la deuda de sueño, menos las siestas).",
                    color: { _ in Theme.wRingSleep }),
        TrendMetric(key: "need_last", name: "Sueño necesario", icon: "hourglass", group: "Sueño", unit: "hr", kind: .avg, style: .bars,
                    goodWhenHigh: nil, format: TrendCatalog.hm, value: { r, _ in r.needLastNight.map { Double($0) } },
                    whatTitle: "¿Qué es el sueño necesario?",
                    whatText: "Lo que necesitabas dormir esa noche: tu referencia por edad, más lo que pide el esfuerzo de la víspera y la deuda de sueño, menos las siestas.",
                    color: { _ in Theme.wRingSleep }),
        TrendMetric(key: PanelKeys.efficiency, name: "Eficiencia del sueño", icon: "chart.bar.fill", group: "Sueño", unit: "%", kind: .avg, style: .bars,
                    goodWhenHigh: true, format: TrendCatalog.pct, value: { r, _ in r.efficiency.map { Double($0) } },
                    whatTitle: "¿Qué es la eficiencia del sueño?",
                    whatText: "El porcentaje del tiempo en cama que pasaste dormido.", color: { _ in Theme.wRingSleep }),
        TrendMetric(key: PanelKeys.regularity, name: "Regularidad del sueño", icon: "clock.arrow.circlepath", group: "Sueño", unit: "%", kind: .avg,
                    style: .bars, goodWhenHigh: true, format: TrendCatalog.pct, value: { r, _ in r.consistency.map { Double($0) } },
                    whatTitle: "¿Qué es la regularidad del sueño?",
                    whatText: "Cuánto se parecen tus horas de dormir y despertar a las de las 3 noches anteriores. Acostarte y levantarte a horas parecidas mejora la calidad del sueño.",
                    color: { _ in Theme.wRingSleep }),
        TrendMetric(key: "restorative", name: "Sueño reparador (horas)", icon: "sparkles", group: "Sueño", unit: "hr", kind: .avg, style: .bars,
                    goodWhenHigh: true, format: TrendCatalog.hm, value: { r, _ in r.restorative.map { Double($0) } },
                    whatTitle: "¿Qué es el sueño reparador?",
                    whatText: "El tiempo en sueño profundo más REM: las fases en las que el cuerpo y la mente se recuperan de verdad.",
                    color: { _ in Color(hex: 0xB45CF2) }),
        TrendMetric(key: PanelKeys.debt, name: "Deuda de sueño", icon: "hourglass.bottomhalf.filled", group: "Sueño", unit: "hr", kind: .avg,
                    style: .bars, goodWhenHigh: false, format: TrendCatalog.hm, value: { r, _ in r.debt.map { Double($0) } },
                    whatTitle: "¿Qué es la deuda de sueño?",
                    whatText: "El sueño que te faltó en las noches anteriores y que se suma a lo que necesitas esta noche.",
                    color: { _ in Theme.wRingSleep }),
        // ---------- Salud y estrés: abren su propia pantalla ----------
        TrendMetric(key: "whoop_age", name: "WHOOP Age", icon: "circle.hexagongrid", group: "Salud", unit: "", kind: .avg, style: .line,
                    goodWhenHigh: false, format: { Fmt.comma($0) }, value: { _, _ in nil }, whatTitle: "", whatText: "", route: .healthspan),
        TrendMetric(key: "aging_pace", name: "Ritmo de envejecimiento", icon: "speedometer", group: "Salud", unit: "", kind: .avg, style: .line,
                    goodWhenHigh: false, format: { Fmt.comma($0) }, value: { _, _ in nil }, whatTitle: "", whatText: "", route: .healthspan),
        TrendMetric(key: "stress_total", name: "Estrés total diurno", icon: "gauge", group: "Estrés", unit: "", kind: .avg, style: .bars,
                    goodWhenHigh: nil, format: TrendCatalog.hm, value: { _, _ in nil }, whatTitle: "", whatText: "", route: .stressTrends(0, 0)),
        TrendMetric(key: "stress_rest", name: "Estrés no relacionado con la actividad", icon: "figure.stand", group: "Estrés", unit: "", kind: .avg,
                    style: .bars, goodWhenHigh: nil, format: TrendCatalog.hm, value: { _, _ in nil }, whatTitle: "", whatText: "", route: .stressTrends(1, 0)),
        TrendMetric(key: "stress_sleep", name: "Estrés del sueño", icon: "moon.zzz", group: "Estrés", unit: "", kind: .avg, style: .bars,
                    goodWhenHigh: nil, format: TrendCatalog.hm, value: { _, _ in nil }, whatTitle: "", whatText: "", route: .stressTrends(2, 0))
    ]

    static func metric(_ key: String) -> TrendMetric {
        return all.first { $0.key == key } ?? all[0]
    }
}

struct TrendsView: View {
    let initialKey: String
    @Binding var path: [Route]
    @State private var key = ""
    @State private var period = 1        // 0 = S, 1 = M, 2 = 6 M
    @State private var shift = 0
    @State private var data: HomeData? = nil
    @State private var showPicker = false
    @State private var selected: Int? = nil
    private let months = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]
    private let wd = ["L", "M", "X", "J", "V", "S", "D"]

    private var metric: TrendMetric { return TrendCatalog.metric(key.isEmpty ? initialKey : key) }

    var body: some View {
        WScreen {
            DetailHeader(title: "Vista de tendencias")
            picker.padding(.top, 16)
            if !showPicker {
                if let d = data {
                    content(d)
                } else {
                    ScreenLoading()
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if key.isEmpty { key = initialKey }
            if data == nil {
                HomeStore.shared.run({ HomeDataLoader.load(dayOffset: 0, historyDays: 400) }, completion: { data = $0 })
            }
        }
    }

    // MARK: Selector de dato (lista por apartados, como WHOOP)

    private var picker: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(.easeOut(duration: 0.2)) { showPicker.toggle() } }) {
                HStack(spacing: 16) {
                    Image(systemName: metric.icon).font(.system(size: 19)).foregroundColor(Theme.textSecondary).frame(width: 24)
                    WTitle(text: metric.name, size: 15).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: showPicker ? "chevron.up" : "chevron.down").font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }
                .padding(18)
            }
            .buttonStyle(.plain)
            if showPicker {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(TrendCatalog.groups, id: \.self) { g in
                        WTitle(text: g, size: 12, color: Theme.textSecondary).padding(.top, 16).padding(.bottom, 4).padding(.horizontal, 18)
                        ForEach(TrendCatalog.all.filter { $0.group == g }, id: \.key) { m in
                            Button(action: { choose(m) }) {
                                HStack(spacing: 16) {
                                    Image(systemName: m.icon).font(.system(size: 17)).foregroundColor(Theme.textSecondary).frame(width: 24)
                                    WTitle(text: m.name, size: 14).multilineTextAlignment(.leading)
                                    Spacer()
                                    if m.key == metric.key {
                                        Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.wMint)
                                    }
                                }
                                .padding(.horizontal, 18).frame(minHeight: 48)
                                .background(m.key == metric.key ? Color.white.opacity(0.06) : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, 12)
                .background(Color.black)
            }
        }
        .background(Theme.wCard).cornerRadius(14)
    }

    private func choose(_ m: TrendMetric) {
        withAnimation(.easeOut(duration: 0.2)) { showPicker = false }
        if let r = m.route { path.append(r); return }
        key = m.key
        selected = nil
    }

    // MARK: Periodos

    private func range() -> (String, String) {
        let today = Day.today()
        switch period {
        case 0: return (Day.add(today, -6 - 7 * shift), Day.add(today, -7 * shift))
        case 1: return (Day.add(today, -29 - 30 * shift), Day.add(today, -30 * shift))
        default: return (Day.add(today, -181 - 182 * shift), Day.add(today, -182 * shift))
        }
    }

    private func dayList(_ a: String, _ b: String) -> [String] {
        var out = [String](); var d = a
        while d <= b { out.append(d); d = Day.add(d, 1) }
        return out
    }

    private func label(_ d: String) -> String { return "\(Day.dayOfMonth(d)) \(months[Day.month(d) - 1])." }

    /// Valor de cada día del periodo (nil = sin dato).
    private func dayValues(_ d: HomeData, _ days: [String]) -> [Double?] {
        var byDate = [String: DayRecord]()
        for r in d.records { byDate[r.date] = r }
        var sess = [String: [ActivitySession]]()
        for s in AppStore.shared.allSessions() { sess[TimeUtil.dayKey(s.startMillis), default: []].append(s) }
        return days.map { day in
            guard let r = byDate[day] else { return nil }
            return metric.value(r, (sess[day] ?? []).filter { $0.type != Formulas.napType })
        }
    }

    /// Promedio del periodo: media de los días (sin hoy) o, en los datos semanales, media de los totales de cada semana.
    private func average(_ days: [String], _ vals: [Double?]) -> Double? {
        let today = Day.today()
        let pairs = zip(days, vals).filter { $0.0 != today }
        if metric.kind == .weekSum {
            let withData = pairs.compactMap { $0.1 }
            if withData.isEmpty { return nil }
            return withData.reduce(0, +) / Double(withData.count) * 7
        }
        let v = pairs.compactMap { $0.1 }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    // MARK: Contenido

    @ViewBuilder private func content(_ d: HomeData) -> some View {
        let m = metric
        let today = Day.today()
        let (a, b) = range()
        let days = dayList(a, b)
        let prevDays = days.map { Day.add($0, -days.count) }
        let vals = dayValues(d, days)
        let avg = average(days, vals)
        let prev = average(prevDays, dayValues(d, prevDays))
        let headline = m.kind == .weekSum ? (period == 0 ? "Total semanal" : "Total semanal prom.") : "Promedio"
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                WTitle(text: headline, size: 12.5, color: Theme.textSecondary)
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    WNumber(text: avg.map { m.format($0) } ?? "--", size: 38)
                    if !m.unit.isEmpty && m.unit != "%" { WNumber(text: m.unit, size: 17) }
                }
                if let av = avg, let pv = prev, pv > 0 {
                    let up = av >= pv
                    let good: Bool? = m.goodWhenHigh.map { $0 == up }
                    let c = good == nil ? Theme.textSecondary : (good! ? Theme.wMint : Theme.alertAmber)
                    let what = ["la semana anterior", "el mes anterior", "los 6 meses anteriores"][period]
                    WNumber(text: (up ? "▲ " : "▼ ") + "\(Int((abs(av - pv) * 100 / pv).rounded())) % vs. \(what)", size: 13, color: c)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(c.opacity(0.12)).cornerRadius(5)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Segmented(labels: ["S", "M", "6 M"], selected: Binding(get: { period }, set: { period = $0; shift = 0; selected = nil }))
                    .frame(width: 190).padding(.top, -20)
                HStack(spacing: 4) {
                    Button(action: { shift += 1; selected = nil }) {
                        Image(systemName: "chevron.left").foregroundColor(Theme.textPrimary).frame(width: 32, height: 32)
                    }
                    WTitle(text: "\(label(a)) - \(label(b)) \(TimeUtil.parts(Day.start(b)).year % 100)", size: 13)
                    Button(action: { if shift > 0 { shift -= 1; selected = nil } }) {
                        Image(systemName: "chevron.right").foregroundColor(Theme.textPrimary.opacity(shift > 0 ? 1 : 0.3)).frame(width: 32, height: 32)
                    }
                }
            }
        }
        .padding(.top, 26)
        WBody(text: sentence(avg, prev), size: 16, color: Theme.textPrimary).padding(.top, 22)

        let series = chartSeries(days, vals)
        if let i = selected, i < series.count, let v = series[i].value {
            HStack(spacing: 8) {
                WNumber(text: m.format(v) + (m.unit.isEmpty || m.unit == "%" ? "" : " " + m.unit), size: 20)
                WBody(text: series[i].title, size: 13)
            }
            .padding(.top, 18)
        }
        chart(series, avg: m.kind == .weekSum && period == 0 ? nil : avg, band: m.style == .line ? typicalBand(d, a) : nil)
            .frame(height: 260).padding(.top, selected == nil ? 22 : 8)
        if b == today {
            WBody(text: "ⓘ  El promedio no incluye el día de hoy (\(label(today)))", size: 13).padding(.top, 10)
        }
        if let title = m.breakdownTitle {
            breakdownCard(title, days, vals).padding(.top, 22)
        }
        VStack(alignment: .leading, spacing: 12) {
            Text(m.whatTitle).font(Theme.text(20)).foregroundColor(Theme.textPrimary)
            WBody(text: m.whatText, size: 15)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Theme.wCard).cornerRadius(14).padding(.top, 26)
    }

    private func sentence(_ avg: Double?, _ prev: Double?) -> String {
        let m = metric
        guard let av = avg else { return "Aún no hay días con datos de \(m.name.lowercased()) en este periodo." }
        let esto = shift > 0 ? "de este periodo" : ["de esta semana", "de este mes", "de estos 6 meses"][period]
        let antes = ["la semana anterior", "el mes anterior", "los 6 meses anteriores"][period]
        let name = m.kind == .weekSum ? "tiempo semanal en \(m.name.lowercased())" : m.name.lowercased()
        var s = "Tu \(name) promedio \(esto) (\(m.format(av)))"
        guard let pv = prev, pv > 0 else { return s + "." }
        let diff = (av - pv) / pv
        if abs(diff) < 0.03 {
            s += " fue consistente con tu promedio de \(antes) (\(m.format(pv)))."
        } else {
            s += " fue \(diff > 0 ? "superior" : "inferior") a tu promedio de \(antes) (\(m.format(pv)))."
            if let g = m.goodWhenHigh {
                s += (diff > 0) == g ? " Sigue así." : " Pequeños cambios cada día te ayudarán a mejorarlo."
            }
        }
        return s
    }

    private struct Point { let value: Double?; let top: String?; let bottom: String?; let title: String }

    /// Barras por día (S, M) o por semana (6 M; y M en los datos semanales).
    private func chartSeries(_ days: [String], _ vals: [Double?]) -> [Point] {
        let m = metric
        let weekly = period == 2 || (period == 1 && m.kind == .weekSum)
        if !weekly {
            return days.enumerated().map { (i, d) -> Point in
                let v = vals[i]
                if period == 0 {
                    return Point(value: v, top: wd[Day.weekdayIndex(d)], bottom: "\(Day.dayOfMonth(d))", title: WText.dateShort(d))
                }
                let show = (days.count - 1 - i) % 7 == 0
                return Point(value: v, top: show ? months[Day.month(d) - 1] : nil, bottom: show ? "\(Day.dayOfMonth(d))" : nil,
                             title: WText.dateShort(d))
            }
        }
        var out = [Point]()
        var i = 0
        var lastMonth = -1
        while i < days.count {
            let end = min(i + 7, days.count)
            let wk = Array(days[i..<end])
            let v = vals[i..<end].compactMap { $0 }
            var value: Double? = nil
            if !v.isEmpty { value = m.kind == .weekSum ? v.reduce(0, +) / Double(v.count) * 7 : v.reduce(0, +) / Double(v.count) }
            let mo = Day.month(wk[0])
            let top: String? = period == 2 ? (mo != lastMonth ? months[mo - 1] : nil) : months[mo - 1]
            out.append(Point(value: value, top: top, bottom: period == 2 ? nil : "\(Day.dayOfMonth(wk[0]))",
                             title: "Semana del \(label(wk[0]))"))
            lastMonth = mo
            i = end
        }
        return out
    }

    /// Rango típico (media ± 0,85 sd de los 30 días antes del periodo), como el Monitor de salud.
    private func typicalBand(_ d: HomeData, _ start: String) -> ClosedRange<Double>? {
        let from = Day.add(start, -30)
        let days = dayList(from, Day.add(start, -1))
        let v = dayValues(d, days).compactMap { $0 }
        guard v.count >= 5 else { return nil }
        let mean = v.reduce(0, +) / Double(v.count)
        let sd = sqrt(v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count - 1))
        return (mean - 0.85 * sd)...(mean + 0.85 * sd)
    }

    private func chart(_ pts: [Point], avg: Double?, band: ClosedRange<Double>?) -> some View {
        let m = metric
        let present = pts.compactMap { $0.value }
        var lo = m.style == .line ? (present.min() ?? 0) : 0
        var hi = present.max() ?? 1
        if let b = band { lo = min(lo, b.lowerBound); hi = max(hi, b.upperBound) }
        if m.style == .line { let pad = max((hi - lo) * 0.15, 1); lo -= pad; hi += pad } else { hi = max(hi * 1.15, 1) }
        let lo0 = lo, hi0 = hi
        let sel = selected
        let showLabels = period == 0
        return GeometryReader { g in
            let w = Double(g.size.width)
            let n = max(pts.count, 1)
            let left = 44.0, right = w - 4
            let slot = (right - left) / Double(n)
            Canvas { ctx, size in
                let h = Double(size.height)
                let top = 18.0, bottom = h - 36
                func Y(_ v: Double) -> Double { return bottom - (bottom - top) * (v - lo0) / max(hi0 - lo0, 1e-9) }
                for i in 0...4 {
                    let v = lo0 + (hi0 - lo0) * Double(i) / 4
                    let y = Y(v)
                    var gl = Path(); gl.move(to: CGPoint(x: left, y: y)); gl.addLine(to: CGPoint(x: right, y: y))
                    ctx.stroke(gl, with: .color(.white.opacity(0.10)), lineWidth: 1)
                    ctx.draw(Text(m.format(v)).font(Theme.label(11)).foregroundColor(Theme.textSecondary), at: CGPoint(x: 0, y: y), anchor: .leading)
                }
                if let b = band {
                    let r = CGRect(x: left, y: Y(b.upperBound), width: right - left, height: max(Y(b.lowerBound) - Y(b.upperBound), 2))
                    ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(.white.opacity(0.07)))
                    ctx.draw(Text("RANGO TÍPICO").font(Theme.label(10)).foregroundColor(Theme.textSecondary),
                             at: CGPoint(x: right, y: top - 10), anchor: .trailing)
                }
                let bw = min(slot * 0.66, 26)
                var line = Path()
                var started = false
                for (i, p) in pts.enumerated() {
                    let cx = left + slot * (Double(i) + 0.5)
                    if let t = p.top {
                        ctx.draw(Text(t).font(Theme.label(11.5)).foregroundColor(Theme.textSecondary), at: CGPoint(x: cx, y: bottom + 12), anchor: .center)
                    }
                    if let t = p.bottom {
                        ctx.draw(Text(t).font(Theme.label(11.5)).foregroundColor(Theme.textSecondary), at: CGPoint(x: cx, y: bottom + 26), anchor: .center)
                    }
                    guard let v = p.value else { started = false; continue }
                    let dim = sel != nil && sel != i
                    if m.style == .bars {
                        let y = Y(v)
                        let r = CGRect(x: cx - bw / 2, y: y, width: bw, height: max(bottom - y, 1))
                        ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(m.color(v).opacity(dim ? 0.35 : 1)))
                        if showLabels {
                            ctx.draw(Text(m.format(v)).font(Theme.label(11.5)).foregroundColor(Theme.textPrimary.opacity(dim ? 0.5 : 1)),
                                     at: CGPoint(x: cx, y: y - 8), anchor: .center)
                        }
                    } else {
                        let pt = CGPoint(x: cx, y: Y(v))
                        if started { line.addLine(to: pt) } else { line.move(to: pt); started = true }
                    }
                }
                if m.style == .line {
                    ctx.stroke(line, with: .color(Theme.strainBlue), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    for (i, p) in pts.enumerated() {
                        guard let v = p.value, pts.count <= 31 || i == pts.count - 1 || sel == i else { continue }
                        let cx = left + slot * (Double(i) + 0.5)
                        let r = sel == i ? 5.5 : 3.0
                        ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: Y(v) - r, width: 2 * r, height: 2 * r)), with: .color(.white))
                        if showLabels {
                            ctx.draw(Text(m.format(v)).font(Theme.label(11.5)).foregroundColor(Theme.textPrimary),
                                     at: CGPoint(x: cx, y: Y(v) - 12), anchor: .center)
                        }
                    }
                }
                if let a = avg, m.style == .bars {
                    let y = Y(a)
                    var dl = Path(); dl.move(to: CGPoint(x: left, y: y)); dl.addLine(to: CGPoint(x: right, y: y))
                    ctx.stroke(dl, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    let chip = CGRect(x: left - 2, y: y - 9, width: 38, height: 18)
                    ctx.fill(Path(roundedRect: chip, cornerRadius: 4), with: .color(.white))
                    ctx.draw(Text("PROM.").font(Theme.label(10)).foregroundColor(Color.black), at: CGPoint(x: chip.midX, y: y), anchor: .center)
                }
                if let i = sel, i < pts.count {
                    let cx = left + slot * (Double(i) + 0.5)
                    var vl = Path(); vl.move(to: CGPoint(x: cx, y: top)); vl.addLine(to: CGPoint(x: cx, y: bottom))
                    ctx.stroke(vl, with: .color(.white.opacity(0.5)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { loc in
                let i = Int((Double(loc.x) - left) / slot)
                if i >= 0 && i < pts.count { selected = (selected == i) ? nil : i }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 8)
                .onChanged { v in
                    if abs(v.translation.width) < abs(v.translation.height) { return }
                    let i = Int((Double(v.location.x) - left) / slot)
                    if i >= 0 && i < pts.count { selected = i }
                })
        }
    }

    private func breakdownCard(_ title: String, _ days: [String], _ vals: [Double?]) -> some View {
        let m = metric
        let today = Day.today()
        let v = zip(days, vals).filter { $0.0 != today }.compactMap { $0.1 }
        let counts = m.breakdown.map { b in v.filter { b.2($0) }.count }
        let total = max(counts.reduce(0, +), 1)
        return VStack(alignment: .leading, spacing: 10) {
            WTitle(text: title + " (días)", size: 12.5, color: Theme.textSecondary)
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(m.breakdown.indices, id: \.self) { i in
                        if counts[i] > 0 {
                            Rectangle().fill(m.breakdown[i].1)
                                .frame(width: max(Double(g.size.width) * Double(counts[i]) / Double(total) - 2, 2))
                        }
                    }
                }
            }
            .frame(height: 8).cornerRadius(2)
            ForEach(m.breakdown.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(m.breakdown[i].1).frame(width: 11, height: 11)
                    WNumber(text: "\(counts[i])x", size: 15).frame(width: 34, alignment: .leading)
                    Text(m.breakdown[i].0).font(Theme.text(14)).foregroundColor(Theme.textPrimary)
                }
            }
        }
    }
}
