package com.pulseapp.android

import android.app.*
import android.bluetooth.*
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import java.util.UUID
import com.pulseapp.android.data.AppDatabase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Locale


class BleForegroundService : Service() {

    companion object {
        val HEART_RATE_SERVICE_UUID: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        var externalRecordingInProgress = false // true mientras el usuario graba manualmente con "+"
        var onAutoActivitySaved: ((String) -> Unit)? = null
        val HEART_RATE_MEASUREMENT_UUID: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        const val CHANNEL_ID = "pulse_channel"
        const val NOTIF_ID = 1

        // Comunicación con la UI (MainActivity se suscribe a esto)
        var onBpmUpdate: ((Int, Int) -> Unit)? = null // bpm, totalReadings
        var onStatusUpdate: ((String) -> Unit)? = null
        var onStatsUpdate: ((Int, Int, Double?) -> Unit)? = null // min, avg, rmssd

        const val EXTRA_DEVICE_ADDRESS = "device_address"
    }

    private val bpmHistory = mutableListOf<Int>()
    private val rrHistory = mutableListOf<Double>()

    private lateinit var bluetoothManager: BluetoothManager
    private lateinit var dataStore: DataStore
    private var bluetoothGatt: BluetoothGatt? = null
    private var targetAddress: String? = null
    private var readingsCount = 0
    private val handler = Handler(Looper.getMainLooper())
    private val serviceJob = Job()
    private val serviceScope = CoroutineScope(Dispatchers.IO + serviceJob)
    private var hrMax: Double = 190.0 // valor por defecto hasta cargar el perfil real
    private val recentReadings = mutableListOf<Pair<Long, Int>>()
    private var isAutoRecording = false
    private var autoStartMillis: Long? = null
    private var sustainedAboveSince: Long? = null
    private var sustainedBelowSince: Long? = null
    private var lastProcessedDay: String? = null
    private val dayFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US)

    override fun onCreate() {
        super.onCreate()
        Formulas.init(this)
        bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        dataStore = DataStore(this)
        serviceScope.launch {
            val profile = AppDatabase.getInstance(applicationContext).userProfileDao().getOnce()
            hrMax = Formulas.hrMax(profile?.ageYears() ?: 30)
        }
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        targetAddress = intent?.getStringExtra(EXTRA_DEVICE_ADDRESS)
        startForeground(NOTIF_ID, buildNotification("Buscando reloj..."), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE.let { if (Build.VERSION.SDK_INT >= 34) it else 0 })
        targetAddress?.let { connectToDevice(it) }
        return START_STICKY
    }

    private fun connectToDevice(address: String) {
        bluetoothGatt?.close() // cierra cualquier conexión anterior antes de abrir una nueva
        bluetoothGatt = null
        val adapter = bluetoothManager.adapter
        val device = adapter.getRemoteDevice(address)
        bluetoothGatt = device.connectGatt(this, true, gattCallback)
        onStatusUpdate?.invoke("Conectando...")
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    onStatusUpdate?.invoke("Conectado")
                    updateNotification("Conectado, leyendo pulso")
                    gatt.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    onStatusUpdate?.invoke("Desconectado, reintentando...")
                    updateNotification("Reconectando...")
                    // Reintento automático — clave para el uso 24/7
                    handler.postDelayed({ targetAddress?.let { connectToDevice(it) } }, 3000)
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val service = gatt.getService(HEART_RATE_SERVICE_UUID) ?: return
            val characteristic = service.getCharacteristic(HEART_RATE_MEASUREMENT_UUID) ?: return
            gatt.setCharacteristicNotification(characteristic, true)
            val descriptor = characteristic.getDescriptor(CCCD_UUID)
            descriptor?.let {
                it.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                gatt.writeDescriptor(it)
            }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (characteristic.uuid != HEART_RATE_MEASUREMENT_UUID) return
            val data = characteristic.value ?: return
            val parsed = parseHeartRate(data)
            if (parsed.first <= 0 || parsed.first > 250) return // lectura imposible, se descarta
            readingsCount++
            dataStore.append(parsed.first, parsed.second)
            bpmHistory.add(parsed.first)
            rrHistory.addAll(parsed.second)
            onBpmUpdate?.invoke(parsed.first, readingsCount)
            updateNotification("${parsed.first} ppm · $readingsCount lecturas")
            checkDayRolloverAndUpdateMetrics()
            checkAutoActivity(parsed.first)

            val min = bpmHistory.minOrNull() ?: parsed.first
            val avg = bpmHistory.average().toInt()
            val rmssd = computeRMSSD(rrHistory.takeLast(30))
            onStatsUpdate?.invoke(min, avg, rmssd)
        }
    }

    private fun computeRMSSD(rr: List<Double>): Double? {
        if (rr.size < 2) return null
        var sumSq = 0.0
        for (i in 1 until rr.size) {
            val diff = rr[i] - rr[i - 1]
            sumSq += diff * diff
        }
        return kotlin.math.sqrt(sumSq / (rr.size - 1))
    }

    private fun parseHeartRate(data: ByteArray): Pair<Int, List<Double>> {
        var index = 0
        val flags = data[index].toInt() and 0xFF
        index += 1
        val is16bit = (flags and 0x01) != 0
        val bpm: Int
        if (is16bit) {
            bpm = (data[index].toInt() and 0xFF) or ((data[index + 1].toInt() and 0xFF) shl 8)
            index += 2
        } else {
            bpm = data[index].toInt() and 0xFF
            index += 1
        }
        val rrPresent = (flags shr 4) and 0x1
        val rrIntervals = mutableListOf<Double>()
        if (rrPresent != 0) {
            while (index + 1 < data.size) {
                val raw = (data[index].toInt() and 0xFF) or ((data[index + 1].toInt() and 0xFF) shl 8)
                val ms = raw / 1024.0 * 1000.0
                if (ms in 300.0..2000.0) rrIntervals.add(ms) // descarta intervalos imposibles (glitches)
                index += 2
            }
        }
        return Pair(bpm, rrIntervals)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "Monitor de pulso", NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PulseApp")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val notification = buildNotification(text)
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIF_ID, notification)
    }

   override fun onDestroy() {
        bluetoothGatt?.close()
        serviceJob.cancel()
        super.onDestroy()
    }
    private fun checkAutoActivity(bpm: Int) {
        val now = System.currentTimeMillis()
        recentReadings.add(now to bpm)
        recentReadings.removeAll { now - it.first > 4 * 60 * 1000 } // solo guarda los últimos 4 min

        if (recentReadings.isEmpty()) return
        val rollingAvg = recentReadings.map { it.second }.average()
        val pctHrMax = rollingAvg / hrMax

        if (externalRecordingInProgress) {
            // El usuario está grabando manualmente: no interferimos
            sustainedAboveSince = null
            sustainedBelowSince = null
            return
        }

        if (!isAutoRecording) {
            if (pctHrMax > 0.6) {
                if (sustainedAboveSince == null) sustainedAboveSince = now
                else if (now - sustainedAboveSince!! > 8 * 60 * 1000) {
                    isAutoRecording = true
                    autoStartMillis = sustainedAboveSince
                    sustainedAboveSince = null
                    updateNotification("Actividad detectada automáticamente")
                }
            } else {
                sustainedAboveSince = null
            }
        } else {
            if (pctHrMax < 0.55) {
                if (sustainedBelowSince == null) sustainedBelowSince = now
                else if (now - sustainedBelowSince!! > 5 * 60 * 1000) {
                    val start = autoStartMillis!!
                    val end = sustainedBelowSince!!
                    isAutoRecording = false
                    autoStartMillis = null
                    sustainedBelowSince = null
                    saveAutoDetectedActivity(start, end)
                }
            } else {
                sustainedBelowSince = null
            }
        }
    }

    private fun saveAutoDetectedActivity(start: Long, end: Long) {
        serviceScope.launch {
            val db = AppDatabase.getInstance(applicationContext)
            val profile = db.userProfileDao().getOnce()
            val session = ActivityRecorder().summarize(
                dataStore.getFile(), start, end,
                ageYears = profile?.ageYears() ?: 30,
                weightKg = profile?.weightKg ?: 75f,
                sex = profile?.sex ?: "M",
                type = "Sin clasificar",
                autoDetected = true,
                restingHr = BaselineProvider().compute(db)?.avgRestingHr?.toInt()
            )
            if (session != null) {
                Formulas.updateObservedHrMax(applicationContext, session.maxHr)
                db.activitySessionDao().save(session)
                onAutoActivitySaved?.invoke("Actividad detectada guardada (${((end - start) / 60000)} min)")
            }
        }
    }
    private fun checkDayRolloverAndUpdateMetrics() {
        val today = dayFormat.format(java.util.Date())
        if (today == lastProcessedDay) return
        lastProcessedDay = today

        serviceScope.launch {
            val db = AppDatabase.getInstance(applicationContext)
            val profile = db.userProfileDao().getOnce()
            val file = dataStore.getFile()
            DailyMetricsUpdater().updateYesterdayIfNeeded(
                db, file,
                ageYears = profile?.ageYears() ?: 30,
                weightKg = profile?.weightKg ?: 75f,
                sex = profile?.sex ?: "M"
            )
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
