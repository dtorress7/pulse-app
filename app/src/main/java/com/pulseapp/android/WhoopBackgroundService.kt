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

/**
 * Servicio EXPERIMENTAL en segundo plano para el flujo avanzado del Whoop
 * (movimiento, temperatura). Completamente separado del servicio de pulso
 * normal (BleForegroundService) — si este falla, no afecta a nada más.
 */
class WhoopBackgroundService : Service() {

    companion object {
        val WHOOP_SERVICE = java.util.UUID.fromString("fd4b0001-cce1-4033-93ce-002d5875f58a")
        val CMD_CHARACTERISTIC = java.util.UUID.fromString("fd4b0002-cce1-4033-93ce-002d5875f58a")
        val NOTIFY_CHARACTERISTICS = listOf(
            java.util.UUID.fromString("fd4b0003-cce1-4033-93ce-002d5875f58a"),
            java.util.UUID.fromString("fd4b0004-cce1-4033-93ce-002d5875f58a"),
            java.util.UUID.fromString("fd4b0005-cce1-4033-93ce-002d5875f58a"),
            java.util.UUID.fromString("fd4b0007-cce1-4033-93ce-002d5875f58a")
        )
        val CCCD_UUID = java.util.UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        const val CHANNEL_ID = "whoop_experimental_channel"
        const val NOTIF_ID = 2
                var isRunning = false
        var onRecordSaved: ((Int) -> Unit)? = null
        val serviceLogLines = mutableListOf<String>()

        fun log(msg: String) {
            synchronized(serviceLogLines) {
                serviceLogLines.add(0, "${java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US).format(java.util.Date())} $msg")
                if (serviceLogLines.size > 200) serviceLogLines.removeAt(serviceLogLines.size - 1)
            }
        }
    }

    private lateinit var dataStore: WhoopDataStore
    private val imuReassembler = WhoopImuReassembler()
    private lateinit var imuStore: WhoopImuRawStore
    private var imuMessageCount = 0
    private val IMU_CHARACTERISTIC = java.util.UUID.fromString("fd4b0005-cce1-4033-93ce-002d5875f58a")
    private var seq = 0
    private var gatt: BluetoothGatt? = null
    private val handler = Handler(Looper.getMainLooper())
    private var savedCount = 0

    override fun onCreate() {
        super.onCreate()
        Formulas.init(this)
        dataStore = WhoopDataStore(this)
        imuStore = WhoopImuRawStore(this)
        createNotificationChannel()
        isRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(
            NOTIF_ID, buildNotification("Buscando Whoop (avanzado)..."),
            if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0
        )
        connectToBondedWhoop()
        return START_STICKY
    }

        private fun connectToBondedWhoop() {
        val bluetoothManager = getSystemService(BluetoothManager::class.java)
        val device = try {
            bluetoothManager.adapter.bondedDevices?.firstOrNull {
                it.name?.contains("WHOOP", ignoreCase = true) == true
            }
        } catch (e: SecurityException) { null }

        if (device == null) {
            log("❌ No se encontró ningún Whoop vinculado")
            updateNotification("Whoop no vinculado — usa la pantalla experimental primero")
            return
        }
        log("Encontrado vinculado: ${device.name}, conectando...")
        gatt?.close()
        gatt = device.connectGatt(this, false, gattCallback)
    }

    private val gattCallback = object : BluetoothGattCallback() {
                override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            log("Estado conexión: newState=$newState status=$status")
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                updateNotification("Conectado, despertando canal...")
                g.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                updateNotification("Desconectado, reintentando...")
                handler.postDelayed({ connectToBondedWhoop() }, 5000)
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            log("Servicios descubiertos (status=$status)")
            val service = g.getService(WHOOP_SERVICE)
            if (service == null) {
                log("❌ No se encontró el servicio fd4b0001")
                return
            }
            subscribeNext(g, service, 0)
        }

                        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            val data = characteristic.value ?: return

            if (characteristic.uuid == IMU_CHARACTERISTIC) {
                imuReassembler.feed(data)?.let { message ->
                    imuStore.append(message)
                    imuMessageCount++
                    WhoopImuDecoder.decode(message)?.let { sec ->
                        val tracker = MotionTrackerHolder.get(this@WhoopBackgroundService)
                        tracker.feed(sec)?.let { m ->
                            log("🚶 Minuto: ${m.steps} pasos · intensidad ${m.enmoMg.toInt()} mg · quieto ${m.stillSecs}s")
                            updateNotification("Pasos hoy: ${tracker.stepsToday}")
                        }
                        if (imuMessageCount % 10 == 1) log("🎯 IMU #$imuMessageCount · pasos hoy: ${tracker.stepsToday}")
                    }
                }
            }

            val bio = WhoopProtocol.decodeBioV18(data)
            if (bio == null) {
                if (characteristic.uuid != IMU_CHARACTERISTIC) {
                    log("📥 [${characteristic.uuid.toString().take(8)}] (${data.size}b): ${WhoopProtocol.bytesToHex(data)}")
                }
                return
            }
            dataStore.append(bio)
            savedCount++
            log("🫀 Guardado #$savedCount: FC=${bio.heartRate}")
            if (savedCount % 5 == 0) {
                updateNotification("Guardando datos avanzados ($savedCount)")
                onRecordSaved?.invoke(savedCount)
            }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            log("Escritura en ${characteristic.uuid.toString().take(8)}: status=$status")
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            log("Suscripción a ${descriptor.characteristic.uuid.toString().take(8)}: status=$status")
        }
    }

        private fun subscribeNext(g: BluetoothGatt, service: BluetoothGattService, index: Int) {
        if (index >= NOTIFY_CHARACTERISTICS.size) {
            log("Todas las suscripciones lanzadas, mandando saludo...")
            handler.postDelayed({ sendHello(g, service) }, 300)
            return
        }
        val characteristic = service.getCharacteristic(NOTIFY_CHARACTERISTICS[index])
        if (characteristic == null) { subscribeNext(g, service, index + 1); return }
        g.setCharacteristicNotification(characteristic, true)
        val descriptor = characteristic.getDescriptor(CCCD_UUID)
        if (descriptor == null) { subscribeNext(g, service, index + 1); return }
        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        g.writeDescriptor(descriptor)
        handler.postDelayed({ subscribeNext(g, service, index + 1) }, 300)
    }

            private fun sendHello(g: BluetoothGatt, service: BluetoothGattService) {
        val cmdChar = service.getCharacteristic(CMD_CHARACTERISTIC)
        if (cmdChar == null) {
            log("❌ No se encontró fd4b0002 para el saludo")
            return
        }
        cmdChar.value = WhoopProtocol.CLIENT_HELLO
        val success = g.writeCharacteristic(cmdChar)
        log(if (success) "Saludo enviado" else "❌ Fallo al escribir el saludo")
        updateNotification("Recibiendo movimiento y pulso avanzado")
        handler.postDelayed({ sendImuStart(g, service) }, 1200)
    }

    private fun sendImuStart(g: BluetoothGatt, service: BluetoothGattService) {
        val cmdChar = service.getCharacteristic(CMD_CHARACTERISTIC) ?: return
        seq = (seq + 1) % 256
        cmdChar.value = WhoopProtocol.buildStartRawDataFrame(seq)
        g.writeCharacteristic(cmdChar)
        log("START_RAW_DATA enviado")
        handler.postDelayed({
            seq = (seq + 1) % 256
            cmdChar.value = WhoopProtocol.buildToggleImuModeFrame(seq)
            g.writeCharacteristic(cmdChar)
            log("TOGGLE_IMU_MODE enviado")
        }, 600)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Whoop avanzado", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Whoop avanzado (experimental)")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val n = buildNotification(text)
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIF_ID, n)
    }

    override fun onDestroy() {
        isRunning = false
        gatt?.close()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
