package com.pulseapp.android

import android.Manifest
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.ui.CircularRingView
import com.pulseapp.android.ui.StrainRecoveryChartView
import com.pulseapp.android.ui.StressDayChartView
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.time.format.TextStyle
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * Inicio con el aspecto de la app de WHOOP (17/10): cabecera con racha y día, tres anillos, monitores de salud y estrés,
 * "Mi día" (perspectiva, actividades, sueño de esta noche) y "Mi panel de control". Los números salen de [HomeDataLoader].
 */
class MainActivity : AppCompatActivity() {

    private val db by lazy { AppDatabase.getInstance(this) }
    private val esLocale = Locale("es", "ES")
    private val activityRecorder = ActivityRecorder()
    private val baselineProvider = BaselineProvider()

    private lateinit var sleepRing: CircularRingView
    private lateinit var recoveryRing: CircularRingView
    private lateinit var strainRing: CircularRingView
    private lateinit var miniSleep: CircularRingView
    private lateinit var miniRecovery: CircularRingView
    private lateinit var miniStrain: CircularRingView
    private lateinit var statusText: TextView
    private lateinit var connectionNote: TextView
    private lateinit var todayList: LinearLayout
    private lateinit var panelList: LinearLayout
    private lateinit var stressChartCard: View
    private lateinit var strainRecoveryCard: View

    private var dayOffset = 0
    private var activityStartMillis: Long? = null
    private var lastData: HomeData? = null
    private var loading = false

    private val types = arrayOf("Fútbol", "Pádel", "Pickleball", "Entrenamiento funcional", "Entrenamiento de fuerza", "Otro")

    private val requiredPermissions: Array<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.POST_NOTIFICATIONS)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { _ ->
        val btOk = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        if (btOk) {
            if (WhoopBackgroundService.findBondedWhoop(this) != null && !WhoopBackgroundService.isRunning) WhoopBackgroundService.start(this)
        } else {
            statusText.text = "Permisos denegados: necesarios para Bluetooth"
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Formulas.init(this)
        setContentView(R.layout.activity_main)
        window.statusBarColor = Ui.color(this, R.color.w_bg_top)

        sleepRing = findViewById(R.id.sleepRing)
        recoveryRing = findViewById(R.id.recoveryRing)
        strainRing = findViewById(R.id.strainRing)
        miniSleep = findViewById(R.id.miniSleepRing)
        miniRecovery = findViewById(R.id.miniRecoveryRing)
        miniStrain = findViewById(R.id.miniStrainRing)
        statusText = findViewById(R.id.statusText)
        connectionNote = findViewById(R.id.connectionNote)
        todayList = findViewById(R.id.todayList)
        panelList = findViewById(R.id.panelList)
        stressChartCard = findViewById(R.id.stressChartCard)
        strainRecoveryCard = findViewById(R.id.strainRecoveryCard)

        // Anillos como los de WHOOP: trazo fino, número blanco grande con "%" del mismo color
        val track = Ui.color(this, R.color.w_track)
        listOf(sleepRing, recoveryRing, strainRing).forEach {
            it.strokeRatio = 0.075f; it.numberRatio = 0.30f; it.suffixRatio = 0.56f; it.suffixSameColor = true; it.setTrackColor(track)
        }
        listOf(miniSleep, miniRecovery, miniStrain).forEach { it.strokeRatio = 0.14f; it.setTrackColor(track) }
        sleepRing.setValue(0f, "--", "", Ui.color(this, R.color.w_ring_sleep))
        recoveryRing.setValue(0f, "--", "", Ui.color(this, R.color.w_recovery_high))
        strainRing.setValue(0f, "--", "", Ui.color(this, R.color.strain_blue))

        val openRecovery = View.OnClickListener { startActivity(Intent(this, RecoveryDetailActivity::class.java)) }
        val openSleep = View.OnClickListener { startActivity(Intent(this, SleepDetailActivity::class.java)) }
        val openActivities = View.OnClickListener { startActivity(Intent(this, ActivitiesListActivity::class.java)) }
        val openProfile = View.OnClickListener { startActivity(Intent(this, ProfileActivity::class.java)) }
        val openWhoop = View.OnClickListener { startActivity(Intent(this, WhoopExperimentalActivity::class.java)) }
        val openStress = View.OnClickListener { startActivity(Intent(this, StressDetailActivity::class.java)) }

        findViewById<View>(R.id.sleepRingBox).setOnClickListener(openSleep)
        findViewById<View>(R.id.recoveryRingBox).setOnClickListener(openRecovery)
        findViewById<View>(R.id.strainRingBox).setOnClickListener(openActivities)
        findViewById<View>(R.id.miniSleep).setOnClickListener(openSleep)
        findViewById<View>(R.id.miniRecovery).setOnClickListener(openRecovery)
        findViewById<View>(R.id.miniStrain).setOnClickListener(openActivities)
        findViewById<View>(R.id.avatarButton).setOnClickListener(openProfile)
        findViewById<View>(R.id.bandButton).setOnClickListener(openWhoop)
        findViewById<View>(R.id.healthCard).setOnClickListener {
            startActivity(Intent(this, HealthActivity::class.java).putExtra(HealthActivity.EXTRA_FROM_HOME, true))
        }
        findViewById<View>(R.id.stressCard).setOnClickListener(openStress)
        stressChartCard.setOnClickListener(openStress)
        findViewById<View>(R.id.expandButton).setOnClickListener(openActivities)
        findViewById<View>(R.id.tonightHeader).setOnClickListener(openSleep)
        findViewById<View>(R.id.insightCard).setOnClickListener { showInsight() }
        findViewById<View>(R.id.plusButton).setOnClickListener { showPlusMenu(it as ImageView) }
        findViewById<View>(R.id.addActivityButton).setOnClickListener { addActivityFlow() }
        findViewById<View>(R.id.startActivityButton).setOnClickListener { toggleActivityRecording() }
        findViewById<View>(R.id.editWakeButton).setOnClickListener { editWakeTime() }
        findViewById<View>(R.id.personalizeButton).setOnClickListener { personalizePanel() }
        findViewById<View>(R.id.strainRecoveryInfo).setOnClickListener {
            androidx.appcompat.app.AlertDialog.Builder(this)
                .setTitle("Esfuerzo y recuperación")
                .setMessage("En azul, el esfuerzo de cada día (0–21, escala de la izquierda). En círculos, la recuperación de esa mañana " +
                    "(0–100 %, a la derecha): verde ≥ 67 %, amarillo 34–66 %, rojo < 34 %.")
                .setPositiveButton("Cerrar", null)
                .show()
        }
        findViewById<View>(R.id.streakPill).setOnClickListener {
            Toast.makeText(this, "Días seguidos llevando la pulsera", Toast.LENGTH_SHORT).show()
        }

        findViewById<View>(R.id.prevDayButton).setOnClickListener { if (dayOffset > -60) { dayOffset--; refresh() } }
        findViewById<View>(R.id.nextDayButton).setOnClickListener { if (dayOffset < 0) { dayOffset++; refresh() } }
        findViewById<View>(R.id.dayLabel).setOnClickListener { if (dayOffset != 0) { dayOffset = 0; refresh() } }

        findViewById<View>(R.id.rowExport).setOnClickListener { exportCsv() }
        findViewById<View>(R.id.rowWhoopExperimental).setOnClickListener(openWhoop)
        findViewById<View>(R.id.rowScan).setOnClickListener(openWhoop)
        findViewById<View>(R.id.rowSummary).setOnClickListener { showSummaryDialog() }
        findViewById<View>(R.id.rowProfile).setOnClickListener(openProfile)

        setupStickyHeader()
        Ui.setupTabBar(this, Ui.Tab.HOME)

        // La conexión es la WHOOP vinculada (modo propietario). El modo Bluetooth estándar ya no se usa.
        stopService(Intent(this, BleForegroundService::class.java))
        WhoopBackgroundService.onActivitySaved = { message ->
            runOnUiThread { Toast.makeText(this, message, Toast.LENGTH_LONG).show() }
        }
        // Si hay una WHOOP vinculada, se conecta sola al abrir la app (como la app de WHOOP)
        if (WhoopBackgroundService.findBondedWhoop(this) != null) {
            if (requiredPermissions.all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }) {
                if (!WhoopBackgroundService.isRunning) WhoopBackgroundService.start(this)
            } else {
                permissionLauncher.launch(requiredPermissions)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        restoreActivityButton()
        checkSetupComplete()
        refresh()
        liveHandler.post(liveTicker)
    }

    override fun onPause() {
        super.onPause()
        liveHandler.removeCallbacks(liveTicker)
    }

    // ---------------------------------------------------------------- directo

    private val liveHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var lastRefresh = 0L

    /** Estado de la pulsera cada 2 s (punto verde/ámbar/gris); los datos se recalculan cada minuto. */
    private val liveTicker = object : Runnable {
        override fun run() {
            val now = System.currentTimeMillis()
            val bonded = WhoopBackgroundService.findBondedWhoop(this@MainActivity) != null
            val live = WhoopBackgroundService.lastBpmTime > now - 15_000
            val state = when {
                !bonded -> "Vincula tu WHOOP"
                !WhoopBackgroundService.isRunning -> "WHOOP desconectada"
                else -> WhoopBackgroundService.state
            }
            statusText.text = state
            val dotColor = when {
                live -> R.color.w_mint
                bonded && WhoopBackgroundService.isRunning -> R.color.alert_amber
                else -> R.color.text_secondary
            }
            (findViewById<View>(R.id.bandDot).background.mutate() as? android.graphics.drawable.GradientDrawable)
                ?.setColor(Ui.color(this@MainActivity, dotColor))
            connectionNote.visibility = if (live) View.GONE else View.VISIBLE
            connectionNote.text = when {
                !bonded -> "Toca la pulsera de arriba a la derecha para vincular tu WHOOP"
                !WhoopBackgroundService.isRunning -> "WHOOP desconectada · toca la pulsera para conectar"
                else -> "Esperando pulso de la WHOOP…"
            }
            if (dayOffset == 0 && now - lastRefresh > 60_000) refresh()
            liveHandler.postDelayed(this, 2000)
        }
    }

    // ---------------------------------------------------------------- datos

    private fun refresh() {
        if (loading) return
        loading = true
        lastRefresh = System.currentTimeMillis()
        updateDayLabel()
        val offset = dayOffset
        lifecycleScope.launch {
            try {
                val data = HomeDataLoader(this@MainActivity).load(offset)
                if (offset == dayOffset) render(data)
            } catch (e: Exception) {
                Toast.makeText(this@MainActivity, "Error al calcular Inicio: ${e.message}", Toast.LENGTH_LONG).show()
            } finally {
                loading = false
                if (offset != dayOffset) refresh()
            }
        }
    }

    private fun updateDayLabel() {
        val label = findViewById<TextView>(R.id.dayLabel)
        val date = java.time.LocalDate.now().plusDays(dayOffset.toLong())
        label.text = when (dayOffset) {
            0 -> "HOY"
            -1 -> "AYER"
            else -> date.dayOfWeek.getDisplayName(TextStyle.SHORT, esLocale).uppercase(esLocale).trimEnd('.') + ". " + date.dayOfMonth
        }
        findViewById<View>(R.id.nextDayButton).alpha = if (dayOffset < 0) 1f else 0.35f
    }

    private fun render(d: HomeData) {
        lastData = d
        val ctx = this
        findViewById<TextView>(R.id.streakText).text = d.streak.toString()

        // Anillos
        val day = d.day
        val sleepColor = Ui.color(ctx, R.color.w_ring_sleep)
        val recColor = Ui.color(ctx, day.recovery?.let { W.recoveryColor(it) } ?: R.color.w_recovery_high)
        val strainColor = Ui.color(ctx, R.color.strain_blue)
        sleepRing.setValue((day.sleepScore ?: 0) / 100f, day.sleepScore?.let { "$it%" } ?: "--", "", sleepColor)
        recoveryRing.setValue((day.recovery ?: 0) / 100f, day.recovery?.let { "$it%" } ?: "--", "", recColor)
        strainRing.setValue(((day.strain ?: 0.0) / 21.0).toFloat(), day.strain?.let { Ui.comma(it) } ?: "--", "", strainColor)
        miniSleep.setValue((day.sleepScore ?: 0) / 100f, "", "", sleepColor)
        miniRecovery.setValue((day.recovery ?: 0) / 100f, "", "", recColor)
        miniStrain.setValue(((day.strain ?: 0.0) / 21.0).toFloat(), "", "", strainColor)

        // Monitor de salud
        val healthText = findViewById<TextView>(R.id.healthStatusText)
        val healthIcon = findViewById<ImageView>(R.id.healthIcon)
        val healthBox = findViewById<View>(R.id.healthIconBox)
        val healthCount = findViewById<TextView>(R.id.healthCountText)
        when {
            d.healthTotal == 0 -> {
                healthText.text = "CALIBRANDO"
                healthText.setTextColor(Ui.color(ctx, R.color.text_primary))
                healthIcon.setImageResource(R.drawable.ic_pulse)
                healthIcon.setColorFilter(Ui.color(ctx, R.color.text_secondary))
                healthBox.background = W.rounded(ctx, R.color.w_row, 8f)
                healthCount.text = "Necesita ${BaselineProvider.MIN_DAYS_REQUIRED} noches"
            }
            d.healthOk == d.healthTotal -> {
                healthText.text = "DENTRO\nDEL RANGO"
                healthText.setTextColor(Ui.color(ctx, R.color.w_mint))
                healthIcon.setImageResource(R.drawable.ic_check)
                healthIcon.setColorFilter(Ui.color(ctx, R.color.w_mint))
                healthBox.background = W.rounded(ctx, R.color.w_mint_bg, 8f)
                healthCount.text = "${d.healthOk}/${d.healthTotal} métricas"
            }
            else -> {
                healthText.text = "FUERA\nDEL RANGO"
                healthText.setTextColor(Ui.color(ctx, R.color.alert_amber))
                healthIcon.setImageResource(R.drawable.ic_info)
                healthIcon.setColorFilter(Ui.color(ctx, R.color.alert_amber))
                healthBox.background = W.rounded(ctx, R.color.w_stress_high_dim, 8f)
                healthCount.text = "${d.healthOk}/${d.healthTotal} métricas"
            }
        }

        // Monitor de estrés (tarjeta pequeña y tarjeta con gráfica)
        val levelColor = W.stressColor(d.stressLevel)
        val score = d.stressScore?.let { Ui.comma(it.toDouble()) } ?: "--"
        val time = d.stressMinute?.let { "%02d:%02d".format(it / 60, it % 60) } ?: ""
        findViewById<TextView>(R.id.stressScoreBox).apply {
            text = score
            setTextColor(Ui.color(ctx, levelColor))
            background = W.rounded(ctx, when (d.stressLevel) {
                "ALTO" -> R.color.w_stress_high_dim
                "MEDIO" -> R.color.w_mint_bg
                else -> R.color.w_low_blue_bg
            }, 8f)
        }
        findViewById<TextView>(R.id.stressLevelText).apply {
            text = if (d.stressScore != null) d.stressLevel else "SIN DATOS"
            setTextColor(Ui.color(ctx, if (d.stressScore != null) levelColor else R.color.text_secondary))
        }
        findViewById<TextView>(R.id.stressTimeText).text = time
        stressChartCard.findViewById<TextView>(R.id.stressUpdatedText).text =
            if (d.stressScore == null) "Sin datos todavía" else "Última actualización a la(s) $time"
        stressChartCard.findViewById<TextView>(R.id.stressChartLevel).apply {
            text = if (d.stressScore != null) d.stressLevel else ""
            setTextColor(Ui.color(ctx, levelColor))
        }
        stressChartCard.findViewById<TextView>(R.id.stressChartScore).text = score
        stressChartCard.findViewById<StressDayChartView>(R.id.stressDayChart)
            .setData(d.stressSeries, d.stressFrom, d.stressTo, d.sleepFromMillis, d.sleepToMillis, d.isToday)

        // Mi día
        findViewById<TextView>(R.id.activitiesTitle).text = if (d.isToday) "ACTIVIDADES DE HOY" else "ACTIVIDADES DEL DÍA"
        findViewById<View>(R.id.startActivityButton).visibility = if (d.isToday) View.VISIBLE else View.GONE
        findViewById<View>(R.id.tonightCard).visibility = if (d.isToday) View.VISIBLE else View.GONE
        fillActivities(d)
        findViewById<TextView>(R.id.bedtimeText).text = d.bedtime ?: "--:--"
        findViewById<TextView>(R.id.wakeText).text = "%02d:%02d".format(d.wakeMinute / 60, d.wakeMinute % 60)

        // Panel
        fillPanel(d)
    }

    private fun fillActivities(d: HomeData) {
        todayList.removeAllViews()
        val timeFmt = SimpleDateFormat("H:mm", esLocale)
        val day = d.day
        val from = d.sleepFromMillis
        val to = d.sleepToMillis
        if (day.sleepMinutes != null && from != null && to != null) {
            val row = W.activityRow(this, R.color.w_ring_sleep, R.drawable.ic_moon_filled, Ui.hm(day.sleepMinutes), "Sueño",
                timeFmt.format(Date(from)), timeFmt.format(Date(to)))
            row.setOnClickListener { startActivity(Intent(this, SleepDetailActivity::class.java)) }
            todayList.addView(row)
        }
        d.sessions.forEach { s ->
            val row = W.activityRow(this, R.color.strain_blue, W.sportIcon(s.type), Ui.comma(s.strain), s.type,
                timeFmt.format(Date(s.startMillis)), timeFmt.format(Date(s.endMillis)))
            row.setOnClickListener {
                startActivity(Intent(this, ActivityDetailActivity::class.java).putExtra(ActivityDetailActivity.EXTRA_SESSION_ID, s.id))
            }
            todayList.addView(row)
        }
        if (todayList.childCount == 0) {
            todayList.addView(W.body(this, if (d.isToday) "Aún no hay actividades hoy." else "No hay actividades ese día.", 14f).apply {
                setPadding(0, 0, 0, Ui.dp(this@MainActivity, 12f))
            })
        }
    }

    private fun fillPanel(d: HomeData) {
        panelList.removeAllViews()
        val hidden = PanelKeys.hidden(this)
        val rows = d.panel.associateBy { it.key }
        PanelKeys.ALL.forEach { (key, _) ->
            if (key in hidden) return@forEach
            when (key) {
                PanelKeys.STRESS -> addCard(stressChartCard)
                PanelKeys.STRAIN_RECOVERY -> {
                    val chart = strainRecoveryCard.findViewById<StrainRecoveryChartView>(R.id.strainRecoveryChart)
                    chart.setDays(d.week.map {
                        StrainRecoveryChartView.Day(
                            it.date.dayOfWeek.getDisplayName(TextStyle.SHORT, esLocale).lowercase(esLocale).trimEnd('.') + ".",
                            it.date.dayOfMonth.toString(), it.strain, it.recovery
                        )
                    })
                    addCard(strainRecoveryCard)
                }
                else -> rows[key]?.let { panelList.addView(W.panelRow(this, it)) }
            }
        }
    }

    private fun addCard(card: View) {
        (card.parent as? ViewGroup)?.removeView(card)
        card.layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            bottomMargin = Ui.dp(this@MainActivity, 12f)
        }
        panelList.addView(card)
    }

    // ---------------------------------------------------------------- cabecera fija

    private fun setupStickyHeader() {
        val scroll = findViewById<ScrollView>(R.id.mainScroll)
        val sticky = findViewById<View>(R.id.stickyHeader)
        val rings = findViewById<View>(R.id.ringsRow)
        scroll.viewTreeObserver.addOnScrollChangedListener {
            val show = scroll.scrollY > rings.top + rings.height - Ui.dp(this, 20f)
            if (show && sticky.visibility != View.VISIBLE) {
                sticky.visibility = View.VISIBLE
                sticky.animate().alpha(1f).setDuration(150).start()
            } else if (!show && sticky.visibility == View.VISIBLE && sticky.alpha == 1f) {
                sticky.animate().alpha(0f).setDuration(120).withEndAction { sticky.visibility = View.GONE }.start()
            }
        }
    }

    // ---------------------------------------------------------------- acciones

    private fun showInsight() {
        val d = lastData ?: return
        val title = if (d.isToday) "Perspectiva diaria" else "Perspectiva del ${d.date.dayOfMonth}/${d.date.monthValue}"
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(d.insight)
            .setPositiveButton("Cerrar", null)
            .show()
    }

    /** Menú del "+" (como WHOOP): agregar o iniciar actividad. El botón se convierte en una X mientras está abierto. */
    private fun showPlusMenu(anchor: ImageView) {
        val ctx = this
        val menu = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundResource(R.drawable.bg_popup_w)
            val p = Ui.dp(ctx, 10f)
            setPadding(p, p, p, p)
            elevation = Ui.dp(ctx, 12f).toFloat()
        }
        val popup = PopupWindow(menu, Ui.dp(ctx, 290f), ViewGroup.LayoutParams.WRAP_CONTENT, true)
        fun item(icon: Int, text: String, action: () -> Unit) {
            menu.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(Ui.dp(ctx, 14f), Ui.dp(ctx, 18f), Ui.dp(ctx, 14f), Ui.dp(ctx, 18f))
                background = ContextCompat.getDrawable(ctx, android.R.drawable.list_selector_background)?.mutate()?.apply { alpha = 40 }
                isClickable = true
                addView(W.icon(ctx, icon, 26f, R.color.text_primary))
                addView(W.title(ctx, text, 15.5f).apply { setPadding(Ui.dp(ctx, 18f), 0, 0, 0) })
                setOnClickListener { popup.dismiss(); action() }
            })
        }
        item(R.drawable.ic_plus, "Agregar actividad") { addActivityFlow() }
        if (dayOffset == 0) {
            item(R.drawable.ic_stopwatch, if (activityStartMillis == null) "Iniciar actividad" else "Detener actividad") { toggleActivityRecording() }
        }
        item(R.drawable.ic_band, "Mi WHOOP") { startActivity(Intent(ctx, WhoopExperimentalActivity::class.java)) }
        popup.setBackgroundDrawable(ColorDrawable(android.graphics.Color.TRANSPARENT))
        popup.elevation = Ui.dp(ctx, 12f).toFloat()
        anchor.setImageResource(R.drawable.ic_close)
        anchor.setBackgroundResource(R.drawable.bg_plus_dark)
        anchor.setColorFilter(Ui.color(ctx, R.color.text_primary))
        popup.setOnDismissListener {
            anchor.setImageResource(R.drawable.ic_plus)
            anchor.setBackgroundResource(R.drawable.bg_plus_white)
            anchor.setColorFilter(android.graphics.Color.parseColor("#FF0F1519"))
        }
        // Se abre ENCIMA del botón, alineado a su derecha (si no cabe, debajo)
        val width = Ui.dp(ctx, 290f)
        menu.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
        val loc = IntArray(2)
        anchor.getLocationInWindow(loc)
        val x = loc[0] + anchor.width - width
        var y = loc[1] - menu.measuredHeight - Ui.dp(ctx, 10f)
        if (y < Ui.dp(ctx, 40f)) y = loc[1] + anchor.height + Ui.dp(ctx, 10f)
        popup.showAtLocation(anchor, Gravity.NO_GRAVITY, x, y)
    }

    /** Agregar actividad a mano: tipo → día → hora de inicio → hora de fin (se calcula con el pulso guardado). */
    private fun addActivityFlow() {
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("¿Qué actividad?")
            .setItems(types) { _, index ->
                val type = types[index]
                val cal = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, dayOffset) }
                DatePickerDialog(this, { _, y, m, dd ->
                    cal.set(y, m, dd)
                    TimePickerDialog(this, { _, h1, m1 ->
                        val start = (cal.clone() as Calendar).apply {
                            set(Calendar.HOUR_OF_DAY, h1); set(Calendar.MINUTE, m1); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                        }
                        TimePickerDialog(this, { _, h2, m2 ->
                            val end = (start.clone() as Calendar).apply { set(Calendar.HOUR_OF_DAY, h2); set(Calendar.MINUTE, m2) }
                            if (end.timeInMillis <= start.timeInMillis) end.add(Calendar.DAY_OF_YEAR, 1)
                            if (end.timeInMillis > System.currentTimeMillis()) {
                                Toast.makeText(this, "La hora de fin no puede ser futura", Toast.LENGTH_LONG).show()
                                return@TimePickerDialog
                            }
                            saveActivitySession(start.timeInMillis, end.timeInMillis, type, autoDetected = false)
                        }, (h1 + 1) % 24, m1, true).apply { setTitle("Hora de fin") }.show()
                    }, cal.get(Calendar.HOUR_OF_DAY), 0, true).apply { setTitle("Hora de inicio") }.show()
                }, cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH)).show()
            }
            .show()
    }

    private fun editWakeTime() {
        val current = SleepPlanner.wakeMinute(this)
        TimePickerDialog(this, { _, h, m ->
            SleepPlanner.setWakeMinute(this, h * 60 + m)
            refresh()
        }, current / 60, current % 60, true).apply { setTitle("Hora de despertar") }.show()
    }

    private fun personalizePanel() {
        val names = PanelKeys.ALL.map { it.second }.toTypedArray()
        val hidden = PanelKeys.hidden(this).toMutableSet()
        val checked = PanelKeys.ALL.map { it.first !in hidden }.toBooleanArray()
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Mi panel de control")
            .setMultiChoiceItems(names, checked) { _, which, isChecked -> checked[which] = isChecked }
            .setPositiveButton("Guardar") { _, _ ->
                PanelKeys.setHidden(this, PanelKeys.ALL.filterIndexed { i, _ -> !checked[i] }.map { it.first }.toSet())
                lastData?.let { fillPanel(it) }
            }
            .setNegativeButton("Cancelar", null)
            .show()
    }

    // ---------------------------------------------------------------- perfil obligatorio

    private var setupDialogShown = false

    /**
     * Como WHOOP: sin saber quién lleva la pulsera no se puede calcular bien. Fecha de nacimiento, peso,
     * altura y sexo son obligatorios. Después, si ya hay pulsera, se pregunta una vez quién se queda el historial.
     */
    private fun checkSetupComplete() {
        if (setupDialogShown) return
        lifecycleScope.launch {
            val p = db.userProfileDao().getOnce()
            if (p == null) {
                setupDialogShown = true
                androidx.appcompat.app.AlertDialog.Builder(this@MainActivity)
                    .setTitle("Antes de empezar: ¿quién lleva la pulsera?")
                    .setMessage("Necesito tu fecha de nacimiento, peso, altura y sexo. Con ellos calculo tu FC máxima y tus zonas, " +
                        "el esfuerzo, las calorías, el VO₂ máx y cuánto sueño necesitas. Sin ellos los números serían de una persona genérica.")
                    .setPositiveButton("Completar ahora") { _, _ ->
                        setupDialogShown = false
                        startActivity(Intent(this@MainActivity, ProfileActivity::class.java))
                    }
                    .setCancelable(false)
                    .show()
            } else if (WhoopBackgroundService.findBondedWhoop(this@MainActivity) != null && WhoopBackgroundService.ackMode(this@MainActivity) == -1) {
                setupDialogShown = true
                AckModeDialog.show(this@MainActivity)
            }
        }
    }

    // ---------------------------------------------------------------- grabar actividad

    private fun restoreActivityButton() {
        val start = ActivityState.manualStart(this)
        activityStartMillis = start
        BleForegroundService.externalRecordingInProgress = start != null
        val text = findViewById<TextView>(R.id.startActivityText)
        val button = findViewById<View>(R.id.startActivityButton)
        if (start != null) {
            val min = (System.currentTimeMillis() - start) / 60000
            text.text = "DETENER · $min MIN"
            button.background = W.rounded(this, R.color.alert_red, 12f)
        } else {
            text.text = "INICIAR ACTIVIDAD"
            button.setBackgroundResource(R.drawable.bg_row_w)
        }
    }

    private fun toggleActivityRecording() {
        val start = activityStartMillis
        if (start == null) {
            activityStartMillis = System.currentTimeMillis()
            ActivityState.setManualStart(this, activityStartMillis)
            BleForegroundService.externalRecordingInProgress = true
            restoreActivityButton()
            Toast.makeText(this, "Actividad iniciada", Toast.LENGTH_SHORT).show()
        } else {
            val end = System.currentTimeMillis()
            activityStartMillis = null
            ActivityState.setManualStart(this, null)
            BleForegroundService.externalRecordingInProgress = false
            restoreActivityButton()
            androidx.appcompat.app.AlertDialog.Builder(this)
                .setTitle("¿Qué actividad ha sido?")
                .setItems(types) { _, index -> saveActivitySession(start, end, types[index], autoDetected = false) }
                // Si cancela, se guarda igualmente como "Sin clasificar" para no perder el registro
                .setOnCancelListener { saveActivitySession(start, end, "Sin clasificar", autoDetected = false) }
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
                Toast.makeText(this@MainActivity, "No hay suficientes datos de pulso en esa franja", Toast.LENGTH_LONG).show()
                return@launch
            }
            Formulas.updateObservedHrMax(this@MainActivity, session.maxHr)
            val id = db.activitySessionDao().save(session)
            refresh()
            startActivity(Intent(this@MainActivity, ActivityDetailActivity::class.java).putExtra(ActivityDetailActivity.EXTRA_SESSION_ID, id))
        }
    }

    // ---------------------------------------------------------------- otros

    private fun showSummaryDialog() {
        val d = lastData ?: return
        val s = d.summary
        val day = d.day
        val message = buildString {
            if (d.profileMissing) append("Sin perfil guardado, usando edad estimada de 30 años.\n\n")
            if (s != null) append("Lecturas analizadas: ${s.totalReadings}\n\n")
            append("FC en reposo: ${day.rhr?.let { "$it lpm" } ?: "sin datos suficientes"}\n")
            append("VFC (RMSSD): ${day.hrv?.let { "%.0f ms".format(it) } ?: "sin RR registrados"}\n")
            append("Respiración: ${day.resp?.let { Ui.comma(it) + " rpm" } ?: "--"}\n")
            append("VO2máx: ${day.vo2?.let { "%.0f".format(it) } ?: "--"}\n")
            append("Esfuerzo (0-21): ${day.strain?.let { Ui.comma(it) } ?: "--"}\n\n")
            if (day.sleepMinutes != null) {
                append("Dormido: ${Ui.hm(day.sleepMinutes)}\n")
                if (s?.sleepStart != null) append("De ${s.sleepStart} a ${s.sleepEnd}\n")
            } else {
                append("No se detectó ningún periodo de descanso largo (mínimo 90 min).\n")
            }
        }
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Resumen")
            .setMessage(message)
            .setPositiveButton("Cerrar", null)
            .show()
    }

    private fun exportCsv() {
        val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
        if (!file.exists()) {
            Toast.makeText(this, "Aún no hay datos guardados", Toast.LENGTH_SHORT).show()
            return
        }
        val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/csv"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, "Compartir hr_log.csv"))
    }
}
