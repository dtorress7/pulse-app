import SwiftUI

/* 9/11: Planificador de sueño como WHOOP (capturas del usuario): mensaje de la alarma, "Mañana quiero", hora sugerida para
   acostarse / hora de despertar, tiempo en cama (toca → "Tu recomendación de sueño"), alarma on/off, modo (hora exacta /
   objetivo de sueño / en verde), hora de despertar, "Mi horario" (calendario) y la pantalla "Guardando…" con el logo. */

private func hm(_ m: Int) -> String { return String(format: "%d:%02d", m / 60, abs(m) % 60) }
private func clock(_ m: Int) -> String { return Fmt.clock(minuteOfDay: ((m % 1440) + 1440) % 1440) }

struct SleepPlannerView: View {
    let basePlan: SleepAlarm.Plan?
    @ObservedObject private var mgr = WhoopManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tick = 0
    @State private var showGoal = false, showMode = false, showTime = false, showRec = false, showSchedule = false, showHelp = false

    private var plan: SleepAlarm.Plan? {
        _ = tick
        guard let b = basePlan else { return nil }
        let sp = SleepPlan(baselineMinutes: b.base, strainAdjustmentMinutes: b.strain, debtAdjustmentMinutes: b.debt,
                           napAdjustmentMinutes: b.nap, totalNeedMinutes: b.need, suggestedBedtime: nil)
        return SleepAlarm.plan(store: AppStore.shared, sleepPlan: sp)
    }
    private var alarmOn: Bool { _ = tick; return SleepAlarm.next().mode != SleepAlarm.modeNone }

    var body: some View {
        ZStack {
            Theme.wBgMid.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    header
                    message.padding(.top, 18)
                    goalButton.padding(.top, 24)
                    times.padding(.top, 30)
                    alarmPanel.padding(.top, 36)
                }
                .padding(.horizontal, 18).padding(.bottom, 40)
            }
            AlarmSavingOverlay()
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showGoal) { GoalSheet { tick += 1 } }
        .sheet(isPresented: $showMode) { ModeSheet(current: SleepAlarm.mode, allowNone: false) { m in
            SleepAlarm.mode = m; tick += 1; mgr.saveAlarmNow()
        } }
        .sheet(isPresented: $showTime) { WakeTimeSheet(minute: SleepPlanner.wakeMinute()) { m in
            SleepPlanner.setWakeMinute(m); HomeStore.shared.invalidate(); tick += 1; mgr.saveAlarmNow()
        } }
        .sheet(isPresented: $showRec) { if let p = plan { RecommendationSheet(plan: p) } }
        .sheet(isPresented: $showSchedule, onDismiss: { tick += 1; HomeStore.shared.invalidate() }) { ScheduleView() }
        .alert("Planificador de sueño", isPresented: $showHelp, actions: { Button("Cerrar", action: {}) }, message: {
            Text("Te dice a qué hora acostarte para dormir lo que necesitas esta noche (tu necesidad de sueño más el tiempo que sueles pasar despierto en la cama) y pone la alarma en la pulsera: vibra aunque el móvil esté lejos. Para pararla, da dos toques a la pulsera.")
        })
    }

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) { Image(systemName: "xmark").font(.system(size: 22, weight: .medium)).foregroundColor(Theme.textPrimary) }
            Spacer()
            HStack(spacing: 8) {
                WTitle(text: "Planificador de sueño", size: 16)
                Button(action: { showHelp = true }) { Image(systemName: "questionmark.circle").foregroundColor(Theme.textSecondary) }
            }
            Spacer()
            Button(action: { showSchedule = true }) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 22)).foregroundColor(Theme.textPrimary)
                    .frame(width: 46, height: 46).overlay(Circle().stroke(Color.white, lineWidth: 2))
            }
        }
        .padding(.top, 14)
    }

    private var message: some View {
        VStack(spacing: 14) {
            Image("LaunchLogo").resizable().scaledToFit().frame(width: 52, height: 52)
            if let p = plan {
                let pct = SleepAlarm.goal == 1 ? "85 %" : "100 %"
                Text(alarmOn ? "Tu alarma se activará a las \(clock(p.wakeMinute))\(p.mode == SleepAlarm.modeExact ? "" : " como muy tarde"). Acuéstate a las \(clock(p.bedMinute)) para obtener el \(pct) del sueño requerido."
                             : "Acuéstate a las \(clock(p.bedMinute)) para obtener el \(pct) del sueño requerido si te despiertas a las \(clock(p.wakeMinute)).")
                    .font(Theme.text(19, .medium)).foregroundColor(Theme.textPrimary).multilineTextAlignment(.center)
            } else {
                WBody(text: "Aún no hay datos de esta noche para calcular tu plan.", size: 16)
            }
        }
    }

    private var goalButton: some View {
        VStack(spacing: 10) {
            WTitle(text: "Mañana quiero", size: 12.5, color: Theme.textSecondary)
            Button(action: { showGoal = true }) {
                WTitle(text: SleepAlarm.goal == 1 ? "Mejorar mi sueño" : "Lograr mi sueño necesario", size: 14)
                    .padding(.horizontal, 22).frame(height: 46)
                    .overlay(Capsule().stroke(Color.white, lineWidth: 2))
            }
            .buttonStyle(.plain)
        }
    }

    private var times: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    WNumber(text: plan.map { clock($0.bedMinute) } ?? "--:--", size: 38)
                    WTitle(text: "Hora sugerida\npara acostarse", size: 12, color: Theme.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    WNumber(text: plan.map { clock($0.wakeMinute) } ?? "--:--", size: 38)
                    WTitle(text: "Tu hora\nde despertar", size: 12, color: Theme.textSecondary).multilineTextAlignment(.trailing)
                }
            }
            Button(action: { showRec = true }) {
                VStack(spacing: 8) {
                    WTitle(text: "Tiempo en cama", size: 12.5)
                    ZStack {
                        Rectangle().fill(Theme.wTrack).frame(height: 30)
                        Text(plan.map { hm($0.inBed) } ?? "--").font(Theme.number(22)).foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 18).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.wBgMid)).overlay(Capsule().stroke(Color.white, lineWidth: 2))
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var alarmPanel: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "applewatch.radiowaves.left.and.right").font(.system(size: 24)).foregroundColor(Theme.textPrimary)
                Spacer()
                WTitle(text: "Alarma", size: 16)
                Spacer()
                Toggle("", isOn: Binding(get: { WhoopSettings.alarmEnabled }, set: { v in
                    WhoopSettings.alarmEnabled = v; tick += 1; mgr.saveAlarmNow()
                })).labelsHidden().tint(Theme.recoveryGreen).disabled(SleepAlarm.scheduleOn)
            }
            if SleepAlarm.scheduleOn {
                WBody(text: "Tienes activado «Mi horario»: la alarma y la hora de cada día salen de ahí (icono del calendario).", size: 13)
            }
            HStack(spacing: 12) {
                panelButton("Alarma establecida en", SleepAlarm.modeName(SleepAlarm.mode)) { showMode = true }
                panelButton("Hora de despertar establecida en", clock(SleepPlanner.wakeMinute())) { showTime = true }
            }
            .opacity(SleepAlarm.scheduleOn ? 0.4 : 1).disabled(SleepAlarm.scheduleOn)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22).fill(Theme.wCard))
    }

    private func panelButton(_ title: String, _ value: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                WTitle(text: title, size: 11.5, color: Theme.textSecondary).multilineTextAlignment(.center)
                WTitle(text: value, size: 14)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.wRow))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.6), lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

/// "Guardando… Mantén tu WHOOP cerca mientras se guarda la alarma." con el logo de PulseApp, y luego "¡Correcto!".
struct AlarmSavingOverlay: View {
    @ObservedObject private var mgr = WhoopManager.shared
    var body: some View {
        Group {
            if mgr.alarmSave == 1 {
                ZStack {
                    Color.black.opacity(0.92).ignoresSafeArea()
                    VStack(spacing: 0) {
                        LoadingView(text: "GUARDANDO", background: .clear).frame(height: 320)
                        WBody(text: "Mantén tu WHOOP cerca mientras se guarda la alarma.", size: 15).multilineTextAlignment(.center)
                    }
                    .padding(30)
                }
            } else if mgr.alarmSave == 2 || mgr.alarmSave == 3 {
                ZStack {
                    Color.black.opacity(0.92).ignoresSafeArea()
                    VStack(spacing: 18) {
                        Image(systemName: mgr.alarmSave == 2 ? "checkmark" : "exclamationmark")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundColor(mgr.alarmSave == 2 ? Theme.recoveryGreen : Theme.alertAmber)
                            .frame(width: 120, height: 120)
                            .overlay(Circle().stroke(mgr.alarmSave == 2 ? Theme.recoveryGreen : Theme.alertAmber, lineWidth: 5))
                        WTitle(text: mgr.alarmSave == 2 ? "¡Correcto!" : "No se pudo guardar", size: 18)
                        WBody(text: mgr.alarmSave == 2 ? "Tu alarma se ha guardado." : "La pulsera no está conectada. Se guardará sola en cuanto se conecte.", size: 15)
                            .multilineTextAlignment(.center)
                    }
                    .padding(30)
                }
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if mgr.alarmSave != 1 { mgr.alarmSave = 0 } } }
                .onTapGesture { mgr.alarmSave = 0 }
            }
        }
    }
}

/// "Selecciona tu meta de sueño": lograr mi sueño necesario / mejorar mi sueño.
struct GoalSheet: View {
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var goal = SleepAlarm.goal
    var body: some View {
        VStack(spacing: 26) {
            WBody(text: "Selecciona tu meta de sueño.", size: 18, color: Theme.textPrimary).padding(.top, 24)
            ForEach([(1, "Mejorar mi sueño"), (0, "Lograr mi sueño necesario")], id: \.0) { g in
                Button(action: { goal = g.0 }) {
                    HStack(spacing: 18) {
                        ZStack {
                            Circle().stroke(Color.white, lineWidth: 2).frame(width: 40, height: 40)
                            if goal == g.0 {
                                Circle().fill(Color.white).frame(width: 40, height: 40)
                                Circle().fill(Color.black).frame(width: 12, height: 12)
                            }
                        }
                        WTitle(text: g.1, size: 15, color: goal == g.0 ? Theme.textPrimary : Theme.textSecondary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            WBody(text: "Lograr: el 100 % de tu necesidad de sueño. Mejorar: el 85 % (provisional, hasta saber la regla exacta de WHOOP).", size: 12.5)
            Spacer()
            Button(action: { SleepAlarm.goal = goal; HomeStore.shared.invalidate(); onSave(); dismiss() }) {
                WTitle(text: "Guardar", size: 16).frame(maxWidth: .infinity).frame(height: 60)
                    .overlay(Capsule().stroke(Color.white, lineWidth: 2))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 30).padding(.bottom, 20)
        .background(Theme.wBgMid.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

/// "Elige tu modo de alarma": hora exacta / objetivo de sueño / en verde (+ "No usar alarma" en el horario).
struct ModeSheet: View {
    let current: Int
    let allowNone: Bool
    let onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            WBody(text: "Elige tu modo de alarma.", size: 18, color: Theme.textPrimary).padding(.vertical, 18)
            option(SleepAlarm.modeExact, "Hora exacta", "Despierta a una hora específica.")
            option(SleepAlarm.modeGoal, "Objetivo de sueño", "Despierta cuando alcances tu meta de sueño.")
            option(SleepAlarm.modeGreen, "En verde", "Despierta una vez que hayas logrado una recuperación en el verde.")
            if allowNone {
                Button(action: { onPick(SleepAlarm.modeNone); dismiss() }) {
                    VStack(spacing: 6) {
                        HStack { WTitle(text: "No usar alarma", size: 14); Image(systemName: "arrow.right").foregroundColor(Theme.textPrimary) }
                        WBody(text: "Recibe recomendaciones sobre la hora de dormir y despertar sin que te despierte la alarma.", size: 13)
                            .multilineTextAlignment(.center)
                    }
                }
                .buttonStyle(.plain).padding(.top, 10)
            }
            WBody(text: "En los modos objetivo de sueño y en verde la pulsera vibra como muy tarde a tu hora de despertar; si antes (hasta 90 min) ya has cumplido la condición, el móvil la hace vibrar en ese momento.", size: 12)
                .padding(.top, 6)
            Spacer()
        }
        .padding(.horizontal, 24)
        .background(Theme.wBgMid.ignoresSafeArea())
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }

    private func option(_ m: Int, _ title: String, _ sub: String) -> some View {
        Button(action: { onPick(m); dismiss() }) {
            VStack(spacing: 6) {
                WTitle(text: title, size: 16)
                WBody(text: sub, size: 14).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(RoundedRectangle(cornerRadius: 6).fill(m == current ? Theme.wRow : Theme.wCard))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.6), lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

/// "Tu recomendación de sueño": necesidad (referencia, esfuerzo, deuda, siestas), meta, tiempo despierto y tiempo en cama.
struct RecommendationSheet: View {
    let plan: SleepAlarm.Plan
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WTitle(text: "Tu recomendación de sueño", size: 17, color: .black).padding(.top, 26)
            Text("El tiempo real del sueño recomendado para esta noche se calcula según tus necesidades personales de sueño y el tiempo que normalmente pasas despierto.")
                .font(Theme.text(15)).foregroundColor(Color.gray)
            VStack(spacing: 0) {
                row("Necesidad de sueño", hm(plan.need), bold: true)
                dashed
                row("Referencia", hm(plan.base))
                row("Esfuerzo reciente", "+" + hm(plan.strain))
                row("Deuda de sueño", "+" + hm(plan.debt))
                row("Siestas recientes", "-" + hm(abs(plan.nap)))
                dashed
                row("Meta de sueño \(SleepAlarm.goal == 1 ? "85" : "100") %", hm(plan.goal), bold: true)
                row("Tiempo promedio despierto", "+" + hm(plan.awake), bold: true)
                Rectangle().fill(Color.black).frame(height: 2).padding(.vertical, 6)
                HStack {
                    WTitle(text: "Tiempo en cama\nrecomendado", size: 14, color: .black)
                    Spacer()
                    Text(hm(plan.inBed)).font(Theme.number(32)).foregroundColor(.black)
                }
                .padding(.vertical, 6)
            }
            .padding(16)
            .background(Color(hex: 0xD9F7EE))
            Spacer()
        }
        .padding(.horizontal, 24)
        .background(Color.white.ignoresSafeArea())
        .presentationDetents([.large])
        .preferredColorScheme(.light)
    }
    private var dashed: some View {
        Line().stroke(Color.gray, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1).padding(.vertical, 6)
    }
    private func row(_ k: String, _ v: String, bold: Bool = false) -> some View {
        HStack {
            WTitle(text: k, size: 13.5, color: bold ? .black : .gray)
            Spacer()
            Text(v).font(Theme.number(16)).foregroundColor(bold ? .black : .gray)
        }
        .padding(.vertical, 6).padding(.leading, bold ? 0 : 10)
    }
}

/// "Mi horario": interruptor + días con su hora y modo de alarma (editar / eliminar / añadir).
struct ScheduleView: View {
    @ObservedObject private var mgr = WhoopManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var on = SleepAlarm.scheduleOn
    @State private var entries = SleepAlarm.schedule
    @State private var editing: Int? = nil
    @State private var expanded: Int? = nil

    var body: some View {
        ZStack {
            Theme.wBgMid.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        Button(action: { dismiss() }) { Image(systemName: "chevron.left").font(.system(size: 22, weight: .medium)).foregroundColor(Theme.textPrimary) }
                        Spacer()
                        WTitle(text: "Mi horario", size: 16)
                        Spacer()
                        Toggle("", isOn: Binding(get: { on }, set: { v in on = v; SleepAlarm.scheduleOn = v; mgr.saveAlarmNow() }))
                            .labelsHidden().tint(Theme.recoveryGreen)
                    }
                    .padding(.top, 14)
                    if !on {
                        Text("Tu horario está desactivado y el planificador de sueño no lo utilizará para alarmas.")
                            .font(Theme.text(16, .medium)).foregroundColor(Theme.textPrimary).multilineTextAlignment(.center).padding(.vertical, 8)
                    }
                    ForEach(entries.indices, id: \.self) { i in entryCard(i).opacity(on ? 1 : 0.45) }
                    let used = entries.reduce(0) { $0 | $1.days }
                    if used != 0b1111111 {
                        Button(action: { entries.append(SleepAlarm.Entry(days: 0b1111111 & ~used, minute: SleepPlanner.wakeMinute(), mode: SleepAlarm.modeExact)); editing = entries.count - 1 }) {
                            HStack { Image(systemName: "plus"); WTitle(text: "Añadir días", size: 14) }.foregroundColor(Theme.textPrimary)
                                .frame(maxWidth: .infinity).frame(height: 50).background(RoundedRectangle(cornerRadius: 10).fill(Theme.wCard))
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.recoveryGreen); WBody(text: "Tu agenda está completa", size: 15, color: Theme.recoveryGreen) }
                            .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 40)
            }
            AlarmSavingOverlay()
        }
        .preferredColorScheme(.dark)
        .sheet(item: Binding(get: { editing.map { EditIdx(i: $0) } }, set: { editing = $0?.i })) { e in
            EntryEditor(entry: entries[e.i], otherDays: entries.enumerated().filter { $0.offset != e.i }.reduce(0) { $0 | $1.element.days }) { new in
                entries[e.i] = new
                entries.removeAll { $0.days == 0 }
                SleepAlarm.schedule = entries
                if on { mgr.saveAlarmNow() }
            }
        }
    }

    private struct EditIdx: Identifiable { let i: Int; var id: Int { i } }

    private func entryCard(_ i: Int) -> some View {
        let e = entries[i]
        return VStack(alignment: .leading, spacing: 10) {
            Button(action: { expanded = expanded == i ? nil : i }) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        WTitle(text: SleepAlarm.dayNames(e.days), size: 12.5, color: Theme.textSecondary)
                        WNumber(text: clock(e.minute), size: 34)
                        HStack(spacing: 6) {
                            Image(systemName: "applewatch.radiowaves.left.and.right").font(.system(size: 12))
                            WTitle(text: SleepAlarm.modeName(e.mode), size: 11.5)
                        }
                        .foregroundColor(e.mode == SleepAlarm.modeNone ? Theme.textSecondary : Theme.recoveryGreen)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.wRow))
                    }
                    Spacer()
                    Image(systemName: expanded == i ? "chevron.up" : "chevron.down").foregroundColor(Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            if expanded == i {
                HStack {
                    Button(action: { editing = i }) { HStack { Image(systemName: "pencil"); WTitle(text: "Editar", size: 13) } }
                    Spacer()
                    Button(action: {
                        entries.remove(at: i); expanded = nil; SleepAlarm.schedule = entries
                        if on { mgr.saveAlarmNow() }
                    }) { HStack { Image(systemName: "trash"); WTitle(text: "Eliminar", size: 13) } }
                }
                .foregroundColor(Theme.textPrimary).buttonStyle(.plain).padding(.top, 6)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.wCard))
    }
}

/// Editar un tramo del horario en 3 pasos como WHOOP: días → modo de alarma → hora de despertar.
struct EntryEditor: View {
    @State var entry: SleepAlarm.Entry
    let otherDays: Int
    let onSave: (SleepAlarm.Entry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var time = Date()

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Button(action: { if step == 0 { dismiss() } else { step -= 1 } }) { Image(systemName: "chevron.left").foregroundColor(Theme.textPrimary) }
                Spacer()
                WTitle(text: step == 0 ? "Selecciona días con horas\nde despertar repetidas" : step == 1 ? "Elegir modo de alarma" : "Establece tu hora de despertar", size: 15)
                    .multilineTextAlignment(.center)
                Spacer()
                Color.clear.frame(width: 20)
            }
            .padding(.top, 22)
            if step == 0 { days } else if step == 1 { modes } else { picker }
            Spacer()
            if step != 1 {
                Button(action: next) {
                    WTitle(text: step == 2 ? "Guardar" : "Siguiente", size: 16).frame(maxWidth: .infinity).frame(height: 60)
                        .overlay(Capsule().stroke(Color.white, lineWidth: 2))
                }
                .buttonStyle(.plain).disabled(entry.days == 0).opacity(entry.days == 0 ? 0.4 : 1)
            }
        }
        .padding(.horizontal, 26).padding(.bottom, 20)
        .background(Theme.wBgMid.ignoresSafeArea())
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
        .onAppear { time = Calendar.current.date(bySettingHour: entry.minute / 60, minute: entry.minute % 60, second: 0, of: Date()) ?? Date() }
    }

    private func next() {
        if step == 2 {
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            entry.minute = (c.hour ?? 7) * 60 + (c.minute ?? 30)
            onSave(entry); dismiss()
        } else { step += 1 }
    }

    private var days: some View {
        VStack(spacing: 18) {
            Image("LaunchLogo").resizable().scaledToFit().frame(width: 52, height: 52)
            WBody(text: "Un horario de sueño constante puede ayudar a mejorar tu Calificación del Sueño", size: 15).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { d in
                    let taken = otherDays & (1 << d) != 0
                    let sel = entry.days & (1 << d) != 0
                    Button(action: { if !taken { entry.days ^= (1 << d) } }) {
                        VStack(spacing: 4) {
                            Text(["L", "M", "X", "J", "V", "S", "D"][d]).font(Theme.number(20))
                                .foregroundColor(sel ? .black : Theme.textSecondary)
                                .frame(width: 42, height: 46)
                                .background(RoundedRectangle(cornerRadius: 4).fill(sel ? Color.white : Theme.wRow))
                            Circle().fill(taken ? Theme.textSecondary : Color.clear).frame(width: 5, height: 5)
                        }
                    }
                    .buttonStyle(.plain).disabled(taken)
                }
            }
        }
    }

    private var modes: some View {
        ModeSheetInline(current: entry.mode) { m in entry.mode = m; step = 2 }
    }

    private var picker: some View {
        DatePicker("", selection: $time, displayedComponents: [.hourAndMinute]).datePickerStyle(.wheel).labelsHidden()
    }
}

/// Los modos de alarma dentro del editor del horario (incluye "No usar alarma").
struct ModeSheetInline: View {
    let current: Int
    let onPick: (Int) -> Void
    var body: some View {
        VStack(spacing: 12) {
            ForEach([(SleepAlarm.modeExact, "Hora exacta", "Despierta a una hora específica."),
                     (SleepAlarm.modeGoal, "Meta de sueño", "Despierta cuando alcances tu meta de sueño."),
                     (SleepAlarm.modeGreen, "En verde", "Despierta cuando alcances una recuperación en el verde.")], id: \.0) { o in
                Button(action: { onPick(o.0) }) {
                    VStack(spacing: 6) { WTitle(text: o.1, size: 16); WBody(text: o.2, size: 14).multilineTextAlignment(.center) }
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .background(RoundedRectangle(cornerRadius: 10).fill(o.0 == current ? Theme.wRow : Theme.wCard))
                }
                .buttonStyle(.plain)
            }
            Button(action: { onPick(SleepAlarm.modeNone) }) {
                VStack(spacing: 6) {
                    HStack { WTitle(text: "No usar alarma", size: 14); Image(systemName: "arrow.right") }.foregroundColor(Theme.textPrimary)
                    WBody(text: "Recibe recomendaciones sobre la hora de dormir y despertar sin que te despierte la alarma.", size: 13)
                        .multilineTextAlignment(.center)
                }
            }
            .buttonStyle(.plain).padding(.top, 8)
        }
    }
}
