package com.pulseapp.android

import android.app.*
import android.bluetooth.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * CONEXIÓN PRINCIPAL CON LA WHOOP (modo vinculado/propietario), como la app de WHOOP:
 * - Vive en un servicio en primer plano: sigue conectado aunque salgas de la app o se apague la pantalla.
 * - Se reconecta solo (autoConnect): al volver del campo, en cuanto la pulsera está cerca, se reengancha.
 * - Al conectar: suscripciones → HELLO → pulso en directo → pide el historial de la pulsera.
 * - Todo el pulso (en directo o del historial) va a hr_log.csv con su hora real → Inicio, esfuerzo, zonas...
 * - Todo lo que llega (menos el IMU) se guarda en bruto en whoop_history_raw.txt para seguir descifrando.
 * - El registro se guarda en memoria y en whoop_service_log.txt: la pantalla avanzada lo muestra siempre.
 */
class WhoopBackgroundService : Service() {

    companion object {
        val WHOOP_SERVICE: UUID = UUID.fromString("fd4b0001-cce1-4033-93ce-002d5875f58a")
        val CMD_CHARACTERISTIC: UUID = UUID.fromString("fd4b0002-cce1-4033-93ce-002d5875f58a")
        val NOTIFY_CHARACTERISTICS = listOf(
            UUID.fromString("fd4b0003-cce1-4033-93ce-002d5875f58a"),
            UUID.fromString("fd4b0004-cce1-4033-93ce-002d5875f58a"),
            UUID.fromString("fd4b0005-cce1-4033-93ce-002d5875f58a"),
            UUID.fromString("fd4b0007-cce1-4033-93ce-002d5875f58a")
        )
        val IMU_CHARACTERISTIC: UUID = UUID.fromString("fd4b0005-cce1-4033-93ce-002d5875f58a")
        val HR_SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        val HR_MEASUREMENT: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        const val CHANNEL_ID = "whoop_link_channel"
        const val NOTIF_ID = 2

        const val ACTION_CONNECT = "com.pulseapp.android.whoop.CONNECT"
        const val ACTION_HISTORY = "com.pulseapp.android.whoop.HISTORY"
        const val ACTION_IMU_ON = "com.pulseapp.android.whoop.IMU_ON"
        const val ACTION_IMU_OFF = "com.pulseapp.android.whoop.IMU_OFF"
        const val ACTION_STOP = "com.pulseapp.android.whoop.STOP"

        private const val PREFS = "pulseapp_whoop"
        private const val KEY_ADDRESS = "device_address"
        private const val KEY_AUTO = "auto_connect"
        private const val KEY_IMU = "imu_enabled"
        private const val KEY_ACK = "ack_history"   // -1 sin decidir · 0 no confirmar (WHOOP conserva) · 1 confirmar
        private const val OFFLOAD_EVERY_MS = 15 * 60_000L

        /** -1 = aún no ha elegido, 0 = no confirmar (la app de WHOOP sigue pudiendo bajarlo), 1 = confirmar (PulseApp descarga todo). */
        fun ackMode(ctx: Context): Int = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(KEY_ACK, -1)
        fun setAckMode(ctx: Context, mode: Int) =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putInt(KEY_ACK, mode).apply()

        // Estado visible para las pantallas (el servicio vive aunque la pantalla se cierre)
        @Volatile var isRunning = false
        @Volatile var state = "Desconectado"
        @Volatile var lastBpm: Int? = null
        @Volatile var lastBpmTime = 0L
        @Volatile var liveCount = 0
        @Volatile var historyCount = 0
        @Volatile var rawCount = 0
        var onUpdate: (() -> Unit)? = null
        var onActivitySaved: ((String) -> Unit)? = null
        val serviceLogLines = mutableListOf<String>()

        fun log(msg: String) {
            val line = "${SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())} $msg"
            synchronized(serviceLogLines) {
                serviceLogLines.add(0, line)
                if (serviceLogLines.size > 400) serviceLogLines.removeAt(serviceLogLines.size - 1)
            }
            logFile?.let { f ->
                try {
                    if (f.length() > 3_000_000L) f.writeText("")
                    f.appendText(line + "\n")
                } catch (_: Exception) { }
            }
            onUpdate?.invoke()
        }
        private var logFile: File? = null

        fun savedAddress(ctx: Context): String? =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_ADDRESS, null)

        fun saveAddress(ctx: Context, address: String) =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(KEY_ADDRESS, address).putBoolean(KEY_AUTO, true).apply()

        /** true si el usuario quiere la pulsera conectada siempre (se apaga solo con "Desconectar"). */
        fun autoConnectEnabled(ctx: Context): Boolean =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_AUTO, false)

        fun setAutoConnect(ctx: Context, on: Boolean) =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_AUTO, on).apply()

        fun imuEnabled(ctx: Context): Boolean =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_IMU, false)

        fun start(ctx: Context, action: String = ACTION_CONNECT) {
            val i = Intent(ctx, WhoopBackgroundService::class.java).setAction(action)
            try { androidx.core.content.ContextCompat.startForegroundService(ctx, i) } catch (e: Exception) {
                log("❌ No se pudo arrancar el servicio: ${e.message}")
            }
        }

        /** Busca la WHOOP vinculada (la guardada o cualquiera emparejada con "WHOOP" en el nombre). */
        fun findBondedWhoop(ctx: Context): BluetoothDevice? = try {
            val adapter = ctx.getSystemService(BluetoothManager::class.java)?.adapter
            val bonded = adapter?.bondedDevices.orEmpty()
            val saved = savedAddress(ctx)
            bonded.firstOrNull { it.address == saved }
                ?: bonded.firstOrNull { it.name?.contains("WHOOP", ignoreCase = true) == true }
        } catch (e: SecurityException) { null }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var hrStore: DataStore
    private lateinit var bioStore: WhoopDataStore
    private lateinit var imuStore: WhoopImuRawStore
    private lateinit var processor: LiveHrProcessor
    /** Un búfer por característica: las tramas largas llegan troceadas y a veces varias juntas. */
    private val assemblers = HashMap<UUID, java.io.ByteArrayOutputStream>()
    // Estado de la descarga del historial
    private var offloading = false
    private var chunkRecords = 0
    private var offloadRecords = 0
    private var ackedChunks = 0
    private var askedAckOnce = false
    private var responsesLogged = 0
    private var eventsLogged = 0
    private var realtimeLogged = 0
    private var unknownHistLogged = 0
    private val offloadTimer = object : Runnable {
        override fun run() { if (isReady() && !offloading) requestHistory(); handler.postDelayed(this, OFFLOAD_EVERY_MS) }
    }
    private val offloadIdle = Runnable {
        if (offloading) { offloading = false; log("📚 La pulsera dejó de enviar historial (sin COMPLETE). Recibidos $offloadRecords registros; se reintenta en 15 min.") }
    }
    private val rawFile by lazy { File(getExternalFilesDir(null), "whoop_history_raw.txt") }
    private var gatt: BluetoothGatt? = null
    private var device: BluetoothDevice? = null
    private var seq = 0
    private var hrMax = 190.0
    private var imuMessages = 0
    private var stopping = false
    private val writtenSeconds = HashSet<Long>()
    private var lastHistoryPacketAt = 0L

    // ---------- Cola de operaciones GATT (Android solo admite una a la vez) ----------
    private sealed class Op {
        data class Subscribe(val service: UUID, val characteristic: UUID) : Op()
        data class Write(val frame: ByteArray, val label: String) : Op()
        data class Delay(val ms: Long) : Op()
    }
    private val queue = ArrayDeque<Op>()
    private var busy = false
    private val timeoutRunnable = Runnable { log("⏱️ Sin respuesta a la operación, sigo"); next() }

    private fun enqueue(op: Op) { handler.post { queue.addLast(op); if (!busy) next() } }

    private fun next() {
        handler.removeCallbacks(timeoutRunnable)
        val g = gatt
        val op = queue.removeFirstOrNull()
        if (g == null || op == null) { busy = false; return }
        busy = true
        when (op) {
            is Op.Delay -> handler.postDelayed({ next() }, op.ms)
            is Op.Subscribe -> {
                val c = g.getService(op.service)?.getCharacteristic(op.characteristic)
                val d = c?.getDescriptor(CCCD_UUID)
                if (c == null || d == null) { next(); return }
                g.setCharacteristicNotification(c, true)
                d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                if (g.writeDescriptor(d)) handler.postDelayed(timeoutRunnable, 2000) else handler.postDelayed({ next() }, 300)
            }
            is Op.Write -> {
                val c = g.getService(WHOOP_SERVICE)?.getCharacteristic(CMD_CHARACTERISTIC)
                if (c == null) { next(); return }
                c.value = op.frame
                recordRaw("TX", "fd4b0002", op.frame)
                val ok = g.writeCharacteristic(c)
                log(if (ok) "➡️ ${op.label}" else "❌ No se pudo enviar: ${op.label}")
                if (ok) handler.postDelayed(timeoutRunnable, 2000) else handler.postDelayed({ next() }, 300)
            }
        }
    }

    private fun command(cmd: Int, payload: ByteArray, label: String) {
        seq = (seq + 1) % 256
        enqueue(Op.Write(WhoopProtocol.buildCommand(cmd, seq, payload), label))
    }

    // ---------- Ciclo de vida ----------

    override fun onCreate() {
        super.onCreate()
        Formulas.init(this)
        logFile = File(getExternalFilesDir(null), "whoop_service_log.txt")
        hrStore = DataStore(this)
        bioStore = WhoopDataStore(this)
        imuStore = WhoopImuRawStore(this)
        processor = LiveHrProcessor(this, scope, hrStore.getFile()) { msg -> onActivitySaved?.invoke(msg); log("🏃 $msg") }
        createNotificationChannel()
        isRunning = true
        registerReceiver(btStateReceiver, android.content.IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        scope.launch {
            val profile = com.pulseapp.android.data.AppDatabase.getInstance(applicationContext).userProfileDao().getOnce()
            hrMax = Formulas.hrMax(profile?.ageYears() ?: 30)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(
            NOTIF_ID, buildNotification("Conectando con tu WHOOP…"),
            if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0
        )
        when (intent?.action) {
            ACTION_STOP -> {
                stopping = true
                setAutoConnect(this, false)
                log("⏹️ Desconectado a petición tuya")
                setState("Desconectado")
                gatt?.disconnect(); gatt?.close(); gatt = null
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_HISTORY -> if (isReady()) { offloading = false; requestHistory() } else { log("⚠️ Aún no está conectada, lo pediré al conectar"); connect() }
            ACTION_IMU_ON -> {
                getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean(KEY_IMU, true).apply()
                if (isReady()) startImu() else connect()
            }
            ACTION_IMU_OFF -> {
                getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean(KEY_IMU, false).apply()
                if (isReady()) stopImu() else log("🚶 Movimiento desactivado: se aplicará al conectar")
            }
            else -> connect()
        }
        return START_STICKY
    }

    private var ready = false
    private fun isReady() = gatt != null && ready

    private fun connect(force: Boolean = false) {
        if (gatt != null && !force) {
            if (ready) { log("Ya está conectada ($state)"); onUpdate?.invoke(); return }
            // Conexión colgada (p. ej. tras apagar el Bluetooth): se descarta y se abre una nueva
            log("Reabriendo la conexión…")
        }
        try { gatt?.close() } catch (_: SecurityException) { }
        gatt = null
        val d = findBondedWhoop(this)
        if (d == null) {
            log("❌ No hay ninguna WHOOP vinculada. Ve a WHOOP avanzado y pulsa 1 → 2.")
            setState("Sin pulsera vinculada")
            return
        }
        device = d
        saveAddress(this, d.address)
        setAutoConnect(this, true)
        log("🔗 Conectando con ${safeName(d)} (se reconectará sola si se aleja)…")
        setState("Buscando la pulsera…")
        try {
            // autoConnect=true: Android la reengancha en cuanto vuelve a estar a tiro, aunque tarde horas
            gatt = d.connectGatt(this, true, callback, BluetoothDevice.TRANSPORT_LE)
        } catch (e: SecurityException) {
            log("❌ Falta el permiso de Bluetooth: abre la app y acéptalo")
        }
    }

    private fun safeName(d: BluetoothDevice) = try { d.name ?: d.address } catch (e: SecurityException) { d.address }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                log("✅ Conectada (status=$status). Preparando canal…")
                setState("Conectada, preparando…")
                handler.post { queue.clear(); busy = false }
                g.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                ready = false
                offloading = false
                handler.post { queue.clear(); busy = false; handler.removeCallbacks(offloadTimer); handler.removeCallbacks(offloadIdle) }
                if (stopping) return
                log("📴 Desconectada (status=$status). Me reengancho sola cuando vuelva a estar cerca.")
                setState("Fuera de alcance — reconectará sola")
                // Con autoConnect el mismo objeto GATT vuelve a conectar; si Android lo suelta, se reabre
                if (status != 0 && status != 8 && status != 19) {
                    handler.postDelayed({
                        if (!stopping) { gatt?.close(); gatt = null; connect() }
                    }, 5000)
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (g.getService(WHOOP_SERVICE) == null) {
                log("❌ La pulsera no muestra el servicio WHOOP (status=$status)")
                return
            }
            log("Servicios listos. Suscribiéndome de uno en uno…")
            NOTIFY_CHARACTERISTICS.forEach { enqueue(Op.Subscribe(WHOOP_SERVICE, it)) }
            if (g.getService(HR_SERVICE) != null) {
                log("La pulsera también ofrece el pulso estándar: lo uso como fuente extra")
                enqueue(Op.Subscribe(HR_SERVICE, HR_MEASUREMENT))
            }
            // Saludo y puesta en marcha (orden de goose/noop, proyectos abiertos que ya descargan la WHOOP 5.0)
            enqueue(Op.Delay(300))
            enqueue(Op.Write(WhoopProtocol.CLIENT_HELLO, "HELLO"))
            enqueue(Op.Delay(600))
            // Reloj en formato de 8 bytes: si la pulsera cree que ha perdido la hora, NO entrega el historial
            val now = System.currentTimeMillis() / 1000
            command(WhoopProtocol.CMD_SET_CLOCK, byteArrayOf(
                (now and 0xFF).toByte(), ((now shr 8) and 0xFF).toByte(), ((now shr 16) and 0xFF).toByte(), ((now shr 24) and 0xFF).toByte(),
                0, 0, 0, 0), "Poner en hora (orden 10)")
            command(WhoopProtocol.CMD_GET_CLOCK, ByteArray(0), "Leer reloj (orden 11)")
            command(WhoopProtocol.CMD_EXIT_HIGH_FREQ_SYNC, byteArrayOf(0), "Salir de sincronización rápida (orden 97)")
            command(WhoopProtocol.CMD_TOGGLE_REALTIME_HR, byteArrayOf(1), "Pulso en directo ON (orden 3)")
            handler.postDelayed({
                ready = true
                assemblers.clear()
                setState("Conectada · esperando pulso")
                if (imuEnabled(this@WhoopBackgroundService)) startImu() else stopImu(quiet = true)
                handler.removeCallbacks(offloadTimer)
                handler.postDelayed(offloadTimer, 1500)   // primera descarga y luego cada 15 min
            }, 2500)
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            log("Suscripción ${descriptor.characteristic.uuid.toString().take(8)}: ${if (status == 0) "✅" else "❌ $status"}")
            handler.post { next() }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            if (status != 0) log("❌ Escritura rechazada (status=$status)")
            handler.post { next() }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            val data = c.value ?: return
            if (c.uuid == HR_MEASUREMENT) { handleStandardHr(data); return }
            for (frame in assemble(c.uuid, data)) handleFrame(c.uuid, frame)
        }
    }

    // ---------- Datos ----------

    private fun handleStandardHr(data: ByteArray) {
        if (data.size < 2) return
        val flags = data[0].toInt() and 0xFF
        var i = 1
        val bpm = if (flags and 1 != 0) { val v = (data[1].toInt() and 0xFF) or ((data[2].toInt() and 0xFF) shl 8); i = 3; v }
                  else { i = 2; data[1].toInt() and 0xFF }
        if (flags and 0x08 != 0) i += 2
        val rr = mutableListOf<Double>()
        if (flags and 0x10 != 0) while (i + 1 < data.size) {
            val ms = ((data[i].toInt() and 0xFF) or ((data[i + 1].toInt() and 0xFF) shl 8)) / 1024.0 * 1000.0
            if (ms in 300.0..2000.0) rr.add(ms)
            i += 2
        }
        storeHr(System.currentTimeMillis(), bpm, rr, live = true)
    }

    /** Junta trozos y separa tramas completas: [AA][01][declLen u16]... total = declLen + 8. */
    private fun assemble(uuid: UUID, chunk: ByteArray): List<ByteArray> {
        val buf = assemblers.getOrPut(uuid) { java.io.ByteArrayOutputStream() }
        buf.write(chunk)
        var bytes = buf.toByteArray()
        val out = mutableListOf<ByteArray>()
        while (true) {
            val start = bytes.indexOfFirst { (it.toInt() and 0xFF) == 0xAA }
            if (start < 0) { bytes = ByteArray(0); break }
            if (start > 0) bytes = bytes.copyOfRange(start, bytes.size)
            if (bytes.size < 8) break
            val declLen = (bytes[2].toInt() and 0xFF) or ((bytes[3].toInt() and 0xFF) shl 8)
            if (bytes[1].toInt() != 0x01 || declLen < 4 || declLen > 4096) { bytes = bytes.copyOfRange(1, bytes.size); continue }
            val total = declLen + 8
            if (bytes.size < total) break
            out.add(bytes.copyOfRange(0, total))
            bytes = bytes.copyOfRange(total, bytes.size)
        }
        buf.reset()
        if (bytes.size in 1..8192) buf.write(bytes)
        return out
    }

    private fun handleFrame(uuid: UUID, frame: ByteArray) {
        if (frame.size < 12) return
        val type = frame[8].toInt() and 0xFF
        if (type == 43 || type == 51) { handleImu(frame); return }   // movimiento: no se guarda en bruto (es enorme)
        recordRaw("RX", uuid.toString().take(8), frame)
        when (type) {
            47 -> handleHistoricalRecord(frame)
            40 -> handleRealtime(frame)
            49, 56 -> handleMeta(frame)
            36, 38 -> if (responsesLogged++ < 40) {
                val res = when (frame[12].toInt() and 0xFF) { 1 -> "OK"; 2 -> "pendiente"; 3 -> "fallo"; 4 -> "no soportada"; else -> "código ${frame[12].toInt() and 0xFF}" }
                log("↩️ Respuesta a la orden ${frame[10].toInt() and 0xFF}: $res")
            }
            48, 53, 54 -> if (eventsLogged++ < 20) log("🔔 Evento de la pulsera nº ${frame[10].toInt() and 0xFF}")
        }
    }

    private fun handleHistoricalRecord(frame: ByteArray) {
        if (offloading) { chunkRecords++; offloadRecords++; handler.removeCallbacks(offloadIdle); handler.postDelayed(offloadIdle, 60_000) }
        val bio = WhoopProtocol.decodeBioV18(frame)
        if (bio == null) {
            if (unknownHistLogged++ < 3) log("❔ Registro de historial versión ${frame[9].toInt() and 0xFF} aún sin descifrar (${frame.size} B), guardado en bruto")
            return
        }
        bioStore.append(bio)
        val t = bio.unixTime * 1000
        val now = System.currentTimeMillis()
        if (bio.unixTime < 1_600_000_000L || t > now + 5 * 60_000L || t < now - 30L * 86_400_000L) {
            if (historyCount < 5) log("⚠️ Registro con hora rara (${bio.unixTime}), no se usa")
            return
        }
        val live = now - t < 60_000L
        if (!live) {
            historyCount++
            if (historyCount % 600 == 1) log("📚 Historial: $historyCount registros (por ${SimpleDateFormat("dd/MM HH:mm", Locale.US).format(Date(t))})")
        }
        storeHr(t, bio.heartRate, bio.rrIntervalsMs.map { it.toDouble() }.filter { it in 300.0..2000.0 }, live)
    }

    private fun handleRealtime(frame: ByteArray) {
        // El pulso en directo propietario aún no está descifrado para la 5.0: se guarda en bruto para analizarlo
        val bio = WhoopProtocol.decodeBioV18(frame)
        if (bio != null && bio.heartRate in 25..230) {
            storeHr(System.currentTimeMillis(), bio.heartRate, bio.rrIntervalsMs.map { it.toDouble() }.filter { it in 300.0..2000.0 }, live = true)
        } else if (realtimeLogged++ < 3) {
            log("📡 Paquete de pulso en directo (${frame.size} B) guardado para descifrar")
        }
    }

    private fun handleMeta(frame: ByteArray) {
        val meta = WhoopProtocol.decodeMetaPacket(frame) ?: return
        handler.removeCallbacks(offloadIdle)
        handler.postDelayed(offloadIdle, 60_000)
        when (meta.metaTypeByte) {
            1 -> { offloading = true; chunkRecords = 0; log("📚 La pulsera empieza a enviar el historial…") }
            2 -> {
                offloading = true
                val ackData = meta.ackData
                val mode = ackMode(this)
                when {
                    ackData == null -> log("⚠️ Fin de bloque sin datos de confirmación")
                    mode == 1 -> {
                        // Los registros de este bloque ya están escritos en hr_log.csv (se guardan al llegar): se puede confirmar
                        ackedChunks++
                        command(WhoopProtocol.CMD_HISTORICAL_DATA_RESULT, byteArrayOf(1) + ackData,
                            "Bloque $ackedChunks recibido ($chunkRecords registros), pidiendo el siguiente")
                    }
                    else -> if (!askedAckOnce) {
                        askedAckOnce = true
                        log(if (mode == -1) "⏸️ Bloque recibido ($chunkRecords registros). Para seguir con el resto hay que confirmar a la pulsera: elige en \"Mi WHOOP\" quién se queda los datos."
                            else "⏸️ Bloque recibido ($chunkRecords registros). No confirmo (WHOOP conserva los datos), así que la pulsera no envía más.")
                    }
                }
                chunkRecords = 0
            }
            3 -> {
                offloading = false
                handler.removeCallbacks(offloadIdle)
                log("✅ Historial completo: $offloadRecords registros en esta descarga ($ackedChunks bloques)")
                offloadRecords = 0
                onUpdate?.invoke()
            }
            else -> log("🏷️ Metadatos tipo ${meta.metaTypeByte}")
        }
    }

    private fun storeHr(timeMillis: Long, bpm: Int, rr: List<Double>, live: Boolean) {
        if (bpm !in 25..230) return
        val sec = timeMillis / 1000
        synchronized(writtenSeconds) {
            if (!writtenSeconds.add(sec)) return
            if (writtenSeconds.size > 200_000) writtenSeconds.clear()
        }
        hrStore.appendAt(timeMillis, bpm, rr)
        processor.feed(timeMillis, bpm, hrMax)
        if (live) {
            liveCount++
            lastBpm = bpm; lastBpmTime = timeMillis
            if (state != "Conectada · midiendo") setState("Conectada · midiendo")
            if (liveCount % 10 == 1) updateNotification("$bpm ppm · conectada")
            if (liveCount == 1) log("🫀 Llega el pulso en directo: $bpm ppm")
            onUpdate?.invoke()
        }
    }

    private fun handleImu(message: ByteArray) {
        imuStore.append(message)
        imuMessages++
        WhoopImuDecoder.decode(message)?.let { sec ->
            MotionTrackerHolder.get(this).feed(sec)?.let { m ->
                if (imuMessages % 300 < 60) log("🚶 Minuto: ${m.steps} pasos · ${m.enmoMg.toInt()} mg")
            }
        }
    }

    private fun recordRaw(dir: String, uuid: String, data: ByteArray) {
        rawCount++
        try {
            if (rawFile.length() > 40_000_000L) return
            rawFile.appendText("${System.currentTimeMillis()},$dir,$uuid,${WhoopProtocol.bytesToHex(data).replace(" ", "")}\n")
        } catch (_: Exception) { }
    }

    // ---------- Órdenes ----------

    private fun requestHistory() {
        if (offloading) { log("📚 Ya se está descargando el historial"); return }
        log("📚 Pidiendo a la pulsera lo que guardó mientras no estabas…")
        offloading = true
        offloadRecords = 0; ackedChunks = 0; chunkRecords = 0; askedAckOnce = false
        command(WhoopProtocol.CMD_SEND_HISTORICAL_DATA, byteArrayOf(0), "Pedir historial (orden 22)")
        handler.removeCallbacks(offloadIdle)
        handler.postDelayed(offloadIdle, 60_000)
    }

    private fun stopImu(quiet: Boolean = false) {
        // La orden real para cortar el chorro de datos crudos (según noop): 63 con [0]
        command(WhoopProtocol.CMD_SEND_R10_R11_REALTIME, byteArrayOf(0), "Movimiento OFF (orden 63)")
        if (!quiet) log("🚶 Movimiento desactivado")
    }

    private fun startImu() {
        command(WhoopProtocol.CMD_SEND_R10_R11_REALTIME, byteArrayOf(1), "Movimiento: datos crudos ON (orden 63)")
        command(WhoopProtocol.CMD_START_RAW_DATA, byteArrayOf(0), "Movimiento: START_RAW_DATA (81)")
        enqueue(Op.Delay(500))
        command(WhoopProtocol.CMD_TOGGLE_IMU_MODE, byteArrayOf(1, 1), "Movimiento: TOGGLE_IMU_MODE (106)")
    }

    // ---------- Notificación ----------

    private fun setState(s: String) {
        state = s
        updateNotification(s)
        onUpdate?.invoke()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Conexión con WHOOP", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PulseApp · WHOOP")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun updateNotification(text: String) {
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIF_ID, buildNotification(text))
        } catch (_: Exception) { }
    }

    /** Si apagas y enciendes el Bluetooth del móvil, la conexión se rehace sola. */
    private val btStateReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            when (i.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                BluetoothAdapter.STATE_OFF -> {
                    ready = false; offloading = false
                    log("📴 Bluetooth del móvil apagado")
                    setState("Bluetooth apagado")
                    try { gatt?.close() } catch (_: SecurityException) { }
                    gatt = null
                }
                BluetoothAdapter.STATE_ON -> if (!stopping) {
                    log("📶 Bluetooth encendido: reconectando")
                    handler.postDelayed({ connect(force = true) }, 1500)
                }
            }
        }
    }

    override fun onDestroy() {
        try { unregisterReceiver(btStateReceiver) } catch (_: Exception) { }
        isRunning = false
        ready = false
        handler.removeCallbacksAndMessages(null)
        try { gatt?.close() } catch (_: SecurityException) { }
        gatt = null
        scope.cancel()
        if (!stopping) state = "Desconectado"
        onUpdate?.invoke()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
