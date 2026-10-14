package com.pulseapp.android

import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.widget.ArrayAdapter
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.ActivitySession
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.ui.CircularRingView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

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
    private lateinit var stepsText: TextView
    private lateinit var dateText: TextView
    private lateinit var todayList: LinearLayout
    private val stressCalculator = StressCalculator()
    private val calorieCalculator = CalorieCalculator()
    private val recoveryCalculator = RecoveryCalculator()
    private val baselineProvider = BaselineProvider()
    private val sleepPlanner = SleepPlanner()
    private val activityRecorder = ActivityRecorder()
    private var activityStartMillis: Long? = null
    private lateinit var startActivityButton: TextView
    private lateinit var sleepNeedText: TextView
    private lateinit var sleepBedtimeText: TextView
    private lateinit var sleepBreakdownText: TextView
    private lateinit var caloriesText: TextView

    private val db by lazy { AppDatabase.getInstance(this) }
    private val esLocale = Locale("es", "ES")

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
        Formulas.init(this)
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
        stepsText = findViewById(R.id.stepsText)
        dateText = findViewById(R.id.dateText)
        todayList = findViewById(R.id.todayList)
        startActivityButton = findViewById(R.id.startActivityButton)

        dateText.text = SimpleDateFormat("EEEE, d 'de' MMMM", esLocale).format(Date())
            .replaceFirstChar { it.uppercase() }

        // Anillos vacíos hasta tener datos (en Inicio la etiqueta va debajo, fuera del anillo)
        recoveryRing.setValue(0f, "--", "", ContextCompat.getColor(this, R.color.recovery_green))
        strainRing.setValue(0f, "--", "", ContextCompat.getColor(this, R.color.strain_blue))
        sleepRing.setValue(0f, "--", "", ContextCompat.getColor(this, R.color.sleep_blue))

        val openRecovery = View.OnClickListener { startActivity(Intent(this, RecoveryDetailActivity::class.java)) }
        val openSleep = View.OnClickListener { startActivity(Intent(this, SleepDetailActivity::class.java)) }
        val openActivities = View.OnClickListener { startActivity(Intent(this, ActivitiesListActivity::class.java)) }
        val openProfile = View.OnClickListener { startActivity(Intent(this, ProfileActivity::class.java)) }

        recoveryRing.setOnClickListener(openRecovery)
        sleepRing.setOnClickListener(openSleep)
        strainRing.setOnClickListener(openActivities)
        findViewById<View>(R.id.healthCard).setOnClickListener { startActivity(Intent(this, HealthActivity::class.java)) }
        findViewById<View>(R.id.sleepPlanCard).setOnClickListener(openSleep)
        findViewById<View>(R.id.activitiesButton).setOnClickListener(openActivities)
        findViewById<View>(R.id.avatarButton).setOnClickListener(openProfile)
        stressCard.setOnClickListener {
            startActivity(Intent(this, StressDetailActivity::class.java))
        }

        Ui.setupTabBar(this, Ui.Tab.HOME)
        findViewById<View>(R.id.prevDayButton).setOnClickListener {
            Toast.makeText(this, "Ver días anteriores: próximamente", Toast.LENGTH_SHORT).show()
        }

        rowExport.setOnClickListener { exportCsv() }
        findViewById<View>(R.id.rowWhoopExperimental).setOnClickListener {
            startActivity(Intent(this, WhoopExperimentalActivity::class.java))
        }
        rowSummary.setOnClickListener { showSummary(showDialog = true) }
        rowProfile.setOnClickListener(openProfile)
        startActivityButton.setOnClickListener { toggleActivityRecording() }

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
    }

    override fun onResume() {
        super.onResume()
        showSummary(showDialog = false)
    }

    private fun hm(minutes: Int): String = "%d:%02d".format(minutes / 60, minutes % 60)
    private fun comma(value: Double, decimals: Int = 1): String =
        "%.${decimals}f".format(Locale.US, value).replace('.', ',')

    private fun showSummary(showDialog: Boolean) {
        lifecycleScope.launch {
            val profile = db.userProfileDao().getOnce()
            val baseline = baselineProvider.compute(db)
            if (profile == null) {
                statusText.text = "Rellena \"Sobre mí\" para un cálculo preciso"
            }
            val age = profile?.ageYears() ?: 30 // valor por defecto si aún no hay perfil
            val metricsCalculator = MetricsCalculator(ageYears = age, male = profile?.sex != "F")
            val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
            val summary = withContext(Dispatchers.IO) { metricsCalculator.analyze(file) }
            minHrText.text = summary.restingHr?.let { "$it" } ?: "--"
            avgHrText.text = summary.avgHr?.let { "$it" } ?: "--"

            // VO2max: fijo, solo se recalcula los martes (o si nunca se ha calculado)
            val today = Calendar.getInstance()
            val isTuesday = today.get(Calendar.DAY_OF_WEEK) == Calendar.TUESDAY
            val todayKey = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(today.time)

            val stableVo2Max: Double? = if (profile != null && (isTuesday || profile.vo2Max == null) && summary.vo2Max != null) {
                db.userProfileDao().save(profile.copy(vo2Max = summary.vo2Max, vo2MaxUpdatedDate = todayKey))
                summary.vo2Max
            } else {
                profile?.vo2Max ?: summary.vo2Max
            }
            vo2MaxText.text = stableVo2Max?.let { "%.0f".format(it) } ?: "--"
            respiratoryRateText.text = summary.respiratoryRate?.let { comma(it) } ?: "--"

            val todayStartMillis = (today.clone() as Calendar).apply {
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
            }.timeInMillis
            val todaySessions = db.activitySessionDao().getAll().filter { it.startMillis >= todayStartMillis }

            if (profile != null) {
                val elapsedMinutesToday = today.get(Calendar.HOUR_OF_DAY) * 60.0 + today.get(Calendar.MINUTE)
                val activityKcalToday = todaySessions.sumOf { it.caloriesKcal }
                val kcal = calorieCalculator.estimateDailyTotal(
                    elapsedMinutesToday, activityKcalToday, age, profile.weightKg, profile.heightCm, profile.sex
                )
                caloriesText.text = NumberFormat.getIntegerInstance(esLocale).format(kcal.toLong())
            } else {
                caloriesText.text = "--"
            }

            // Pasos de hoy: en directo si el acelerómetro está activo, si no desde motion_minutes.csv
            val steps = withContext(Dispatchers.IO) { Ui.stepsToday(this@MainActivity) }
            stepsText.text = if (steps > 0) NumberFormat.getIntegerInstance(esLocale).format(steps) else "--"

            val stressSummary = withContext(Dispatchers.IO) { stressCalculator.analyze(file, summary.restingHr, baseline) }
            val sleepPlan = sleepPlanner.computeTonightPlan(db, summary.strain)
            sleepNeedText.text = hm(sleepPlan.totalNeedMinutes)
            sleepBedtimeText.text = sleepPlan.suggestedBedtime?.let { "Acuéstate a las $it para despertar a las 7:30" }
                ?: "Acuéstate a las --"
            sleepBreakdownText.text = "Base %s, esfuerzo +%s, deuda +%s".format(
                hm(sleepPlan.baselineMinutes), hm(sleepPlan.strainAdjustmentMinutes), hm(sleepPlan.debtAdjustmentMinutes)
            )

            stressScoreText.text = stressSummary.currentScore?.let { comma(it.toDouble()) } ?: "--"
            stressLevelText.text = stressSummary.level
            stressLevelText.setTextColor(
                ContextCompat.getColor(this@MainActivity, when (stressSummary.level) {
                    "ALTO" -> R.color.alert_amber
                    "MEDIO" -> R.color.recovery_green
                    else -> R.color.strain_blue
                })
            )
            val updated = stressSummary.lastUpdateMinute?.let {
                "Última actualización a las %02d:%02d".format(it / 60, it % 60)
            } ?: "Sin datos todavía"
            stressUpdatedText.text = if (baseline == null) {
                "$updated\nSin línea base aún (${BaselineProvider.MIN_DAYS_REQUIRED}+ días)"
            } else updated
            stressChart.setSeries(stressSummary.series)
            stressChart.setSleepWindow(summary.sleepStartMinuteOfDay, summary.sleepEndMinuteOfDay)
            stressChart.setActivities(todaySessions.map { session ->
                val s = Calendar.getInstance().apply { timeInMillis = session.startMillis }
                val e = Calendar.getInstance().apply { timeInMillis = session.endMillis }
                com.pulseapp.android.ui.ActivityPeriod(
                    startMinute = s.get(Calendar.HOUR_OF_DAY) * 60 + s.get(Calendar.MINUTE),
                    endMinute = e.get(Calendar.HOUR_OF_DAY) * 60 + e.get(Calendar.MINUTE)
                )
            })

            // Anillos
            val recoveryScore = recoveryCalculator.calculate(
                summary.avgHrv, summary.restingHr, summary.sleepMinutes,
                sleepPlan.totalNeedMinutes, summary.sleepEfficiencyPct, baseline, summary.respiratoryRate
            )
            val recoveryColor = when {
                recoveryScore >= 67 -> R.color.recovery_green
                recoveryScore >= 34 -> R.color.alert_amber
                else -> R.color.alert_red
            }
            recoveryRing.setValue(
                recoveryScore / 100f, "$recoveryScore%", "",
                ContextCompat.getColor(this@MainActivity, recoveryColor)
            )

            strainRing.setValue(
                (summary.strain / 21.0).toFloat(), comma(summary.strain), "",
                ContextCompat.getColor(this@MainActivity, R.color.strain_blue)
            )

            // Sueño como WHOOP: horas vs necesidad + eficiencia + regularidad (Formulas.sleepScore)
            val consistency = Formulas.sleepConsistency(
                db.dailyMetricsDao().getLastDays(7).mapNotNull { it.sleepStartMinuteOfDay }
            )
            val sleepPerf = summary.sleepMinutes?.let {
                val hoursVsNeed = (it * 100 / sleepPlan.totalNeedMinutes.coerceAtLeast(1)).coerceAtMost(100)
                Formulas.sleepScore(hoursVsNeed, summary.sleepEfficiencyPct, consistency)
            }
            sleepRing.setValue(
                (sleepPerf ?: 0) / 100f,
                sleepPerf?.let { "$it%" } ?: "--", "",
                ContextCompat.getColor(this@MainActivity, R.color.sleep_blue)
            )

            fillTodayList(summary, todaySessions)

            if (showDialog) {
                val message = buildString {
                    if (profile == null) {
                        append("Sin perfil guardado, usando edad estimada de $age años.\n\n")
                    }
                    append("Lecturas analizadas: ${summary.totalReadings}\n\n")
                    append("FC en reposo: ${summary.restingHr?.let { "$it lpm" } ?: "sin datos suficientes"}\n")
                    append("VFC (RMSSD): ${summary.avgHrv?.let { "%.0f ms".format(it) } ?: "sin RR registrados"}\n")
                    append("VO2máx estimado: ${summary.vo2Max?.let { comma(it) } ?: "--"}\n")
                    append("Esfuerzo (0-21): ${comma(summary.strain)}\n\n")
                    if (summary.sleepMinutes != null) {
                        append("Dormido: ${hm(summary.sleepMinutes)}\n")
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
    }

    /** Lista "Mi día": el sueño de anoche y las actividades de hoy, estilo lista agrupada de iOS. */
    private fun fillTodayList(summary: DailySummary, sessions: List<ActivitySession>) {
        todayList.removeAllViews()
        val inflater = LayoutInflater.from(this)
        val timeFmt = SimpleDateFormat("HH:mm", esLocale)
        var rows = 0

        fun addDivider() {
            val d = View(this)
            val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, (1 * resources.displayMetrics.density).toInt().coerceAtLeast(1))
            lp.marginStart = (64 * resources.displayMetrics.density).toInt()
            d.layoutParams = lp
            d.setBackgroundColor(ContextCompat.getColor(this, R.color.hairline))
            todayList.addView(d)
        }

        val slept = summary.sleepMinutes
        val start = summary.sleepStartMinuteOfDay
        val end = summary.sleepEndMinuteOfDay
        if (slept != null && start != null && end != null) {
            val row = inflater.inflate(R.layout.item_day_activity, todayList, false)
            row.findViewById<ImageView>(R.id.itemIcon).apply {
                setBackgroundResource(R.drawable.bg_icon_sleep)
                setImageResource(R.drawable.ic_moon)
                setColorFilter(ContextCompat.getColor(this@MainActivity, R.color.sleep_blue))
            }
            row.findViewById<TextView>(R.id.itemName).text = "Sueño"
            row.findViewById<TextView>(R.id.itemTime).text =
                "%02d:%02d – %02d:%02d".format(start / 60, start % 60, end / 60, end % 60)
            row.findViewById<TextView>(R.id.itemValue).apply {
                text = hm(slept)
                setTextColor(ContextCompat.getColor(this@MainActivity, R.color.sleep_blue))
            }
            row.findViewById<TextView>(R.id.itemSub).text = "dormido"
            row.setOnClickListener { startActivity(Intent(this, SleepDetailActivity::class.java)) }
            todayList.addView(row)
            rows++
        }

        sessions.sortedBy { it.startMillis }.forEach { session ->
            if (rows > 0) addDivider()
            val row = inflater.inflate(R.layout.item_day_activity, todayList, false)
            row.findViewById<ImageView>(R.id.itemIcon).setColorFilter(ContextCompat.getColor(this, R.color.strain_blue))
            row.findViewById<TextView>(R.id.itemName).text = session.type
            val range = "${timeFmt.format(Date(session.startMillis))} – ${timeFmt.format(Date(session.endMillis))}"
            row.findViewById<TextView>(R.id.itemTime).text = if (session.autoDetected) "Detectada · $range" else range
            row.findViewById<TextView>(R.id.itemValue).apply {
                text = comma(session.strain)
                setTextColor(ContextCompat.getColor(this@MainActivity, R.color.strain_blue))
            }
            row.findViewById<TextView>(R.id.itemSub).text = "%.0f kcal".format(session.caloriesKcal)
            row.setOnClickListener {
                startActivity(Intent(this, EditSessionActivity::class.java).putExtra(EditSessionActivity.EXTRA_SESSION_ID, session.id))
            }
            todayList.addView(row)
            rows++
        }

        if (rows == 0) {
            val empty = TextView(this).apply {
                text = "Aún no hay actividades hoy. Pulsa «Iniciar actividad» para grabar una."
                setTextColor(ContextCompat.getColor(this@MainActivity, R.color.text_secondary))
                textSize = 13f
                val pad = (16 * resources.displayMetrics.density).toInt()
                setPadding(pad, pad, pad, pad)
            }
            todayList.addView(empty)
        }
    }

    private fun toggleActivityRecording() {
        val start = activityStartMillis
        if (start == null) {
            activityStartMillis = System.currentTimeMillis()
            BleForegroundService.externalRecordingInProgress = true
            startActivityButton.setBackgroundResource(R.drawable.bg_button_recording)
            startActivityButton.setTextColor(ContextCompat.getColor(this, R.color.text_primary))
            startActivityButton.text = "Detener actividad"
            Toast.makeText(this, "Actividad iniciada", Toast.LENGTH_SHORT).show()
        } else {
            val end = System.currentTimeMillis()
            activityStartMillis = null
            BleForegroundService.externalRecordingInProgress = false
            startActivityButton.setBackgroundResource(R.drawable.bg_button_primary)
            startActivityButton.setTextColor(ContextCompat.getColor(this, R.color.text_on_accent))
            startActivityButton.text = "Iniciar actividad"

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
                autoDetected = autoDetected,
                restingHr = baselineProvider.compute(db)?.avgRestingHr?.toInt()
            )
            if (session == null) {
                Toast.makeText(this@MainActivity, "No hay suficientes datos de pulso en esta sesión", Toast.LENGTH_LONG).show()
                return@launch
            }
            Formulas.updateObservedHrMax(this@MainActivity, session.maxHr)
            db.activitySessionDao().save(session)

            val durationMin = ((end - start) / 60000).toInt()
            val message = "Tipo: $type\n" +
                    "Duración: ${durationMin} min\n" +
                    "FC media: ${session.avgHr} lpm · FC máx: ${session.maxHr} lpm\n" +
                    "Esfuerzo: ${comma(session.strain)}\n" +
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
            showSummary(showDialog = false)
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
