package com.pulseapp.android

import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.ArrayAdapter
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.ui.CircularRingView
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class MainActivity : AppCompatActivity() {

    private lateinit var bpmText: TextView
    private lateinit var statusText: TextView
    private lateinit var countText: TextView
    private lateinit var minHrText: TextView
    private lateinit var avgHrText: TextView
    private lateinit var hrvText: TextView
    private lateinit var vo2MaxText: TextView
    private lateinit var respiratoryRateText: TextView
    private lateinit var recoveryRing: CircularRingView
    private lateinit var strainRing: CircularRingView
    private lateinit var sleepRing: CircularRingView
    private lateinit var rowScan: LinearLayout
    private lateinit var rowProfile: LinearLayout
    private lateinit var rowSummary: LinearLayout
    private lateinit var rowExport: LinearLayout
    private lateinit var stressCard: LinearLayout
    private lateinit var stressUpdatedText: TextView
    private lateinit var stressLevelText: TextView
    private lateinit var stressScoreText: TextView
    private lateinit var stressChart: com.pulseapp.android.ui.StressChartView
    private val stressCalculator = StressCalculator()
    private val calorieCalculator = CalorieCalculator()
    private val recoveryCalculator = RecoveryCalculator()
    private val baselineProvider = BaselineProvider()
    private val sleepPlanner = SleepPlanner()
    private val activityRecorder = ActivityRecorder()
    private var activityStartMillis: Long? = null
    private lateinit var tabActionView: View
    private lateinit var sleepNeedText: TextView
    private lateinit var sleepBedtimeText: TextView
    private lateinit var sleepBreakdownText: TextView
    private lateinit var caloriesText: TextView

    private val db by lazy { AppDatabase.getInstance(this) }

    private val devices = mutableListOf<android.bluetooth.BluetoothDevice>()
    private lateinit var adapter: ArrayAdapter<String>

    private val requiredPermissions: Array<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.POST_NOTIFICATIONS
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { results ->
        if (results.values.all { it }) {
            startScan()
        } else {
            statusText.text = "Permisos denegados: necesarios para Bluetooth"
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        bpmText = findViewById(R.id.bpmText)
        statusText = findViewById(R.id.statusText)
        countText = findViewById(R.id.countText)
        minHrText = findViewById(R.id.minHrText)
        avgHrText = findViewById(R.id.avgHrText)
        hrvText = findViewById(R.id.hrvText)
        vo2MaxText = findViewById(R.id.vo2MaxText)
        respiratoryRateText = findViewById(R.id.respiratoryRateText)
        recoveryRing = findViewById(R.id.recoveryRing)
        strainRing = findViewById(R.id.strainRing)
        sleepRing = findViewById(R.id.sleepRing)
        rowScan = findViewById(R.id.rowScan)
        rowProfile = findViewById(R.id.rowProfile)
        rowSummary = findViewById(R.id.rowSummary)
        rowExport = findViewById(R.id.rowExport)
        stressCard = findViewById(R.id.stressCard)
        stressUpdatedText = findViewById(R.id.stressUpdatedText)
        stressLevelText = findViewById(R.id.stressLevelText)
        stressScoreText = findViewById(R.id.stressScoreText)
        stressChart = findViewById(R.id.stressChart)
        caloriesText = findViewById(R.id.caloriesText)
        sleepNeedText = findViewById(R.id.sleepNeedText)
        sleepBedtimeText = findViewById(R.id.sleepBedtimeText)
        sleepBreakdownText = findViewById(R.id.sleepBreakdownText)
        stressCard.setOnClickListener {
            startActivity(Intent(this, StressDetailActivity::class.java))
        }

        // Valores iniciales de los anillos (vacíos hasta tener datos reales)
        recoveryRing.setValue(0f, "--", "RECOVERY", ContextCompat.getColor(this, R.color.recovery_green))
        recoveryRing.setOnClickListener {
            startActivity(Intent(this, RecoveryDetailActivity::class.java))
        }
        strainRing.setValue(0f, "--", "STRAIN", ContextCompat.getColor(this, R.color.strain_blue))
        sleepRing.setValue(0f, "--", "SUEÑO", ContextCompat.getColor(this, R.color.sleep_blue))
        sleepRing.setOnClickListener {
            startActivity(Intent(this, SleepDetailActivity::class.java))
        }

        rowExport.setOnClickListener { exportCsv() }
        findViewById<View>(R.id.rowWhoopExperimental).setOnClickListener {
            startActivity(Intent(this, WhoopExperimentalActivity::class.java))
        }
        rowSummary.setOnClickListener { showSummary() }
        rowProfile.setOnClickListener {
            startActivity(Intent(this, ProfileActivity::class.java))
        }
        findViewById<View>(R.id.tabSleep).setOnClickListener {
            startActivity(Intent(this, SleepDetailActivity::class.java))
        }
       findViewById<View>(R.id.tabRecovery).setOnClickListener {
            startActivity(Intent(this, RecoveryDetailActivity::class.java))
        }
        findViewById<View>(R.id.tabCoach).setOnClickListener {
            Toast.makeText(this, "Próximamente", Toast.LENGTH_SHORT).show()
        }
        tabActionView = findViewById(R.id.tabAction)
        tabActionView.setOnClickListener {
            toggleActivityRecording()
        }

        adapter = ArrayAdapter(this, android.R.layout.simple_list_item_1, mutableListOf())

        rowScan.setOnClickListener {
            if (requiredPermissions.all {
                    ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
                }) {
                startScan()
            } else {
                permissionLauncher.launch(requiredPermissions)
            }
        }

        BleForegroundService.onBpmUpdate = { bpm, count ->
            runOnUiThread {
                bpmText.text = bpm.toString()
                countText.text = "$count lecturas guardadas"
            }
        }
        BleForegroundService.onAutoActivitySaved = { message ->
            runOnUiThread {
                Toast.makeText(this, message, Toast.LENGTH_LONG).show()
            }
        }
        BleForegroundService.onStatusUpdate = { status ->
            runOnUiThread { statusText.text = status }
        }
        BleForegroundService.onStatsUpdate = { _, _, rmssd ->
            runOnUiThread {
                hrvText.text = if (rmssd != null) "%.0f".format(rmssd) else "--"
            }
        }
        showSummary()
    }

    override fun onResume() {
        super.onResume()
        showSummary()
    }

    private fun showSummary() {
        lifecycleScope.launch {
            val profile = db.userProfileDao().getOnce()
            val baseline = baselineProvider.compute(db)
            if (profile == null) {
                statusText.text = "Rellena \"Sobre mí\" primero para un cálculo preciso"
            }
            val age = profile?.ageYears() ?: 30 // valor por defecto si aún no hay perfil
            val metricsCalculator = MetricsCalculator(ageYears = age)
            val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
            val summary = withContext(Dispatchers.IO) { metricsCalculator.analyze(file) }
            minHrText.text = summary.restingHr?.let { "$it" } ?: "--"
            avgHrText.text = summary.avgHr?.let { "$it" } ?: "--"

            // VO2max: fijo, solo se recalcula los martes (o si nunca se ha calculado)
            val today = java.util.Calendar.getInstance()
            val isTuesday = today.get(java.util.Calendar.DAY_OF_WEEK) == java.util.Calendar.TUESDAY
            val todayKey = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(today.time)

            val stableVo2Max: Double? = if (profile != null && (isTuesday || profile.vo2Max == null) && summary.vo2Max != null) {
                db.userProfileDao().save(profile.copy(vo2Max = summary.vo2Max, vo2MaxUpdatedDate = todayKey))
                summary.vo2Max
            } else {
                profile?.vo2Max ?: summary.vo2Max
            }
            vo2MaxText.text = stableVo2Max?.let { "%.0f".format(it) } ?: "--"
            respiratoryRateText.text = summary.respiratoryRate?.let { "%.1f rpm".format(it) } ?: "--"
            if (profile != null) {
                val nowCal = java.util.Calendar.getInstance()
                val elapsedMinutesToday = nowCal.get(java.util.Calendar.HOUR_OF_DAY) * 60.0 +
                        nowCal.get(java.util.Calendar.MINUTE)

                val todayStartMillis = (nowCal.clone() as java.util.Calendar).apply {
                    set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0); set(java.util.Calendar.SECOND, 0)
                }.timeInMillis
                val todaySessionsForCalories = db.activitySessionDao().getAll().filter { it.startMillis >= todayStartMillis }
                val activityKcalToday = todaySessionsForCalories.sumOf { it.caloriesKcal }

                val kcal = calorieCalculator.estimateDailyTotal(
                    elapsedMinutesToday, activityKcalToday, age, profile.weightKg, profile.heightCm, profile.sex
                )
                caloriesText.text = "%.0f kcal".format(kcal)
            } else {
                caloriesText.text = "-- (rellena tu perfil)"
            }
            val stressSummary = withContext(Dispatchers.IO) { stressCalculator.analyze(file, summary.restingHr, baseline) }
            val sleepPlan = sleepPlanner.computeTonightPlan(db, summary.strain)
            val needH = sleepPlan.totalNeedMinutes / 60
            val needM = sleepPlan.totalNeedMinutes % 60
            sleepNeedText.text = "${needH}h ${needM}min"
            sleepBedtimeText.text = "Hora de dormir sugerida: ${sleepPlan.suggestedBedtime}"
            sleepBreakdownText.text = "Base 7h50 + Strain %dmin + Deuda %dmin".format(
                sleepPlan.strainAdjustmentMinutes, sleepPlan.debtAdjustmentMinutes
            )
            stressScoreText.text = stressSummary.currentScore?.let { "%.1f".format(it).replace('.', ',') } ?: "--"
            stressLevelText.text = stressSummary.level
            stressLevelText.setTextColor(
                ContextCompat.getColor(this@MainActivity, when (stressSummary.level) {
                    "ALTO" -> R.color.alert_amber
                    "MEDIO" -> R.color.recovery_green
                    else -> R.color.strain_blue
                })
            )
            val baselineNote = if (baseline != null) {
                " (línea base de ${baseline.daysUsed} días)"
            } else {
                " (aún sin línea base — necesitas ${BaselineProvider.MIN_DAYS_REQUIRED}+ días guardados)"
            }
            stressUpdatedText.text = (stressSummary.lastUpdateMinute?.let {
                "Última actualización a las %02d:%02d".format(it / 60, it % 60)
            } ?: "Sin datos todavía") + baselineNote
            stressChart.setSeries(stressSummary.series)
            stressChart.setSleepWindow(summary.sleepStartMinuteOfDay, summary.sleepEndMinuteOfDay)

            // Actividades guardadas hoy, convertidas a minutos del día
            val todayCal = java.util.Calendar.getInstance()
            val todayStart = (todayCal.clone() as java.util.Calendar).apply {
                set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0); set(java.util.Calendar.SECOND, 0)
            }.timeInMillis
            val allSessions = db.activitySessionDao().getAll()
            val todaySessions = allSessions.filter { it.startMillis >= todayStart }
            val activityPeriods = todaySessions.map { session ->
                val startCal = java.util.Calendar.getInstance().apply { timeInMillis = session.startMillis }
                val endCal = java.util.Calendar.getInstance().apply { timeInMillis = session.endMillis }
                com.pulseapp.android.ui.ActivityPeriod(
                    startMinute = startCal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + startCal.get(java.util.Calendar.MINUTE),
                    endMinute = endCal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + endCal.get(java.util.Calendar.MINUTE)
                )
            }
            stressChart.setActivities(activityPeriods)

            // Recovery aproximado: 100% si FC reposo está en tu mejor rango conocido, baja si sube
           val recoveryScore = recoveryCalculator.calculate(
                summary.avgHrv, summary.restingHr, summary.sleepMinutes,
                sleepPlan.totalNeedMinutes, summary.sleepEfficiencyPct, baseline
            )
            recoveryRing.setValue(
                recoveryScore / 100f, "$recoveryScore%",
                "RECOVERY", ContextCompat.getColor(this@MainActivity, R.color.recovery_green)
            )

            val strainPct = (summary.strain / 21.0).toFloat()
            strainRing.setValue(
                strainPct, "%.1f".format(summary.strain),
                "STRAIN", ContextCompat.getColor(this@MainActivity, R.color.strain_blue)
            )

            val sleepTargetMinutes = 8 * 60 + 30 // objetivo aproximado ~8h30
            val sleepPct = summary.sleepMinutes?.let { (it.toFloat() / sleepTargetMinutes) } ?: 0f
            sleepRing.setValue(
                sleepPct,
                summary.sleepMinutes?.let { "${it / 60}h${it % 60}" } ?: "--",
                "SUEÑO", ContextCompat.getColor(this@MainActivity, R.color.sleep_blue)
            )

            val message = buildString {
                if (profile == null) {
                    append("⚠️ Sin perfil guardado, usando edad estimada de $age años.\n\n")
                }
                append("Lecturas analizadas: ${summary.totalReadings}\n\n")
                append("FC en reposo: ${summary.restingHr?.let { "$it ppm" } ?: "sin datos suficientes"}\n")
                append("HRV (RMSSD): ${summary.avgHrv?.let { "%.0f ms".format(it) } ?: "sin RR registrados"}\n")
                append("VO2max estimado: ${summary.vo2Max?.let { "%.1f".format(it) } ?: "--"}\n")
                append("Esfuerzo (0-21): ${"%.1f".format(summary.strain)}\n\n")
                if (summary.sleepMinutes != null) {
                    val hours = summary.sleepMinutes / 60
                    val mins = summary.sleepMinutes % 60
                    append("Descanso detectado: ${hours}h ${mins}min\n")
                    append("De ${summary.sleepStart} a ${summary.sleepEnd}\n")
                } else {
                    append("No se detectó ningún periodo de descanso largo (mínimo 90 min) todavía.\n")
                }
            }

            androidx.appcompat.app.AlertDialog.Builder(this@MainActivity)
                .setTitle("Resumen")
                .setMessage(message)
                .setPositiveButton("Cerrar", null)
                .show()
        }
    }
private fun toggleActivityRecording() {
        val start = activityStartMillis
        if (start == null) {
            activityStartMillis = System.currentTimeMillis()
            BleForegroundService.externalRecordingInProgress = true
            tabActionView.setBackgroundResource(R.drawable.bg_fab_recording)
            Toast.makeText(this, "Actividad iniciada", Toast.LENGTH_SHORT).show()
        } else {
            val end = System.currentTimeMillis()
            activityStartMillis = null
            BleForegroundService.externalRecordingInProgress = false
            tabActionView.setBackgroundResource(R.drawable.bg_fab_accent)

            val types = arrayOf("Fútbol", "Pádel", "Entrenamiento funcional", "Entrenamiento de fuerza", "Otro")
            androidx.appcompat.app.AlertDialog.Builder(this)
                .setTitle("¿Qué actividad ha sido?")
                .setItems(types) { _, index ->
                    saveActivitySession(start, end, types[index], autoDetected = false)
                }
                .setOnCancelListener {
                    // Si cancela, se guarda igualmente como "Sin clasificar" para no perder el registro
                    saveActivitySession(start, end, "Sin clasificar", autoDetected = false)
                }
                .show()
        }
    }

    private fun saveActivitySession(start: Long, end: Long, type: String, autoDetected: Boolean) {
        lifecycleScope.launch {
            val profile = db.userProfileDao().getOnce()
            val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
            val session = activityRecorder.summarize(
                file, start, end,
                ageYears = profile?.ageYears() ?: 30,
                weightKg = profile?.weightKg ?: 75f,
                sex = profile?.sex ?: "M",
                type = type,
                autoDetected = autoDetected
            )
            if (session == null) {
                Toast.makeText(this@MainActivity, "No hay suficientes datos de pulso en esta sesión", Toast.LENGTH_LONG).show()
                return@launch
            }
            db.activitySessionDao().save(session)

                        val durationMin = ((end - start) / 60000).toInt()
            val message = "Tipo: $type\n" +
                    "Duración: ${durationMin} min\n" +
                    "FC media: ${session.avgHr} bpm · FC máx: ${session.maxHr} bpm\n" +
                    "Strain: %.1f\n".format(session.strain) +
                    "Calorías: %.0f kcal\n\n".format(session.caloriesKcal) +
                    "Zona 0: ${session.minutesZone0} min\n" +
                    "Zona 1: ${session.minutesZone1} min\n" +
                    "Zona 2: ${session.minutesZone2} min\n" +
                    "Zona 3: ${session.minutesZone3} min\n" +
                    "Zona 4: ${session.minutesZone4} min\n" +
                    "Zona 5: ${session.minutesZone5} min"

            androidx.appcompat.app.AlertDialog.Builder(this@MainActivity)
                .setTitle("Actividad guardada")
                .setMessage(message)
                .setPositiveButton("Cerrar", null)
                .show()
        }
    }
    private fun exportCsv() {
        val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
        if (!file.exists()) {
            statusText.text = "Aún no hay datos guardados"
            return
        }
        val uri = androidx.core.content.FileProvider.getUriForFile(
            this, "$packageName.fileprovider", file
        )
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/csv"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, "Compartir hr_log.csv"))
    }

    private var scanDialog: androidx.appcompat.app.AlertDialog? = null

    private fun startScan() {
        devices.clear()
        adapter.clear()
        statusText.text = "Buscando dispositivos..."

        scanDialog = androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Dispositivos cercanos")
            .setAdapter(adapter) { _, position ->
                val device = devices[position]
                connectAndStartService(device.address)
                scanDialog?.dismiss()
            }
            .setNegativeButton("Cancelar", null)
            .show()

        val bluetoothManager = getSystemService(BluetoothManager::class.java)
        val scanner = bluetoothManager.adapter.bluetoothLeScanner

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val device = result.device
                if (devices.none { it.address == device.address }) {
                    devices.add(device)
                    val label = if (ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) {
                        device.name ?: device.address
                    } else {
                        device.address
                    }
                    runOnUiThread { adapter.add(label) }
                }
            }
        }

        try {
            scanner.startScan(callback)
            android.os.Handler(mainLooper).postDelayed({
                scanner.stopScan(callback)
            }, 8000)
        } catch (e: SecurityException) {
            statusText.text = "Faltan permisos de Bluetooth"
        }
    }

    private fun connectAndStartService(address: String) {
        val intent = Intent(this, BleForegroundService::class.java)
        intent.putExtra(BleForegroundService.EXTRA_DEVICE_ADDRESS, address)
        ContextCompat.startForegroundService(this, intent)
        statusText.text = "Conectando a $address..."
    }
}
