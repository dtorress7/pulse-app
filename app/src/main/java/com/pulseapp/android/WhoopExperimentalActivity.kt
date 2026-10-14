package com.pulseapp.android

import android.bluetooth.*
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

/**
 * PANTALLA EXPERIMENTAL — no toca nada de la app normal.
 * Nuevo orden: primero CONECTA de forma normal (como ya hace la app para leer
 * el pulso, sin emparejamiento), y solo después, ya conectados, se intenta
 * activar el emparejamiento cifrado — en vez de pedirlo por adelantado.
 */
class WhoopExperimentalActivity : AppCompatActivity() {

    private lateinit var logText: TextView
    private lateinit var bondButton: Button
    private lateinit var connectButton: Button
    private lateinit var historyButton: Button
    private lateinit var historyRequestButton: Button
    private lateinit var enableR22Button: Button   // ← añadir esta línea
    private lateinit var startRawDataButton: Button
    private var seqCounter = 0
    private var decodedCount = 0
    private val imuReassembler = WhoopImuReassembler()
    private lateinit var imuStore: WhoopImuRawStore
    private var imuMessageCount = 0
    private val IMU_CHARACTERISTIC = java.util.UUID.fromString("fd4b0005-cce1-4033-93ce-002d5875f58a")
    private var pendingSubscribeCallback: (() -> Unit)? = null
    
    private var targetDevice: BluetoothDevice? = null
    private var gatt: BluetoothGatt? = null
    private val logLines = mutableListOf<String>()
    private val historyFile by lazy { java.io.File(getExternalFilesDir(null), "whoop_history_raw.txt") }
    private var historyPackets = 0

    /** Guarda TODO lo que llega/sale (menos IMU) para descifrar la descarga del historial: "ms,dir,uuid,HEX". */
    private fun recordRaw(dir: String, uuid: String, data: ByteArray) {
        try {
            if (historyFile.length() > 30_000_000L) return
            historyFile.appendText("${System.currentTimeMillis()},$dir,$uuid,${WhoopProtocol.bytesToHex(data).replace(" ", "")}\n")
        } catch (_: Exception) { }
    }

    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
            val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)
            when (state) {
                BluetoothDevice.BOND_BONDING -> log("Emparejando...")
                                BluetoothDevice.BOND_BONDED -> {
                    log("✅ Emparejado correctamente con ${device?.name}")
                    log("Iniciando guardado automático en segundo plano...")
                    if (ensurePermissions()) {
                        startWhoopBackgroundService()
                    }
                }
                BluetoothDevice.BOND_NONE -> log("❌ Emparejamiento fallido o cancelado")
            }
        }
    }

    private val permissionLauncher = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()
    ) { results ->
        if (results.values.all { it }) {
            log("Permisos concedidos, pulsa 1 de nuevo.")
        } else {
            log("❌ Permisos denegados — no podemos continuar sin ellos.")
        }
    }

    private fun ensurePermissions(): Boolean {
        val needed = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            arrayOf(android.Manifest.permission.BLUETOOTH_SCAN, android.Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
        }
        val missing = needed.filter {
            androidx.core.content.ContextCompat.checkSelfPermission(this, it) != android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        return if (missing.isEmpty()) {
            true
        } else {
            permissionLauncher.launch(missing.toTypedArray())
            false
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_whoop_experimental)

        logText = findViewById(R.id.logText)
        bondButton = findViewById(R.id.bondButton)
        connectButton = findViewById(R.id.connectButton)
        historyButton = findViewById(R.id.historyButton)
        historyRequestButton = findViewById(R.id.historyRequestButton)

        findViewById<TextView>(R.id.backButton).setOnClickListener { finish() }
        imuStore = WhoopImuRawStore(this)

        registerReceiver(bondReceiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))

        bondButton.setOnClickListener {
            if (ensurePermissions()) scanAndConnect()
        }
        connectButton.setOnClickListener { tryBondAfterConnected() }
                historyButton.setOnClickListener { sendHello() }
                historyRequestButton.setOnClickListener { requestHistory() }
        enableR22Button = findViewById(R.id.enableR22Button)
        enableR22Button.setOnClickListener { sendEnableR22() }
        startRawDataButton = findViewById(R.id.startRawDataButton)
        startRawDataButton.setOnClickListener { sendStartRawData() }
        findViewById<Button>(R.id.shareImuButton).setOnClickListener {
            val f = imuStore.getFile()
            if (!f.exists() || f.length() == 0L) {
                log("⚠️ Aún no hay datos IMU guardados")
                return@setOnClickListener
            }
            val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.fileprovider", f)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "Compartir datos IMU"))
        }
        findViewById<Button>(R.id.shareHistoryButton).setOnClickListener {
            if (!historyFile.exists() || historyFile.length() == 0L) {
                log("⚠️ Aún no hay historial guardado. Conecta, envía HELLO y pulsa Pedir historial.")
                return@setOnClickListener
            }
            val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.fileprovider", historyFile)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "Compartir historial bruto"))
        }
        findViewById<Button>(R.id.clearHistoryButton).setOnClickListener {
            try { historyFile.writeText("") } catch (_: Exception) { }
            historyPackets = 0
            log("🗑️ Historial bruto borrado")
        }
        findViewById<Button>(R.id.clearImuButton).setOnClickListener {
            imuStore.clear()
            imuMessageCount = 0
            log("🗑️ Datos IMU borrados")
        }
                val backgroundButton: Button = findViewById(R.id.backgroundToggleButton)
                val viewDataButton: Button = findViewById(R.id.viewWhoopDataButton)
        viewDataButton.setOnClickListener { showSavedWhoopData() }
                val viewServiceLogButton: Button = findViewById(R.id.viewServiceLogButton)
        viewServiceLogButton.setOnClickListener {
            if (WhoopBackgroundService.serviceLogLines.isEmpty()) {
                log("⚠️ El servicio no ha escrito nada en su registro todavía")
            } else {
                log("--- Registro del servicio (${WhoopBackgroundService.serviceLogLines.size} líneas) ---")
                WhoopBackgroundService.serviceLogLines.forEach { log(it) }
            }
        }
         backgroundButton.setOnClickListener {
            if (WhoopBackgroundService.isRunning) {
                stopService(Intent(this, WhoopBackgroundService::class.java))
                backgroundButton.text = "Activar guardado en segundo plano"
                log("Servicio en segundo plano detenido")
            } else {
                if (!ensurePermissions()) {
                    log("❌ Faltan permisos de Bluetooth, acepta el diálogo y pulsa de nuevo")
                    return@setOnClickListener
                }
                startWhoopBackgroundService()
            }
        }
        findViewById<Button>(R.id.copyLogButton).setOnClickListener {
            val clipboard = getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
            clipboard.setPrimaryClip(android.content.ClipData.newPlainText("registro", logLines.joinToString("\n")))
            android.widget.Toast.makeText(this, "Registro copiado", android.widget.Toast.LENGTH_SHORT).show()
        }

        log("Pulsa 1 para buscar tu reloj y CONECTAR (sin emparejar todavía).")
    }
        private fun showSavedWhoopData() {
        val file = java.io.File(getExternalFilesDir(null), "whoop_bio_log.csv")
        if (!file.exists()) {
            log("⚠️ Todavía no existe whoop_bio_log.csv — activa primero el segundo plano y espera un poco")
            return
        }
        val lines = file.readLines()
        val totalDataLines = (lines.size - 1).coerceAtLeast(0)
        log("📊 whoop_bio_log.csv tiene $totalDataLines filas de datos guardadas")
        log("Últimas 10 filas:")
        lines.takeLast(10).forEach { log(it) }
    }
            private fun startWhoopBackgroundService() {
        gatt?.close()
        androidx.core.content.ContextCompat.startForegroundService(
            this, Intent(this, WhoopBackgroundService::class.java)
        )
        findViewById<Button>(R.id.backgroundToggleButton).text = "Detener guardado en segundo plano"
        log("Servicio en segundo plano iniciado — ya puedes salir de esta pantalla")
    }
        private fun log(msg: String) {
        runOnUiThread {
            logLines.add(0, msg)
            logText.text = logLines.joinToString("\n")
        }
    }

    private fun scanAndConnect() {
        log("Buscando dispositivos...")
        val bluetoothManager = getSystemService(BluetoothManager::class.java)
        val scanner = bluetoothManager.adapter.bluetoothLeScanner

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val device = result.device
                val name = try { device.name } catch (e: SecurityException) { null }
                if (name != null && name.contains("WHOOP", ignoreCase = true)) {
                    log("Encontrado: $name — conectando (sin emparejar)...")
                    targetDevice = device
                    scanner.stopScan(this)
                    connectGattOnly(device)
                }
            }
        }
        try {
            scanner.startScan(callback)
            android.os.Handler(mainLooper).postDelayed({
                scanner.stopScan(callback)
                if (targetDevice == null) log("No se encontró ningún WHOOP en 10s")
            }, 10000)
        } catch (e: SecurityException) {
            log("❌ Falta permiso de Bluetooth")
        }
    }

    private fun connectGattOnly(device: BluetoothDevice) {
        gatt = device.connectGatt(this, false, object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    log("✅ Conectado (sin emparejar). Descubriendo servicios...")
                    g.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    log("Desconectado (status=$status)")
                }
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                log("--- Servicios encontrados ---")
                for (service in g.services) {
                    log("Servicio: ${service.uuid}")
                    for (characteristic in service.characteristics) {
                        log("  Característica: ${characteristic.uuid}")
                    }
                }
                log("--- Fin de la lista ---")
                val hasWhoopFamily = g.services.any { it.uuid.toString().startsWith("fd4b0001") }
                if (hasWhoopFamily) {
                    log("✅ Encontrada la familia fd4b0001 (protocolo NOOP)")
                } else {
                    log("⚠️ No se encontró fd4b0001 — puede que tu firmware use otros UUIDs")
                }
                runOnUiThread {
                    connectButton.isEnabled = true
                    if (g.device.bondState == BluetoothDevice.BOND_BONDED) {
                        historyButton.isEnabled = true
                    }
                }
            }
            
            override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                val data = characteristic.value ?: return
                if (characteristic.uuid == IMU_CHARACTERISTIC) {
       imuReassembler.feed(data)?.let { message ->
           imuStore.append(message)
           imuMessageCount++
           WhoopImuDecoder.decode(message)?.let { sec ->
               val tracker = MotionTrackerHolder.get(this@WhoopExperimentalActivity)
               tracker.feed(sec)?.let { m ->
                   log("🚶 Minuto: ${m.steps} pasos · intensidad ${m.enmoMg.toInt()} mg · quieto ${m.stillSecs}s")
               }
               if (imuMessageCount % 10 == 1) log("🎯 IMU #$imuMessageCount · pasos hoy: ${tracker.stepsToday}")
           }
       }
   }
                if (characteristic.uuid != IMU_CHARACTERISTIC) {
                    recordRaw("RX", characteristic.uuid.toString().take(8), data)
                    historyPackets++
                    if (historyPackets % 200 == 0) log("💾 Historial bruto: $historyPackets paquetes guardados")
                }
                decodedCount++
                if (decodedCount > 20) {
                    if (decodedCount % 50 == 0) log("... van $decodedCount paquetes recibidos en total ...")
                    return
                }
                val meta = WhoopProtocol.decodeMetaPacket(data)
                if (meta != null) {
                    log("🏷️ METADATOS: tipo=${meta.metaTypeByte} · cursor=${meta.cursorHex}")
                    return
                }
                val bio = WhoopProtocol.decodeBioV18(data)
                if (bio != null) {
                    val shortUuid = characteristic.uuid.toString().take(8)
                    log("🫀 [$shortUuid] FC=${bio.heartRate}bpm · RR=${bio.rrIntervalsMs} · " +
                        "Temp=${"%.1f".format(bio.skinTempC)}°C · " +
                        "Gravedad=(${"%.2f".format(bio.gravityX)}, ${"%.2f".format(bio.gravityY)}, ${"%.2f".format(bio.gravityZ)})")
                } else {
                    log("📥 Respuesta de ${characteristic.uuid} (${data.size} bytes): ${WhoopProtocol.bytesToHex(data)}")
                }
            }

            override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
                log(if (status == BluetoothGatt.GATT_SUCCESS) "✅ Escritura confirmada" else "❌ Error al escribir (status=$status)")
            }
                        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
                log("Suscripción a ${descriptor.characteristic.uuid}: ${if (status == BluetoothGatt.GATT_SUCCESS) "✅" else "❌ (status=$status)"}")
                val callback = pendingSubscribeCallback
                pendingSubscribeCallback = null
                callback?.invoke()
            }
        })
    }

       private fun tryBondAfterConnected() {
        val device = targetDevice
        if (device == null) {
            log("❌ Conecta primero (paso 1)")
            return
        }
        if (device.bondState == BluetoothDevice.BOND_BONDED) {
            log("✅ Ya estaba emparejado de antes — reconectando limpio...")
            gatt?.close()
            android.os.Handler(mainLooper).postDelayed({
                connectGattOnly(device)
            }, 500)
            return
        }
        log("Ya conectados — intentando activar emparejamiento cifrado...")
        try {
            device.createBond()
        } catch (e: SecurityException) {
            log("❌ Falta permiso de Bluetooth")
        }
    }
    private val WHOOP_SERVICE = java.util.UUID.fromString("fd4b0001-cce1-4033-93ce-002d5875f58a")
    private val CMD_CHARACTERISTIC = java.util.UUID.fromString("fd4b0002-cce1-4033-93ce-002d5875f58a")
    private val NOTIFY_CHARACTERISTICS = listOf(
        java.util.UUID.fromString("fd4b0003-cce1-4033-93ce-002d5875f58a"),
        java.util.UUID.fromString("fd4b0004-cce1-4033-93ce-002d5875f58a"),
        java.util.UUID.fromString("fd4b0005-cce1-4033-93ce-002d5875f58a"),
        java.util.UUID.fromString("fd4b0007-cce1-4033-93ce-002d5875f58a")
    )
    private val CCCD_UUID = java.util.UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private fun sendHello() {
        val g = gatt ?: run { log("❌ Conecta primero"); return }
        val service = g.getService(WHOOP_SERVICE) ?: run { log("❌ No se encontró el servicio Whoop"); return }

               log("Suscribiéndose a las características de datos (una a una)...")
        subscribeNext(g, service, 0)

        android.os.Handler(mainLooper).postDelayed({
            val cmdChar = service.getCharacteristic(CMD_CHARACTERISTIC)
            if (cmdChar == null) {
                log("❌ No se encontró la característica de comandos fd4b0002")
                return@postDelayed
            }
            log("Enviando CLIENT_HELLO: ${WhoopProtocol.bytesToHex(WhoopProtocol.CLIENT_HELLO)}")
            cmdChar.value = WhoopProtocol.CLIENT_HELLO
            recordRaw("TX", "fd4b0002", WhoopProtocol.CLIENT_HELLO)
            val success = g.writeCharacteristic(cmdChar)
            log(if (success) "Saludo enviado, esperando respuesta..." else "❌ Fallo al escribir el saludo — no sigas al botón 4, repite desde el 1")
            runOnUiThread {
                historyRequestButton.isEnabled = success
                enableR22Button.isEnabled = success
                startRawDataButton.isEnabled = success
            }
        }, 500)
    }

    private fun sendStartRawData() {
        val g = gatt ?: run { log("❌ Conecta primero"); return }
        val service = g.getService(WHOOP_SERVICE) ?: return
        val cmdChar = service.getCharacteristic(CMD_CHARACTERISTIC) ?: return

        seqCounter = (seqCounter + 1) % 256
        val frame1 = WhoopProtocol.buildStartRawDataFrame(seqCounter)
        log("START_RAW_DATA: ${WhoopProtocol.bytesToHex(frame1)}")
        cmdChar.value = frame1
        recordRaw("TX", "fd4b0002", frame1)
        g.writeCharacteristic(cmdChar)

        android.os.Handler(mainLooper).postDelayed({
            seqCounter = (seqCounter + 1) % 256
            val frame2 = WhoopProtocol.buildToggleImuModeFrame(seqCounter)
            log("TOGGLE_IMU_MODE: ${WhoopProtocol.bytesToHex(frame2)}")
            cmdChar.value = frame2
            recordRaw("TX", "fd4b0002", frame2)
            g.writeCharacteristic(cmdChar)
            log("✅ Secuencia IMU enviada — espera unos segundos y mira si llegan paquetes tipo 43/51")
        }, 500)
    }
    
    private fun sendEnableR22() {
        val g = gatt ?: run { log("❌ Conecta primero"); return }
        val service = g.getService(WHOOP_SERVICE) ?: return
        val cmdChar = service.getCharacteristic(CMD_CHARACTERISTIC) ?: return

        val flags = listOf(
            "enable_r22_v4_packets" to '1',
            "enable_r22_v3_packets" to '2'
        )

        fun sendFlag(index: Int) {
            if (index >= flags.size) {
                log("✅ Banderas enviadas — espera unos segundos y mira si fd4b0005 despierta")
                return
            }
            val (name, value) = flags[index]
            seqCounter = (seqCounter + 1) % 256
            val frame = WhoopProtocol.buildSetConfigFrame(name, value, seqCounter)
            log("Activando '$name'=$value: ${WhoopProtocol.bytesToHex(frame)}")
            cmdChar.value = frame
            recordRaw("TX", "fd4b0002", frame)
            g.writeCharacteristic(cmdChar)
            android.os.Handler(mainLooper).postDelayed({ sendFlag(index + 1) }, 600)
        }
        sendFlag(0)
        }
    

        private fun requestHistory() {
        val g = gatt ?: run { log("❌ Conecta primero"); return }
        val service = g.getService(WHOOP_SERVICE) ?: return
        val cmdChar = service.getCharacteristic(CMD_CHARACTERISTIC) ?: return

        // Paso que faltaba: sincronizar el reloj antes de pedir el historial
        seqCounter = (seqCounter + 1) % 256
        val clockPayload = ByteArray(4) // por ahora vacío, solo para "tocar" el reloj
        val clockFrame = WhoopProtocol.buildCommand(WhoopProtocol.CMD_GET_CLOCK, seqCounter, clockPayload)
        log("Sincronizando reloj: ${WhoopProtocol.bytesToHex(clockFrame)}")
        cmdChar.value = clockFrame
        recordRaw("TX", "fd4b0002", clockFrame)
        g.writeCharacteristic(cmdChar)

        android.os.Handler(mainLooper).postDelayed({
            seqCounter = (seqCounter + 1) % 256
            val frame = WhoopProtocol.buildCommand(
                WhoopProtocol.CMD_SEND_HISTORICAL_DATA, seqCounter, byteArrayOf(0)
            )
            log("Pidiendo historial (byte correcto=0): ${WhoopProtocol.bytesToHex(frame)}")
            cmdChar.value = frame
            recordRaw("TX", "fd4b0002", frame)
            g.writeCharacteristic(cmdChar)
        }, 800)
    }
    private fun subscribeNext(g: BluetoothGatt, service: BluetoothGattService, index: Int) {
        if (index >= NOTIFY_CHARACTERISTICS.size) {
            log("✅ Suscrito a las ${NOTIFY_CHARACTERISTICS.size} características")
            return
        }
        val uuid = NOTIFY_CHARACTERISTICS[index]
        val characteristic = service.getCharacteristic(uuid)
        if (characteristic == null) {
            subscribeNext(g, service, index + 1)
            return
        }
        g.setCharacteristicNotification(characteristic, true)
        val descriptor = characteristic.getDescriptor(CCCD_UUID)
        if (descriptor == null) {
            subscribeNext(g, service, index + 1)
            return
        }
        pendingSubscribeCallback = { subscribeNext(g, service, index + 1) }
        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        g.writeDescriptor(descriptor)
    }
    override fun onDestroy() {
        try { unregisterReceiver(bondReceiver) } catch (e: Exception) { }
        gatt?.close()
        super.onDestroy()
    }
}
