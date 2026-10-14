package com.pulseapp.android

import android.bluetooth.*
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.View
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File

/**
 * "Mi WHOOP": vincular la pulsera (solo la primera vez) y ver/controlar la conexión.
 * La conexión NO vive aquí, sino en WhoopBackgroundService: puedes salir de esta pantalla,
 * de la app o bloquear el móvil y sigue conectada; al volver, el estado y el registro siguen ahí.
 */
class WhoopExperimentalActivity : AppCompatActivity() {

    private lateinit var logText: TextView
    private lateinit var statusText: TextView
    private lateinit var deviceText: TextView
    private lateinit var statusDot: View
    private lateinit var connectButton: TextView
    private lateinit var imuButton: TextView
    private val handler = Handler(Looper.getMainLooper())

    // Solo para el emparejamiento inicial
    private var targetDevice: BluetoothDevice? = null
    private var pairingGatt: BluetoothGatt? = null
    private var scanning = false

    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
            when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)) {
                BluetoothDevice.BOND_BONDING -> log("Vinculando… (la luz de la pulsera debe estar azul)")
                BluetoothDevice.BOND_BONDED -> {
                    log("✅ Vinculada: ${safeName(device)}")
                    device?.let { handOverToService(it) }
                }
                BluetoothDevice.BOND_NONE -> log("❌ Vinculación fallida o cancelada. Toca la pulsera hasta la luz azul y repite 1 → 2.")
            }
        }
    }

    private val permissionLauncher = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()
    ) { results ->
        log(if (results.values.all { it }) "Permisos concedidos, repite el paso." else "❌ Sin permisos de Bluetooth no puede conectar.")
    }

    private fun ensurePermissions(): Boolean {
        val needed = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            mutableListOf(android.Manifest.permission.BLUETOOTH_SCAN, android.Manifest.permission.BLUETOOTH_CONNECT).apply {
                if (android.os.Build.VERSION.SDK_INT >= 33) add(android.Manifest.permission.POST_NOTIFICATIONS)
            }
        } else listOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
        val missing = needed.filter { ContextCompat.checkSelfPermission(this, it) != android.content.pm.PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) return true
        permissionLauncher.launch(missing.toTypedArray())
        return false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_whoop_experimental)
        logText = findViewById(R.id.logText)
        statusText = findViewById(R.id.statusText)
        deviceText = findViewById(R.id.deviceText)
        statusDot = findViewById(R.id.statusDot)
        connectButton = findViewById(R.id.connectButton)
        imuButton = findViewById(R.id.imuButton)

        findViewById<View>(R.id.backButton).setOnClickListener { finish() }
        registerReceiver(bondReceiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))

        findViewById<View>(R.id.bondButton).setOnClickListener { if (ensurePermissions()) scanAndConnect() }
        connectButton.setOnClickListener { bondOrConnect() }
        findViewById<View>(R.id.reconnectButton).setOnClickListener {
            if (ensurePermissions()) WhoopBackgroundService.start(this)
        }
        findViewById<View>(R.id.historyRequestButton).setOnClickListener {
            if (ensurePermissions()) WhoopBackgroundService.start(this, WhoopBackgroundService.ACTION_HISTORY)
        }
        imuButton.setOnClickListener {
            val on = !WhoopBackgroundService.imuEnabled(this)
            if (on) {
                androidx.appcompat.app.AlertDialog.Builder(this)
                    .setTitle("Movimiento y pasos")
                    .setMessage("Activa el acelerómetro para contar pasos. Gasta el doble de batería de la pulsera y todavía " +
                        "no conocemos la orden para pararlo: se para al desconectar. ¿Activarlo?")
                    .setPositiveButton("Activar") { _, _ ->
                        WhoopBackgroundService.start(this, WhoopBackgroundService.ACTION_IMU_ON); refresh()
                    }
                    .setNegativeButton("Cancelar", null).show()
            } else {
                WhoopBackgroundService.start(this, WhoopBackgroundService.ACTION_IMU_OFF); refresh()
            }
        }
        findViewById<View>(R.id.batteryButton).setOnClickListener { askIgnoreBatteryOptimizations() }
        findViewById<View>(R.id.ackModeButton).setOnClickListener { AckModeDialog.show(this) { refresh() } }
        findViewById<View>(R.id.disconnectButton).setOnClickListener {
            androidx.appcompat.app.AlertDialog.Builder(this)
                .setTitle("Desconectar")
                .setMessage("La pulsera dejará de enviar datos a PulseApp hasta que pulses \"Conectar ahora\". ¿Seguro?")
                .setPositiveButton("Desconectar") { _, _ -> WhoopBackgroundService.start(this, WhoopBackgroundService.ACTION_STOP) }
                .setNegativeButton("Cancelar", null).show()
        }

        findViewById<View>(R.id.copyLogButton).setOnClickListener {
            val text = synchronized(WhoopBackgroundService.serviceLogLines) { WhoopBackgroundService.serviceLogLines.joinToString("\n") }
            val cb = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
            cb.setPrimaryClip(android.content.ClipData.newPlainText("registro", text))
            Toast.makeText(this, "Registro copiado", Toast.LENGTH_SHORT).show()
        }
        findViewById<View>(R.id.shareLogButton).setOnClickListener { share("whoop_service_log.txt", "Compartir registro") }
        findViewById<View>(R.id.shareHistoryButton).setOnClickListener { share("whoop_history_raw.txt", "Compartir historial bruto") }
        findViewById<View>(R.id.clearHistoryButton).setOnClickListener {
            try { File(getExternalFilesDir(null), "whoop_history_raw.txt").writeText("") } catch (_: Exception) { }
            WhoopBackgroundService.rawCount = 0
            log("🗑️ Historial bruto borrado")
        }
        findViewById<View>(R.id.shareImuButton).setOnClickListener { share("whoop_imu_raw.txt", "Compartir movimiento") }
        findViewById<View>(R.id.clearImuButton).setOnClickListener {
            WhoopImuRawStore(this).clear()
            log("🗑️ Datos de movimiento borrados")
        }

        // Si ya está vinculada y no hay servicio, se conecta sola al entrar
        if (WhoopBackgroundService.findBondedWhoop(this) != null && !WhoopBackgroundService.isRunning && ensurePermissions()) {
            WhoopBackgroundService.start(this)
        }
    }

    override fun onResume() {
        super.onResume()
        WhoopBackgroundService.onUpdate = { handler.post { refresh() } }
        refresh()
        handler.post(ticker)
    }

    override fun onPause() {
        super.onPause()
        WhoopBackgroundService.onUpdate = null
        handler.removeCallbacks(ticker)
    }

    private val ticker = object : Runnable {
        override fun run() { refresh(); handler.postDelayed(this, 2000) }
    }

    private fun refresh() {
        val st = WhoopBackgroundService.state
        val running = WhoopBackgroundService.isRunning
        statusText.text = if (running) st else "Desconectado"
        val live = WhoopBackgroundService.lastBpmTime > System.currentTimeMillis() - 15_000
        statusDot.setBackgroundResource(
            when {
                running && live -> R.drawable.bg_dot_green
                running && st.startsWith("Conectada") -> R.drawable.bg_dot_blue
                running -> R.drawable.bg_dot_amber
                else -> R.drawable.bg_dot_red
            }
        )
        val bonded = WhoopBackgroundService.findBondedWhoop(this)
        deviceText.text = if (bonded != null) "Vinculada: ${safeName(bonded)}" else "Ninguna WHOOP vinculada todavía"
        findViewById<TextView>(R.id.liveBpmText).text = if (live) "${WhoopBackgroundService.lastBpm}" else "--"
        findViewById<TextView>(R.id.liveCountText).text = Ui.thousands(WhoopBackgroundService.liveCount.toLong())
        findViewById<TextView>(R.id.historyCountText).text = Ui.thousands(WhoopBackgroundService.historyCount.toLong())
        findViewById<TextView>(R.id.ackModeButton).text = AckModeDialog.label(WhoopBackgroundService.ackMode(this))
        imuButton.text = if (WhoopBackgroundService.imuEnabled(this)) "Movimiento y pasos: desactivar" else "Movimiento y pasos: activar"
        val lines = synchronized(WhoopBackgroundService.serviceLogLines) { WhoopBackgroundService.serviceLogLines.take(150) }
        logText.text = if (lines.isEmpty()) "Sin actividad todavía." else lines.joinToString("\n")
    }

    private fun log(msg: String) = WhoopBackgroundService.log(msg)

    private fun safeName(d: BluetoothDevice?) = try { d?.name ?: d?.address ?: "" } catch (e: SecurityException) { d?.address ?: "" }

    // ---------- Vinculación inicial ----------

    private fun scanAndConnect() {
        if (scanning) return
        // Si el servicio está conectado, se suelta para poder vincular de nuevo
        if (WhoopBackgroundService.isRunning) stopService(Intent(this, WhoopBackgroundService::class.java))
        val scanner = getSystemService(BluetoothManager::class.java).adapter.bluetoothLeScanner
        targetDevice = null
        log("🔎 Buscando tu WHOOP… (si está conectada al iPhone, desvincúlala allí o apaga su Bluetooth)")
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val name = try { result.device.name } catch (e: SecurityException) { null }
                if (name != null && name.contains("WHOOP", ignoreCase = true) && targetDevice == null) {
                    targetDevice = result.device
                    try { scanner.stopScan(this) } catch (_: SecurityException) { }
                    scanning = false
                    log("Encontrada: $name. Conectando para vincular…")
                    connectForPairing(result.device)
                }
            }
        }
        try {
            scanning = true
            scanner.startScan(cb)
            handler.postDelayed({
                if (scanning) {
                    try { scanner.stopScan(cb) } catch (_: SecurityException) { }
                    scanning = false
                    if (targetDevice == null) log("No se encontró ninguna WHOOP en 12 s. ¿Está conectada a otro móvil?")
                }
            }, 12_000)
        } catch (e: SecurityException) { log("❌ Falta permiso de Bluetooth") }
    }

    private fun connectForPairing(device: BluetoothDevice) {
        pairingGatt?.close()
        pairingGatt = device.connectGatt(this, false, object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    log("Conectada (sin vincular). Comprobando…"); g.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    log("Conexión de vinculación cerrada (status=$status)")
                }
            }
            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                if (g.getService(WhoopBackgroundService.WHOOP_SERVICE) != null) {
                    log("✅ Es tu WHOOP. Toca la pulsera hasta que la luz se ponga AZUL y pulsa 2.")
                } else log("⚠️ No muestra el servicio WHOOP: prueba de nuevo el 1")
            }
        })
    }

    private fun bondOrConnect() {
        if (!ensurePermissions()) return
        val device = targetDevice ?: WhoopBackgroundService.findBondedWhoop(this)
        if (device == null) { log("❌ Pulsa primero 1 para encontrarla"); return }
        if (device.bondState == BluetoothDevice.BOND_BONDED) {
            log("Ya estaba vinculada.")
            handOverToService(device)
            return
        }
        log("Pidiendo vinculación cifrada…")
        try { device.createBond() } catch (e: SecurityException) { log("❌ Falta permiso de Bluetooth") }
    }

    /** Tras vincular: se cierra la conexión temporal y el servicio toma el control para siempre. */
    private fun handOverToService(device: BluetoothDevice) {
        try { pairingGatt?.disconnect(); pairingGatt?.close() } catch (_: SecurityException) { }
        pairingGatt = null
        WhoopBackgroundService.saveAddress(this, device.address)
        handler.postDelayed({
            log("Pasando la conexión al servicio en segundo plano. Ya puedes salir de esta pantalla.")
            WhoopBackgroundService.start(this)
        }, 800)
    }

    private fun askIgnoreBatteryOptimizations() {
        val pm = getSystemService(PowerManager::class.java)
        if (pm.isIgnoringBatteryOptimizations(packageName)) {
            Toast.makeText(this, "Ya está: Android no cerrará la conexión por batería", Toast.LENGTH_LONG).show()
            return
        }
        try {
            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
        } catch (e: Exception) {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    private fun share(fileName: String, title: String) {
        val f = File(getExternalFilesDir(null), fileName)
        if (!f.exists() || f.length() == 0L) { log("⚠️ $fileName está vacío todavía"); return }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", f)
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }, title))
    }

    override fun onDestroy() {
        try { unregisterReceiver(bondReceiver) } catch (_: Exception) { }
        try { pairingGatt?.close() } catch (_: SecurityException) { }
        super.onDestroy()
    }
}
