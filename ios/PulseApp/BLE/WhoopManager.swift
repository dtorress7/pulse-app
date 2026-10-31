import Foundation
import CoreBluetooth
import Combine
import UIKit

/// CONEXIÓN PRINCIPAL CON LA WHOOP en iOS (equivale a WhoopBackgroundService de Android):
///  - Sigue conectada con la app en segundo plano (modo "bluetooth-central") y se reengancha sola: `connect` de
///    CoreBluetooth no caduca nunca (como el autoConnect de Android) y hay restauración de estado si iOS cierra la app.
///  - Al conectar: suscripciones → HELLO → poner en hora → pulso en directo → pide el historial de la pulsera.
///  - Todo el pulso (en directo o del historial) va a hr_log.csv con su hora real.
///  - En iOS el emparejamiento es del SISTEMA: si ya tienes la WHOOP emparejada con este iPhone (la app de WHOOP),
///    PulseApp se conecta por encima sin vincular otra vez. Si no, la primera orden provoca el aviso de emparejar.
final class WhoopManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    static let shared = WhoopManager()

    static let whoopService = CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a")
    static let cmdCharacteristic = CBUUID(string: "fd4b0002-cce1-4033-93ce-002d5875f58a")
    static let notifyCharacteristics: [CBUUID] = [
        CBUUID(string: "fd4b0003-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0004-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0005-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0007-cce1-4033-93ce-002d5875f58a")
    ]
    static let hrService = CBUUID(string: "180D")
    static let hrMeasurement = CBUUID(string: "2A37")
    private static let restoreId = "com.pulseapp.ios.central"
    private static let offloadEvery: TimeInterval = 15 * 60

    // Estado que ven las pantallas
    @Published var state = "Desconectado"
    @Published var isRunning = false
    @Published var lastBpm: Int? = nil
    @Published var lastBpmTime: Int64 = 0
    @Published var liveCount = 0
    @Published var historyCount = 0
    @Published var deviceName: String? = nil
    @Published var logVersion = 0
    @Published var scanning = false

    let store = AppStore.shared
    let hrLog = HrLog(url: AppPaths.file(AppPaths.hrLog))
    private(set) var handler: WhoopFrameHandler!

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var seq = 0
    private var ready = false
    private var stopping = false
    private var wantsStart = false
    private var hrMax = 190.0
    private var lastOffloadRequest = Date.distantPast
    private var offloadedThisConnection = false
    private var characteristicsPending = 0
    private var setupStarted = false
    // Vigilancia (31/10): la noche 30→31 la app se quedó en "Conectada, preparando…" sin medir hasta reconectar a mano
    private var setupStartedAt = Date.distantPast
    private var setupWatch: DispatchWorkItem?
    private var lastRxAt = Date.distantPast
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private static let setupTimeout: TimeInterval = 15
    private static let silenceLimit: TimeInterval = 120

    private enum Op {
        case subscribe(CBCharacteristic)
        case write([UInt8], String)
        case delay(TimeInterval)
    }
    private var queue = [Op]()
    private var busy = false
    private var timeoutWork: DispatchWorkItem?
    private var offloadIdleWork: DispatchWorkItem?

    private override init() {
        super.init()
        let hrLog = self.hrLog
        DispatchQueue.global(qos: .utility).async { if hrLog.repairDstOnce() { HomeStore.shared.invalidate() } }   // una vez: la hora repetida del 25/10
        let store = self.store
        let motion = MotionTracker(outFile: AppPaths.file(AppPaths.motion))
        let processor = LiveHrProcessor(store: store, hrLog: hrLog, onActivitySaved: { msg in
            DispatchQueue.main.async { ServiceLog.shared.log("🏃 " + msg) }
        })
        handler = WhoopFrameHandler(
            hrLog: hrLog, bio: WhoopBioStore(url: AppPaths.file(AppPaths.bioLog)),
            raw: BufferedAppender(url: AppPaths.file(AppPaths.historyRaw), maxBytes: 40_000_000),
            motion: motion, processor: processor,
            sendCommand: { [weak self] cmd, payload, label in self?.command(cmd, payload, label) },
            log: { msg in ServiceLog.shared.log(msg) },
            ackMode: { WhoopSettings.ackMode },
            hrMax: { [weak self] in self?.hrMax ?? 190.0 })
        handler.onChange = { [weak self] in self?.pushLive() }
        handler.onOffloadActivity = { [weak self] in self?.armOffloadIdle() }
        ServiceLog.shared.onUpdate = { [weak self] in
            DispatchQueue.main.async { self?.logVersion += 1 }
        }
        refreshHrMax()
        central = CBCentralManager(delegate: self, queue: DispatchQueue.main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: WhoopManager.restoreId,
                                             CBCentralManagerOptionShowPowerAlertKey: true])
    }

    /// FC máxima según el perfil (para la detección automática de actividades).
    func refreshHrMax() {
        let age = store.getProfile()?.ageYears() ?? 30
        hrMax = Formulas.hrMax(ageYears: age)
    }

    // ---------- Acciones de la pantalla ----------

    /// Conectar ahora (y mantener la conexión). Si no se conoce la pulsera, la busca.
    func start() {
        stopping = false
        wantsStart = true
        WhoopSettings.autoConnect = true
        isRunning = true
        connectToKnownOrScan()
    }

    /// Buscar una WHOOP cercana (también la que ya está conectada al iPhone por la app de WHOOP).
    func scanForWhoop() {
        stopping = false
        wantsStart = true
        isRunning = true
        guard central.state == .poweredOn else { setState("Bluetooth apagado o sin permiso"); return }
        // 1) ¿Ya está conectada al iPhone (app de WHOOP)? Entonces no hace falta buscarla.
        let connected = central.retrieveConnectedPeripherals(withServices: [WhoopManager.whoopService, WhoopManager.hrService])
        if let p = connected.first(where: { ($0.name ?? "").lowercased().contains("whoop") }) ?? connected.first {
            ServiceLog.shared.log("Encontrada ya conectada al iPhone: \(p.name ?? "WHOOP")")
            adopt(p)
            return
        }
        ServiceLog.shared.log("🔎 Buscando tu WHOOP… (acércala; si estuviera conectada a otro móvil, apaga su Bluetooth)")
        scanning = true
        setState("Buscando la pulsera…")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.scanning else { return }
            self.central.stopScan()
            self.scanning = false
            if self.peripheral == nil {
                ServiceLog.shared.log("No se encontró ninguna WHOOP en 15 s. Toca la pulsera hasta la luz azul y repite.")
                self.setState("No encontrada")
            }
        }
    }

    func disconnect() {
        stopping = true
        wantsStart = false
        WhoopSettings.autoConnect = false
        ServiceLog.shared.log("⏹️ Desconectado a petición tuya")
        if scanning { central.stopScan(); scanning = false }
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        resetLink()
        isRunning = false
        setState("Desconectado")
        handler.flush()
    }

    func requestHistoryNow() {
        if ready { requestHistory(force: true) } else {
            ServiceLog.shared.log("⚠️ Aún no está conectada, lo pediré al conectar")
            start()
        }
    }

    func setImu(_ on: Bool) {
        WhoopSettings.imuEnabled = on
        if on {
            if ready { startImu() } else { start() }
        } else {
            if ready { stopImu() } else { ServiceLog.shared.log("🚶 Movimiento desactivado: se aplicará al conectar") }
            handler.motion.flush()
        }
    }

    func setAckMode(_ mode: Int) {
        WhoopSettings.ackMode = mode
        ServiceLog.shared.log(mode == 1 ? "⚙️ Modo historial: PulseApp descarga todo" : "⚙️ Modo historial: WHOOP conserva los datos")
        if mode == 1 && ready { requestHistory(force: true) }
        objectWillChange.send()
    }

    // ---------- Conexión ----------

    private func connectToKnownOrScan() {
        guard central.state == .poweredOn else {
            setState(central.state == .unauthorized ? "Sin permiso de Bluetooth (Ajustes → PulseApp)" : "Bluetooth apagado")
            return
        }
        if let existing = peripheral {
            connect(existing)
            return
        }
        if let id = WhoopSettings.deviceId, let uuid = UUID(uuidString: id),
           let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            adopt(p)
            return
        }
        scanForWhoop()
    }

    private func adopt(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        WhoopSettings.deviceId = p.identifier.uuidString
        deviceName = p.name
        connect(p)
    }

    private func connect(_ p: CBPeripheral) {
        p.delegate = self
        if p.state == .connected {
            ServiceLog.shared.log("Ya estaba conectada, preparando canal…")
            beginSetup(p)
            return
        }
        ServiceLog.shared.log("🔗 Conectando con \(p.name ?? "la pulsera") (se reconectará sola si se aleja)…")
        setState("Buscando la pulsera…")
        // connect no caduca: iOS la reengancha en cuanto vuelve a estar a tiro, aunque tarde horas
        central.connect(p, options: nil)
    }

    private func resetLink() {
        ready = false
        setupStarted = false
        setupWatch?.cancel()
        endBgTask()
        cmdChar = nil
        queue.removeAll()
        busy = false
        timeoutWork?.cancel()
        offloadIdleWork?.cancel()
        handler.resetConnection()
    }

    // ---------- CBCentralManagerDelegate ----------

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            if WhoopSettings.autoConnect && !stopping {
                ServiceLog.shared.log("📶 Bluetooth listo: conectando")
                isRunning = true
                connectToKnownOrScan()
            } else if wantsStart {
                connectToKnownOrScan()
            } else {
                setState("Desconectado")
            }
        case .poweredOff:
            resetLink()
            ServiceLog.shared.log("📴 Bluetooth del iPhone apagado")
            setState("Bluetooth apagado")
        case .unauthorized:
            setState("Sin permiso de Bluetooth (Ajustes → PulseApp)")
        default:
            break
        }
    }

    /// iOS cerró la app y la reabre para entregar un evento de la pulsera: se recupera la conexión.
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let list = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = list.first {
            peripheral = p
            p.delegate = self
            deviceName = p.name
            isRunning = true
            stopping = false
            ServiceLog.shared.log("♻️ iOS ha reabierto PulseApp: recupero la conexión con la pulsera")
            // 31/10: aquí el Bluetooth aún NO está listo (iOS llama a esto antes de centralManagerDidUpdateState) y las órdenes se
            // ignoran: antes se llamaba a beginSetup, la preparación se quedaba a medias y la app ya no lo reintentaba en toda la
            // noche ("Conectada, preparando…"). Ahora se prepara al recibir .poweredOn (connectToKnownOrScan).
            setupStarted = false
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        if !name.lowercased().contains("whoop") { return }
        c.stopScan()
        scanning = false
        ServiceLog.shared.log("Encontrada: \(name). Conectando…")
        adopt(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        ServiceLog.shared.log("✅ Conectada. Preparando canal…")
        setState("Conectada, preparando…")
        beginSetup(p)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        ServiceLog.shared.log("❌ No se pudo conectar: \(error?.localizedDescription ?? "sin detalle"). Reintento…")
        if !stopping {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self = self, !self.stopping else { return }
                self.central.connect(p, options: nil)
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        resetLink()
        handler.flush()
        if stopping { return }
        ServiceLog.shared.log("📴 Desconectada. Me reengancho sola cuando vuelva a estar cerca.")
        setState("Fuera de alcance — reconectará sola")
        // Una conexión pendiente no caduca: iOS la completa cuando la pulsera vuelva
        c.connect(p, options: nil)
    }

    // ---------- Preparación del canal ----------

    private func beginSetup(_ p: CBPeripheral) {
        guard central.state == .poweredOn else {
            ServiceLog.shared.log("⏳ Bluetooth aún no listo: preparo el canal en cuanto lo esté")
            return
        }
        if setupStarted {
            // Si una preparación anterior se quedó colgada, no se bloquea para siempre
            if !ready && Date().timeIntervalSince(setupStartedAt) > WhoopManager.setupTimeout { restartLink(p, "la preparación anterior no terminó") }
            return
        }
        setupStarted = true
        setupStartedAt = Date()
        queue.removeAll(); busy = false
        beginBgTask()
        // Vigilancia: si en 15 s no está midiendo, se corta y se vuelve a conectar (lo mismo que desconectar y conectar a mano)
        setupWatch?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, !self.stopping, !self.ready, let p = self.peripheral else { return }
            self.restartLink(p, "la preparación no terminó en \(Int(WhoopManager.setupTimeout)) s")
        }
        setupWatch = w
        DispatchQueue.main.asyncAfter(deadline: .now() + WhoopManager.setupTimeout, execute: w)
        p.discoverServices([WhoopManager.whoopService, WhoopManager.hrService])
    }

    /// Corta la conexión de PulseApp con la pulsera y la vuelve a pedir (la app de WHOOP no se ve afectada).
    private func restartLink(_ p: CBPeripheral, _ reason: String) {
        if stopping { return }
        ServiceLog.shared.log("🔄 Reconectando sola: \(reason)")
        resetLink()
        setState("Reconectando…")
        central.cancelPeripheralConnection(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, !self.stopping, self.central.state == .poweredOn else { return }
            if p.state == .connected { self.beginSetup(p) } else { self.central.connect(p, options: nil) }
        }
    }

    /// Al abrir la app: si debería estar midiendo y no lo está (o lleva 2 min sin recibir nada), se arregla sola.
    func ensureAlive() {
        guard WhoopSettings.autoConnect, !stopping, central.state == .poweredOn else { return }
        guard let p = peripheral else { connectToKnownOrScan(); return }
        if !ready {
            if !setupStarted || Date().timeIntervalSince(setupStartedAt) > WhoopManager.setupTimeout {
                if p.state == .connected { restartLink(p, "al abrir la app no estaba midiendo") } else { connectToKnownOrScan() }
            }
        } else if Date().timeIntervalSince(lastRxAt) > WhoopManager.silenceLimit {
            restartLink(p, "llevaba más de 2 min sin recibir datos de la pulsera")
        }
    }

    private func beginBgTask() {
        endBgTask()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "whoop-setup") { [weak self] in self?.endBgTask() }
    }

    private func endBgTask() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = p.services, services.contains(where: { $0.uuid == WhoopManager.whoopService }) else {
            ServiceLog.shared.log("❌ La pulsera no muestra el servicio WHOOP (\(error?.localizedDescription ?? "sin error"))")
            restartLink(p, "no aparecieron los servicios")
            return
        }
        characteristicsPending = services.count
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        characteristicsPending -= 1
        if characteristicsPending > 0 { return }
        finishSetup(p)
    }

    private func finishSetup(_ p: CBPeripheral) {
        guard let whoop = p.services?.first(where: { $0.uuid == WhoopManager.whoopService }) else { return }
        cmdChar = whoop.characteristics?.first(where: { $0.uuid == WhoopManager.cmdCharacteristic })
        ServiceLog.shared.log("Servicios listos. Suscribiéndome de uno en uno…")
        for u in WhoopManager.notifyCharacteristics {
            if let c = whoop.characteristics?.first(where: { $0.uuid == u }) { enqueue(.subscribe(c)) }
        }
        if let hr = p.services?.first(where: { $0.uuid == WhoopManager.hrService }),
           let c = hr.characteristics?.first(where: { $0.uuid == WhoopManager.hrMeasurement }) {
            ServiceLog.shared.log("La pulsera también ofrece el pulso estándar: lo uso como fuente extra")
            enqueue(.subscribe(c))
        }
        // Saludo y puesta en marcha (orden de los proyectos abiertos goose/noop, que ya descargan la WHOOP 5.0)
        enqueue(.delay(0.3))
        enqueue(.write(WhoopProtocol.clientHello, "HELLO"))
        enqueue(.delay(0.6))
        // Reloj en formato de 8 bytes: si la pulsera cree que ha perdido la hora, NO entrega el historial
        let now = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970))
        let clock: [UInt8] = [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF), UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF), 0, 0, 0, 0]
        command(WhoopProtocol.cmdSetClock, clock, "Poner en hora (orden 10)")
        command(WhoopProtocol.cmdGetClock, [], "Leer reloj (orden 11)")
        command(WhoopProtocol.cmdExitHighFreqSync, [0], "Salir de sincronización rápida (orden 97)")
        command(WhoopProtocol.cmdToggleRealtimeHr, [1], "Pulso en directo ON (orden 3)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self, self.setupStarted else { return }
            self.ready = true
            self.setupWatch?.cancel()
            self.lastRxAt = Date()
            self.offloadedThisConnection = false
            self.setState("Conectada · esperando pulso")
            if WhoopSettings.imuEnabled { self.startImu() }
            self.lastOffloadRequest = Date.distantPast
            // Si en 15 s no llega ningún dato, también se reconecta
            DispatchQueue.main.asyncAfter(deadline: .now() + WhoopManager.setupTimeout) { [weak self] in
                guard let self = self, self.ready, !self.stopping, let p = self.peripheral else { self?.endBgTask(); return }
                if Date().timeIntervalSince(self.lastRxAt) >= WhoopManager.setupTimeout { self.restartLink(p, "conectada pero sin datos") } else { self.endBgTask() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.tickOffload() }
        }
    }

    // ---------- Cola de operaciones (una a la vez) ----------

    private func enqueue(_ op: Op) {
        queue.append(op)
        if !busy { next() }
    }

    private func next() {
        timeoutWork?.cancel()
        guard let p = peripheral, !queue.isEmpty else { busy = false; return }
        let op = queue.removeFirst()
        busy = true
        switch op {
        case .delay(let t):
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.next() }
        case .subscribe(let c):
            p.setNotifyValue(true, for: c)
            armTimeout(2)
        case .write(let frame, let label):
            guard let c = cmdChar else { next(); return }
            handler.recordRaw("TX", "fd4b0002", frame)
            p.writeValue(Data(frame), for: c, type: .withResponse)
            ServiceLog.shared.log("➡️ " + label)
            armTimeout(2)
        }
    }

    private func armTimeout(_ seconds: TimeInterval) {
        let w = DispatchWorkItem { [weak self] in
            ServiceLog.shared.log("⏱️ Sin respuesta a la operación, sigo")
            self?.next()
        }
        timeoutWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        let id = c.uuid.uuidString.prefix(8).lowercased()
        ServiceLog.shared.log("Suscripción \(id): " + (error == nil ? "✅" : "❌ \(error!.localizedDescription)"))
        DispatchQueue.main.async { [weak self] in self?.next() }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let e = error { ServiceLog.shared.log("❌ Escritura rechazada (\(e.localizedDescription))") }
        DispatchQueue.main.async { [weak self] in self?.next() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let data = c.value else { return }
        lastRxAt = Date()
        let uuid: String = c.uuid == WhoopManager.hrMeasurement ? "00002a37" : String(c.uuid.uuidString.prefix(8)).lowercased()
        handler.handleNotification(uuid: uuid, data: [UInt8](data))
        tickOffload()
    }

    // ---------- Órdenes ----------

    private func command(_ cmd: Int, _ payload: [UInt8], _ label: String) {
        seq = (seq + 1) % 256
        guard let frame = WhoopProtocol.buildCommand(cmd, seq: seq, payload: payload) else {
            ServiceLog.shared.log("⛔ Orden \(cmd) prohibida (destructiva): no se envía")
            return
        }
        enqueue(.write(frame, label))
    }

    /// Pide el historial cada 15 min (o al conectar). En "WHOOP conserva" la pulsera siempre manda el mismo primer
    /// bloque: basta con pedirlo una vez por conexión.
    private func tickOffload() {
        guard ready, !handler.offloading else { return }
        if Date().timeIntervalSince(lastOffloadRequest) < WhoopManager.offloadEvery { return }
        if WhoopSettings.ackMode != 1 && offloadedThisConnection { return }
        offloadedThisConnection = true
        requestHistory(force: false)
    }

    private func requestHistory(force: Bool) {
        if handler.offloading && !force { ServiceLog.shared.log("📚 Ya se está descargando el historial"); return }
        lastOffloadRequest = Date()
        ServiceLog.shared.log("📚 Pidiendo a la pulsera lo que guardó mientras no estabas…")
        handler.beginOffload()
        command(WhoopProtocol.cmdSendHistoricalData, [0], "Pedir historial (orden 22)")
        armOffloadIdle()
    }

    private func armOffloadIdle() {
        offloadIdleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.handler.endOffload() }
        offloadIdleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: w)
    }

    private func startImu() {
        command(WhoopProtocol.cmdStartRawData, [0], "Movimiento: START_RAW_DATA (81)")
        enqueue(.delay(0.5))
        command(WhoopProtocol.cmdToggleImuMode, [1, 1], "Movimiento: TOGGLE_IMU_MODE (106)")
    }

    private func stopImu() {
        command(WhoopProtocol.cmdToggleImuMode, [0, 0], "Movimiento OFF (orden 106 [0,0])")
        ServiceLog.shared.log("🚶 Movimiento desactivado")
    }

    // ---------- Estado visible ----------

    private func setState(_ s: String) {
        if Thread.isMainThread { state = s } else { DispatchQueue.main.async { self.state = s } }
    }

    private func pushLive() {
        let h = handler!
        lastBpm = h.lastBpm
        lastBpmTime = h.lastBpmTime
        liveCount = h.liveCount
        historyCount = h.historyCount
        if ready && state != "Conectada · midiendo" { state = "Conectada · midiendo" }
    }

    /// Para pantallas: pasos de hoy en directo.
    var stepsToday: Int { return handler.stepsToday }
    var rawCount: Int { return handler.rawCount }
    var isReady: Bool { return ready }
}
