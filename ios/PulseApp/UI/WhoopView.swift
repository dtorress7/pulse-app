import Foundation
import SwiftUI

/// Conexión con la WHOOP, modos experimentales, exportación y registro.
struct WhoopView: View {
    @StateObject private var mgr = WhoopManager.shared
    @State private var imu = WhoopSettings.imuEnabled
    @State private var imuSaver = WhoopSettings.imuSaver
    @State private var ack = WhoopSettings.ackMode
    @State private var logLines = ServiceLog.shared.snapshot(150)
    @State private var showClear = false
    @State private var testTick = 0
    @State private var alarm = WhoopSettings.alarmEnabled

    var body: some View {
        NavigationStack {
            Screen("WHOOP") {
                connectionCard
                alarmCard
                modesCard
                dataCard
                exportCard
                logCard
            }
            .navigationTitle("WHOOP")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { logLines = ServiceLog.shared.snapshot(150) }
            .onChange(of: mgr.logVersion) { _ in logLines = ServiceLog.shared.snapshot(150) }
        }
    }

    private var connectionCard: some View {
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CapsLabel(text: "Conexión")
                Text(mgr.state).font(Theme.text(16, .semibold)).foregroundColor(Theme.textPrimary)
                if let n = mgr.deviceName { Text(n).font(Theme.text(12)).foregroundColor(Theme.textSecondary) }
                HStack(spacing: 10) {
                    action(mgr.isRunning ? "Reconectar" : "Conectar", Theme.recoveryGreen) { mgr.start() }
                    action("Buscar", Theme.strainBlue) { mgr.scanForWhoop() }
                    action("Desconectar", Theme.track) { mgr.disconnect() }
                }
                action("Pedir historial ahora", Theme.cardElevated) { mgr.requestHistoryNow() }
                Text("En iPhone la pulsera se empareja con el sistema: si ya la usas con la app de WHOOP, PulseApp intentará engancharse a esa conexión. Si no aparece, apaga el Bluetooth del otro móvil y pulsa Buscar.")
                    .font(Theme.text(11)).foregroundColor(Theme.textSecondary)
            }
        }
    }

    private func action(_ title: String, _ color: Color, _ run: @escaping () -> Void) -> some View {
        return Button(action: run) {
            Text(title).font(Theme.label(15))
                .foregroundColor(color == Theme.recoveryGreen || color == Theme.strainBlue ? Theme.onAccent : Theme.textPrimary)
                .frame(maxWidth: Double.infinity).padding(.vertical, 10)
                .background(color).cornerRadius(10)
        }
    }

    /// 9/11: despertador con vibración de la propia pulsera (como WHOOP).
    private var alarmCard: some View {
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                CapsLabel(text: "Alarma")
                Toggle(isOn: Binding(get: { alarm }, set: { v in
                    alarm = v; WhoopSettings.alarmEnabled = v; mgr.applyAlarm(force: true)
                })) {
                    Text("Despertador con vibración").font(Theme.text(15)).foregroundColor(Theme.textPrimary)
                }
                Text(alarm ? "La pulsera vibrará a las \(Fmt.clock(minuteOfDay: SleepPlanner.wakeMinute())) (la hora de despertar de «El sueño de esta noche», en Inicio). La alarma se guarda en la pulsera: suena aunque el móvil esté lejos. Si también tienes la alarma de la app de WHOOP, la última que se ponga sustituye a la otra."
                     : "Usa la hora de despertar de «El sueño de esta noche» (Inicio). Pruébala primero con el botón de abajo.")
                    .font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                Button(action: { mgr.testBuzz() }) {
                    Text("Probar vibración").font(Theme.label(14)).foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: Double.infinity).padding(.vertical, 9).background(Theme.track).cornerRadius(10)
                }
            }
        }
    }

    private var modesCard: some View {
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                CapsLabel(text: "Modos experimentales")
                Toggle(isOn: Binding(get: { imu }, set: { imu = $0; mgr.setImu($0) })) {
                    Text("Movimiento y pasos").font(Theme.text(15)).foregroundColor(Theme.textPrimary)
                }
                Text("Activa el acelerómetro (más batería de la pulsera). Necesario para las fases del sueño y los pasos.")
                    .font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                Toggle(isOn: Binding(get: { imuSaver }, set: { v in
                    imuSaver = v; WhoopSettings.imuSaver = v; mgr.applyImuSchedule(force: true)
                })) {
                    Text("Ahorro de batería (movimiento solo de 20:00 a 12:00)").font(Theme.text(15)).foregroundColor(Theme.textPrimary)
                }
                Text("El movimiento gasta 1,5–2× la batería de la pulsera. Con el ahorro solo se graba lo que necesita el sueño; de día los pasos salen del contador de la pulsera, pero no se detectan siestas ni paseos. Cuánto baja la batería se guarda en band_battery.csv.")
                    .font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                Hairline()
                let recording = ImuTestRecorder.isRecording && testTick >= 0
                Button(action: {
                    if recording { ImuTestRecorder.stop() } else { ImuTestRecorder.start(minutes: 20) }
                    testTick += 1
                }) {
                    Text(recording ? "Grabando prueba de pasos… hasta las \(Fmt.clock(ImuTestRecorder.untilMillis)) (tocar para parar)"
                                   : "Grabar prueba de pasos (20 min)")
                        .font(Theme.label(14)).foregroundColor(recording ? Theme.onAccent : Theme.textPrimary)
                        .frame(maxWidth: Double.infinity).padding(.vertical, 9)
                        .background(recording ? Theme.alertAmber : Theme.track).cornerRadius(10)
                }
                Text("Guarda el acelerómetro crudo en imu_prueba.csv (necesita «Movimiento y pasos» activado). Después mándalo desde Exportar.")
                    .font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                Hairline()
                Text(WhoopSettings.ackLabel(ack)).font(Theme.text(14)).foregroundColor(Theme.textPrimary)
                HStack(spacing: 8) {
                    ackButton(0, "WHOOP guarda")
                    ackButton(1, "PulseApp descarga")
                }
                Text("«PulseApp descarga» confirma cada bloque: la pulsera los borra y la app oficial de WHOOP ya no los verá.")
                    .font(Theme.text(11)).foregroundColor(Theme.textSecondary)
            }
        }
    }

    private func ackButton(_ mode: Int, _ title: String) -> some View {
        let on = ack == mode
        return Button(action: { ack = mode; mgr.setAckMode(mode) }) {
            Text(title).font(Theme.label(14)).foregroundColor(on ? Theme.onAccent : Theme.textPrimary)
                .frame(maxWidth: Double.infinity).padding(.vertical, 9)
                .background(on ? Theme.recoveryGreen : Theme.track).cornerRadius(10)
        }
    }

    private var dataCard: some View {
        return Card(padding: 0) {
            VStack(spacing: 0) {
                ListRow(title: "Lecturas en directo", value: "\(mgr.liveCount)")
                Hairline()
                ListRow(title: "Del historial", value: "\(mgr.historyCount)")
                Hairline()
                ListRow(title: "Pasos hoy", value: Fmt.thousands(Int64(mgr.stepsToday)))
                ListRow(title: "Batería de la pulsera", value: BandBattery.percent.map { "\($0) %" + (BandBattery.isCharging ? " · cargando" : "") } ?? "—")
                Hairline()
                ListRow(title: "Tamaño del registro de pulso", value: "\(mgr.hrLog.fileSize() / 1024) KB")
            }
        }
    }

    private var exportCard: some View {
        let names = [AppPaths.hrLog, AppPaths.motion, ImuTestRecorder.fileName, AppPaths.historyRaw, AppPaths.bioLog, AppPaths.serviceLog, BandSteps.fileName, BandBattery.historyFile,
                     "strength_logs.tsv", "strength_templates.tsv"]
        let existing = names.filter { FileManager.default.fileExists(atPath: AppPaths.file($0).path) }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CapsLabel(text: "Exportar")
                Text("Los archivos también están en la app Archivos → En mi iPhone → PulseApp.")
                    .font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                if existing.isEmpty {
                    EmptyNote(text: "Aún no hay archivos.")
                } else {
                    ForEach(0..<existing.count) { i in
                        ShareLink(item: AppPaths.file(existing[i])) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text(existing[i]).font(Theme.text(14))
                                Spacer()
                            }
                            .foregroundColor(Theme.strainBlue)
                        }
                    }
                }
            }
        }
    }

    private var logCard: some View {
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CapsLabel(text: "Registro")
                if logLines.isEmpty {
                    EmptyNote(text: "Sin mensajes todavía.")
                } else {
                    ForEach(0..<logLines.count) { i in
                        Text(logLines[logLines.count - 1 - i]).font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                    }
                }
            }
        }
    }
}
