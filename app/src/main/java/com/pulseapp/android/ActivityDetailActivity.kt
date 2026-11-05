package com.pulseapp.android

import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.ActivitySession
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.ui.ActivityHrChartView
import com.pulseapp.android.ui.StageTimelineBarView
import com.pulseapp.android.ui.ZoneBarView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.ceil

/**
 * Detalle de una actividad con el aspecto de WHOOP (17/10): esfuerzo y pasos frente a tu media, pulso de la actividad,
 * tiempo en cada zona (con tu rango típico en ese deporte) y estadísticas clave frente a los últimos 30 días.
 */
class ActivityDetailActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_SESSION_ID = "session_id"
    }

    private val esLocale = Locale("es", "ES")
    private var sessionId = -1L
    private var strengthTab = 0
    private var strengthPage = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_activity_detail)
        window.statusBarColor = Ui.color(this, R.color.w_bg_top)
        sessionId = intent.getLongExtra(EXTRA_SESSION_ID, -1)
        if (sessionId == -1L) { finish(); return }
        findViewById<View>(R.id.backButton).setOnClickListener { finish() }
        findViewById<View>(R.id.moreButton).setOnClickListener { showMenu() }
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun showMenu() {
        val hasLog = Strength.logFor(sessionId) != null
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setItems(arrayOf("Editar actividad", if (hasLog) "Editar ejercicios (entrenador de fuerza)" else "Registrar ejercicios (entrenador de fuerza)",
                "Eliminar actividad")) { _, which ->
                if (which == 0) {
                    startActivity(Intent(this, EditSessionActivity::class.java).putExtra(EditSessionActivity.EXTRA_SESSION_ID, sessionId))
                } else if (which == 1) {
                    openStrengthLog()
                } else {
                    androidx.appcompat.app.AlertDialog.Builder(this)
                        .setTitle("¿Eliminar esta actividad?")
                        .setMessage("Se borra el registro de la actividad. El pulso guardado no se toca.")
                        .setPositiveButton("Eliminar") { _, _ ->
                            lifecycleScope.launch {
                                val db = AppDatabase.getInstance(this@ActivityDetailActivity)
                                db.activitySessionDao().getById(sessionId)?.let { db.activitySessionDao().delete(it) }
                                Strength.deleteLog(sessionId)
                                Toast.makeText(this@ActivityDetailActivity, "Actividad eliminada", Toast.LENGTH_SHORT).show()
                                finish()
                            }
                        }
                        .setNegativeButton("Cancelar", null)
                        .show()
                }
            }
            .show()
    }

    private fun openStrengthLog() {
        startActivity(Intent(this, StrengthSessionActivity::class.java)
            .putExtra(StrengthSessionActivity.EXTRA_MODE, StrengthSessionActivity.MODE_LOG)
            .putExtra(StrengthSessionActivity.EXTRA_SESSION_ID, sessionId))
    }

    private class Stats(val strain: Double, val steps: Int?, val kcal: Double, val avgHr: Int, val maxHr: Int, val seconds: Long)

    private fun load() {
        lifecycleScope.launch {
            val ctx = this@ActivityDetailActivity
            val db = AppDatabase.getInstance(ctx)
            val s = db.activitySessionDao().getById(sessionId) ?: run { finish(); return@launch }
            Formulas.init(ctx)
            val log = Strength.logFor(s.id)?.takeIf { it.setCount > 0 }
            val all = db.activitySessionDao().getAll()
            val profile = db.userProfileDao().getOnce()
            val hrMax = Formulas.hrMax(profile?.ageYears() ?: 30)
            val dir = getExternalFilesDir(null)
            val hrFile = File(dir, "hr_log.csv")
            val motion = withContext(Dispatchers.IO) { MotionTracker.readMinutes(File(dir, MotionTracker.FILE_NAME)) }
            val band = withContext(Dispatchers.IO) { BandSteps.read(dir) }
            fun stepsIn(a: ActivitySession): Int? {
                // 30/10: pasos de la pulsera (también sin el móvil cerca) + PulseApp donde la pulsera no llega
                if (BandSteps.hasData(band, a.startMillis, a.endMillis)) return BandSteps.merged(band, motion, a.startMillis, a.endMillis)
                val m = motion.filter { it.minuteStartUnix * 1000 in a.startMillis until a.endMillis }
                return if (m.isEmpty()) null else m.sumOf { it.steps }
            }
            val pad = 10 * 60_000L
            val samples = withContext(Dispatchers.IO) {
                StressCalculator().loadSamples(hrFile, s.startMillis - pad).filter { it.timeMillis <= s.endMillis + pad }
            }

            // Cabecera
            findViewById<ImageView>(R.id.sportIcon).setImageResource(W.sportIcon(s.type))
            findViewById<TextView>(R.id.sportTitle).text = s.type.uppercase(esLocale)
            findViewById<TextView>(R.id.sportSubtitle).text = whenText(s)

            // Medias de 30 días del mismo deporte (si no hay, de todas las actividades)
            val monthAgo = s.startMillis - 30L * 86_400_000L
            val others = all.filter { it.id != s.id && it.startMillis in monthAgo until s.startMillis + 86_400_000L }
            val sameType = others.filter { it.type == s.type }
            val pool = if (sameType.isNotEmpty()) sameType else others
            fun stats(a: ActivitySession) = Stats(a.strain, stepsIn(a), a.caloriesKcal, a.avgHr, a.maxHr, (a.endMillis - a.startMillis) / 1000)
            val me = stats(s)
            val avg = pool.map { stats(it) }

            val content = findViewById<LinearLayout>(R.id.detailContent)
            content.removeAllViews()
            // 2/11: la siesta se muestra como en WHOOP (horas de sueño, sueño reparador y fases), no como una actividad
            if (s.type == Formulas.NAP_TYPE) {
                val st = withContext(Dispatchers.IO) { NapStages.dir = NapStages.dir ?: dir; NapStages.get(s) }
                showNap(content, s, st, samples)
                return@launch
            }

            // Esfuerzo y pasos
            content.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                    topMargin = Ui.dp(ctx, 26f)
                }
                val avgStrain = avg.takeIf { it.isNotEmpty() }?.map { it.strain }?.average()
                addView(bigStat(Ui.comma(me.strain), R.color.strain_blue, avgStrain?.let { trendOf(me.strain, it) }, avgStrain?.let { Ui.comma(it) },
                    "Esfuerzo\nde actividad").apply { layoutParams = W.weight(0.85f) })
                val avgSteps = avg.mapNotNull { it.steps }.takeIf { it.isNotEmpty() }?.average()
                if (log != null) {
                    // 5/11: entrenador de fuerza → reparto CARDIO (pulso) / MUSCULAR (series), como WHOOP
                    val inSess = samples.filter { it.timeMillis in s.startMillis..s.endMillis }.distinctBy { it.timeMillis / 1000 }
                    var cardio = 0.0
                    for (i in 1 until inSess.size) {
                        val dt = (inSess[i].timeMillis - inSess[i - 1].timeMillis) / 60000.0
                        if (dt <= 0 || dt > 8) continue
                        cardio += Formulas.trimp(dt, inSess[i].bpm, Formulas.zoneRestingHr(), hrMax)
                    }
                    val (cp, mp) = Strength.cardioMuscleSplit(cardio, Strength.muscleLoad(log, Formulas.bodyKg()))
                    addView(cardioMuscle(cp, mp).apply { layoutParams = W.weight(1.15f) })
                } else
                addView(bigStat(me.steps?.let { Ui.thousands(it.toLong()) } ?: "--", R.color.text_primary,
                    if (me.steps != null && avgSteps != null) trendOf(me.steps.toDouble(), avgSteps) else null,
                    avgSteps?.let { Ui.thousands(Math.round(it)) }, "Pasos de la actividad").apply { layoutParams = W.weight(1.15f) })
            })

            // Gráfica de pulso (medias de 10 s)
            val chartPts = samples.groupBy { it.timeMillis / 10_000 }.entries.sortedBy { it.key }
                .map { (k, v) -> k * 10_000 to Math.round(v.map { it.bpm }.average()).toInt() }
            var hrChart: ActivityHrChartView? = null
            // 5/11: deslizar el dedo por la gráfica muestra el pulso de ese momento (como WHOOP)
            val scrubLabel = scrubLabel(ctx)
            if (log != null) {
                content.addView(SUi.segmented(ctx, listOf("Ejercicios", "Zonas de FC"), strengthTab) { strengthTab = it; load() })
            }
            if (chartPts.size >= 2) {
                content.addView(scrubLabel)
                content.addView(ActivityHrChartView(ctx).apply {
                    hrChart = this
                    setData(chartPts, s.startMillis, s.endMillis)
                    onScrub = { t, b -> showScrub(scrubLabel, t, b) }
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Ui.dp(ctx, 360f)).apply {
                        topMargin = Ui.dp(ctx, 22f)
                    }
                })
            } else {
                content.addView(W.body(ctx, "No hay pulso guardado de esta actividad.", 14f).apply { setPadding(0, Ui.dp(ctx, 22f), 0, 0) })
            }

            // Ejercicios del entrenador de fuerza (pestaña EJERCICIOS) o zonas (ZONAS DE FC)
            val zoneParent = if (log != null && strengthTab == 0) LinearLayout(ctx) else content
            if (log != null && strengthTab == 0) {
                exercisePager(content, log) { ranges -> hrChart?.setHighlights(ranges, android.graphics.Color.parseColor("#2BD4A0")) }
            }
            // Rango típico + duración
            val durSec = (s.endMillis - s.startMillis) / 1000
            zoneParent.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                    topMargin = Ui.dp(ctx, 22f)
                }
                addView(View(ctx).apply {
                    setBackgroundResource(R.drawable.bg_outline_card_w)
                    layoutParams = LinearLayout.LayoutParams(Ui.dp(ctx, 26f), Ui.dp(ctx, 26f))
                })
                addView(W.title(ctx, "Rango típico", 14.5f, R.color.text_secondary).apply {
                    setPadding(Ui.dp(ctx, 14f), 0, 0, 0); layoutParams = W.weight()
                })
                addView(W.title(ctx, "Duración  ", 14.5f, R.color.text_secondary))
                addView(W.number(ctx, hms(durSec), 18f))
            })

            // Zonas: segundos con pulso en cada una (dentro de la actividad)
            val inside = samples.filter { it.timeMillis in s.startMillis..s.endMillis }.distinctBy { it.timeMillis / 1000 }
            val bounds = Formulas.zoneBounds(hrMax)
            val zoneSec = IntArray(6)
            inside.forEach { zoneSec[Formulas.zoneOf(it.bpm, bounds)]++ }
            val zoneTotal = zoneSec.sum().coerceAtLeast(1)
            val zoneColors = listOf(R.color.w_zone0, R.color.w_zone1, R.color.w_zone2, R.color.w_zone3, R.color.w_zone4, R.color.w_zone5)
            // Rango típico de cada zona en este deporte (mín–máx de las otras sesiones, si hay al menos 2)
            val typical = (0..5).map { z ->
                val fr = sameType.filter { it.id != s.id }.mapNotNull { a ->
                    val mins = listOf(a.minutesZone0, a.minutesZone1, a.minutesZone2, a.minutesZone3, a.minutesZone4, a.minutesZone5)
                    val tot = mins.sum()
                    if (tot <= 0) null else mins[z].toFloat() / tot
                }
                if (fr.size >= 2) fr.minOrNull()!! to fr.maxOrNull()!! else null
            }
            // 29/10: tocar una zona la marca (como las fases del sueño): su barra muestra cuándo estuviste en ella y la gráfica
            // de pulso se pinta de su color en esos tramos. Tramos = segundos seguidos en la zona (huecos ≤ 5 s se unen).
            val zoneRuns = Array(6) { ArrayList<Pair<Long, Long>>() }
            run {
                var curZ = -1; var a = 0L; var last = 0L
                for (r in inside.sortedBy { it.timeMillis }) {
                    val z = Formulas.zoneOf(r.bpm, bounds)
                    if (z == curZ && r.timeMillis - last <= 5_000L) { last = r.timeMillis; continue }
                    if (curZ >= 0) zoneRuns[curZ].add(a to last + 1_000L)
                    curZ = z; a = r.timeMillis; last = r.timeMillis
                }
                if (curZ >= 0) zoneRuns[curZ].add(a to last + 1_000L)
            }
            // Zona de cada tramo de 10 s para la barra de tiempo (−1 = sin pulso)
            val nBuckets = ((s.endMillis - s.startMillis) / 10_000L + 1).toInt().coerceIn(1, 5000)
            val bucketZone = IntArray(nBuckets) { -1 }
            run {
                val sum = IntArray(nBuckets); val cnt = IntArray(nBuckets)
                for (r in inside) { val k = ((r.timeMillis - s.startMillis) / 10_000L).toInt(); if (k in 0 until nBuckets) { sum[k] += r.bpm; cnt[k]++ } }
                for (k in 0 until nBuckets) if (cnt[k] > 0) bucketZone[k] = Formulas.zoneOf(Math.round(sum[k].toDouble() / cnt[k]).toInt(), bounds)
            }
            val zoneBox = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
            zoneParent.addView(zoneBox)
            var selectedZone: Int? = null
            fun renderZones() {
                zoneBox.removeAllViews()
                for (z in 5 downTo 0) {
                    val range = when (z) {
                        0 -> "<${bounds[0]} BPM"
                        5 -> "${bounds[4]}+ BPM"
                        else -> "${bounds[z - 1]}-${bounds[z] - 1} BPM"
                    }
                    val on = selectedZone == z
                    val row = zoneRow(z, range, zoneSec[z], zoneSec[z].toFloat() / zoneTotal, zoneColors[z], typical[z],
                        timeline = if (on) bucketZone else null, dimmed = selectedZone != null && !on)
                    if (zoneSec[z] > 0) row.setOnClickListener {
                        selectedZone = if (on) null else z
                        row.performHapticFeedback(android.view.HapticFeedbackConstants.CLOCK_TICK)
                        renderZones()
                    }
                    zoneBox.addView(row)
                }
                val sel = selectedZone
                if (zoneParent !== content) return
                if (sel != null) hrChart?.setHighlights(zoneRuns[sel], Ui.color(ctx, zoneColors[sel]))
                else hrChart?.setHighlights(emptyList(), 0)
            }
            renderZones()
            zoneParent.addView(W.body(ctx, "Las zonas salen de tu reserva de FC, como en WHOOP: entre tu FC en reposo (${Formulas.zoneRestingHr()} lpm) y tu FC máxima (${Math.round(hrMax)} lpm), que puedes cambiar en Sobre mí.", 14.5f).apply {
                setPadding(0, Ui.dp(ctx, 12f), 0, 0)
            })

            // Estadísticas clave
            content.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                    topMargin = Ui.dp(ctx, 34f)
                }
                addView(W.title(ctx, "Estadísticas clave", 15.5f).apply { layoutParams = W.weight() })
                addView(W.title(ctx, "vs. promedio de 30 días", 13f, R.color.text_secondary))
            })
            val strip = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
            fun avgOf(f: (Stats) -> Double): Double? = avg.takeIf { it.isNotEmpty() }?.map(f)?.average()
            val kcalAvg = avgOf { it.kcal }
            val hrAvg = avgOf { it.avgHr.toDouble() }
            val maxAvg = avgOf { it.maxHr.toDouble() }
            val durAvg = avgOf { it.seconds.toDouble() }
            strip.addView(statCard(R.drawable.ic_calories, "Calorías", "%.0f".format(me.kcal), "cal.",
                kcalAvg?.let { trendOf(me.kcal, it) }, kcalAvg?.let { "%.0f cal.".format(it) }))
            strip.addView(statCard(R.drawable.ic_heart, "FC prom.", me.avgHr.toString(), "lpm",
                hrAvg?.let { trendOf(me.avgHr.toDouble(), it) }, hrAvg?.let { "%.0f lpm".format(it) }))
            strip.addView(statCard(R.drawable.ic_heart_up, "FC máxima", me.maxHr.toString(), "lpm",
                maxAvg?.let { trendOf(me.maxHr.toDouble(), it) }, maxAvg?.let { "%.0f lpm".format(it) }))
            strip.addView(statCard(R.drawable.ic_stopwatch, "Duración", hm(durSec), ":%02d".format(durSec % 60),
                durAvg?.let { trendOf(durSec.toDouble(), it) }, durAvg?.let { hms(Math.round(it)) }))
            content.addView(HorizontalScrollView(ctx).apply {
                isHorizontalScrollBarEnabled = false
                clipToPadding = false
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                    topMargin = Ui.dp(ctx, 16f)
                }
                addView(strip)
            })
            if (log != null) {
                val count = withContext(Dispatchers.IO) {
                    val ids = all.map { it.id }.toSet()
                    Strength.logs().count { it.id in ids && it.setCount > 0 && it.startMs <= log.startMs }
                }
                content.addView(milestoneCard(ctx, count).apply { layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = Ui.dp(ctx, 26f) } })
            } else if (Formulas.isStrength(s.type)) {
                content.addView(W.card(ctx, 26f).apply {
                    addView(W.title(ctx, "Entrenador de fuerza", 15f))
                    addView(W.body(ctx, "Registra los ejercicios, series y pesos de este entreno: la carga muscular entra en el esfuerzo y verás el resumen como en WHOOP.", 14.5f).apply {
                        setPadding(0, Ui.dp(ctx, 8f), 0, Ui.dp(ctx, 14f))
                    })
                    addView(SUi.button(ctx, "Registrar ejercicios") { openStrengthLog() })
                })
            }
            if (s.autoDetected) {
                content.addView(W.body(ctx, "Actividad detectada automáticamente. Puedes cambiar el deporte o la hora desde ···", 14f).apply {
                    setPadding(0, Ui.dp(ctx, 18f), 0, 0)
                })
            }
        }
    }

    private fun showNap(content: LinearLayout, s: ActivitySession, st: SleepStager.Result?, samples: List<StressCalculator.Sample>) {
        val ctx = this
        val asleep = NapStages.asleepMinutes(s)
        val restorative = st?.let { it.deepMinutes + it.remMinutes }
        content.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin = Ui.dp(ctx, 26f)
            }
            addView(bigStat(Ui.hm(asleep), R.color.w_ring_sleep, null, null, "Horas de sueño").apply { layoutParams = W.weight() })
            addView(bigStat(restorative?.let { Ui.hm(it) } ?: "--", R.color.text_primary, null, null, "Sueño reparador").apply { layoutParams = W.weight() })
        })
        content.addView(W.card(ctx, 22f).apply {
            setBackgroundResource(R.drawable.bg_outline_card_w)
            setPadding(Ui.dp(ctx, 20f), Ui.dp(ctx, 18f), Ui.dp(ctx, 20f), Ui.dp(ctx, 18f))
            addView(W.body(ctx, "Esta siesta redujo tu sueño requerido por $asleep minutos.", 17f, R.color.text_primary))
        })
        val inBed = s.copy(startMillis = st?.startMillis ?: s.startMillis, endMillis = st?.endMillis ?: s.endMillis)
        val chartPts = samples.groupBy { it.timeMillis / 10_000 }.entries.sortedBy { it.key }
            .map { (k, v) -> k * 10_000 to Math.round(v.map { it.bpm }.average()).toInt() }
        var hrChart: ActivityHrChartView? = null
        if (chartPts.size >= 2) content.addView(ActivityHrChartView(ctx).apply {
            hrChart = this
            setData(chartPts, inBed.startMillis, inBed.endMillis)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Ui.dp(ctx, 300f)).apply { topMargin = Ui.dp(ctx, 22f) }
        })
        val durMin = ((inBed.endMillis - inBed.startMillis) / 60_000L).toInt()
        content.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin = Ui.dp(ctx, 22f)
            }
            addView(W.title(ctx, "Fases de la siesta", 14.5f, R.color.text_secondary).apply { layoutParams = W.weight() })
            addView(W.title(ctx, "Duración  ", 14.5f, R.color.text_secondary))
            addView(W.number(ctx, Ui.hm(durMin), 18f))
        })
        if (st == null) {
            content.addView(W.body(ctx, "Sin movimiento grabado en la siesta no se pueden calcular las fases.", 14.5f).apply {
                setPadding(0, Ui.dp(ctx, 12f), 0, 0)
            })
            return
        }
        val names = listOf("Despierto", "Ligero", "Sueño profundo (SWS)", "REM")
        val colors = listOf(R.color.w_stage_awake, R.color.w_stage_light, R.color.w_stage_deep, R.color.w_stage_rem)
        val order = listOf(SleepStager.AWAKE, SleepStager.LIGHT, SleepStager.DEEP, SleepStager.REM)
        // Tramos de cada fase (para pintar la gráfica de pulso al tocarla, como en Sueño)
        val runs = Array(4) { ArrayList<Pair<Long, Long>>() }
        var i = 0
        while (i < st.stages.size) {
            var j = i
            while (j < st.stages.size && st.stages[j] == st.stages[i]) j++
            runs[st.stages[i]].add((st.startMinute + i) * 60_000L to (st.startMinute + j) * 60_000L)
            i = j
        }
        val box = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
        content.addView(box)
        var selected: Int? = null
        fun render() {
            box.removeAllViews()
            for ((k, stage) in order.withIndex()) {
                val min = st.count(stage)
                val row = LinearLayout(ctx).apply {
                    orientation = LinearLayout.VERTICAL
                    setBackgroundResource(R.drawable.bg_card_w)
                    setPadding(Ui.dp(ctx, 18f), Ui.dp(ctx, 14f), Ui.dp(ctx, 18f), Ui.dp(ctx, 12f))
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                        topMargin = Ui.dp(ctx, 12f)
                    }
                    alpha = if (min == 0 || (selected != null && selected != stage)) 0.55f else 1f
                    addView(LinearLayout(ctx).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        addView(W.title(ctx, names[k], 15.5f))
                        addView(W.number(ctx, "%d %%".format(min * 100 / st.stages.size.coerceAtLeast(1)), 15f, colors[k]).apply {
                            setPadding(Ui.dp(ctx, 12f), 0, 0, 0); layoutParams = W.weight()
                        })
                        addView(W.number(ctx, Ui.hm(min), 22f))
                    })
                    if (min > 0) addView(StageTimelineBarView(ctx).apply {
                        setData(st.stages, stage, Ui.color(ctx, colors[k]), true)
                        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Ui.dp(ctx, 30f)).apply { topMargin = Ui.dp(ctx, 10f) }
                    })
                }
                if (min > 0) row.setOnClickListener {
                    selected = if (selected == stage) null else stage
                    render()
                }
                box.addView(row)
            }
            val sel = selected
            if (sel != null) hrChart?.setHighlights(runs[sel], Ui.color(ctx, colors[order.indexOf(sel)])) else hrChart?.setHighlights(emptyList(), 0)
        }
        render()
        // Métricas de la siesta
        content.addView(W.title(ctx, "Métricas de la siesta", 15.5f).apply { setPadding(0, Ui.dp(ctx, 30f), 0, 0) })
        val strip = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
        strip.addView(statCard(R.drawable.ic_moon, "Despertares", st.awakenings.toString(), "", null, null))
        strip.addView(statCard(R.drawable.ic_moon, "Eficiencia", st.efficiencyPct.toString(), "%", null, null))
        strip.addView(statCard(R.drawable.ic_heart, "FC prom.", s.avgHr.toString(), "lpm", null, null))
        content.addView(HorizontalScrollView(ctx).apply {
            isHorizontalScrollBarEnabled = false
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin = Ui.dp(ctx, 16f)
            }
            addView(strip)
        })
        content.addView(W.body(ctx, "Fases calculadas con tu pulso y movimiento (el mismo método que la noche). Las siestas restan su tiempo dormido de lo que necesitas dormir esa noche, como en WHOOP.", 14f).apply {
            setPadding(0, Ui.dp(ctx, 18f), 0, 0)
        })
    }

    private fun scrubLabel(ctx: android.content.Context): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.BOTTOM
        visibility = View.INVISIBLE
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = Ui.dp(ctx, 16f) }
        addView(W.number(ctx, "--", 34f, R.color.strain_blue).apply { tag = "bpm" })
        addView(W.number(ctx, " lpm", 16f, R.color.strain_blue).apply { setPadding(0, 0, 0, Ui.dp(ctx, 4f)) })
        addView(W.number(ctx, "", 16f, R.color.text_secondary).apply { tag = "time"; setPadding(Ui.dp(ctx, 14f), 0, 0, Ui.dp(ctx, 4f)) })
    }

    private fun showScrub(label: LinearLayout, t: Long?, bpm: Int?) {
        if (t == null || bpm == null) { label.visibility = View.INVISIBLE; return }
        label.visibility = View.VISIBLE
        label.findViewWithTag<TextView>("bpm").text = bpm.toString()
        label.findViewWithTag<TextView>("time").text = SimpleDateFormat("HH:mm:ss", esLocale).format(Date(t))
    }

    /** Barra CARDIO / MUSCULAR con sus porcentajes. */
    private fun cardioMuscle(cardioPct: Int, musclePct: Int): LinearLayout {
        val ctx = this
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(Ui.dp(ctx, 12f), Ui.dp(ctx, 6f), 0, 0)
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(W.title(ctx, "Cardio", 13f), W.weight())
                addView(W.title(ctx, "Muscular", 13f))
            })
            addView(android.widget.FrameLayout(ctx).apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Ui.dp(ctx, 16f)).apply { topMargin = Ui.dp(ctx, 8f) }
                background = android.graphics.drawable.GradientDrawable(android.graphics.drawable.GradientDrawable.Orientation.LEFT_RIGHT,
                    intArrayOf(android.graphics.Color.parseColor("#0A7FD0"), Ui.color(ctx, R.color.strain_blue))).apply { cornerRadius = Ui.dp(ctx, 3f).toFloat() }
                addView(View(ctx).apply {
                    setBackgroundColor(android.graphics.Color.WHITE)
                    layoutParams = android.widget.FrameLayout.LayoutParams(Ui.dp(ctx, 3f), Ui.dp(ctx, 22f)).apply { gravity = Gravity.CENTER_VERTICAL }
                    post { translationX = ((parent as View).width * cardioPct / 100f) - Ui.dp(ctx, 1.5f) }
                })
            })
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = Ui.dp(ctx, 8f) }
                addView(W.number(ctx, "$cardioPct %", 17f), W.weight())
                addView(W.number(ctx, "$musclePct %", 17f))
            })
        }
    }

    /**
     * Tarjetas que se deslizan (como WHOOP): la 1.ª con el total (ejercicios, series, volumen, repeticiones) y una por ejercicio.
     * Al pasar a un ejercicio, sus series se marcan en verde en la gráfica de pulso. "Ver todo" abre el resumen.
     */
    private fun exercisePager(content: LinearLayout, log: Strength.Workout,
                              highlight: (List<Pair<Long, Long>>) -> Unit) {
        val ctx = this
        val pages = log.exercises.size + 1
        if (strengthPage >= pages) strengthPage = 0
        val box = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = Ui.dp(ctx, 18f) }
        }
        val dots = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        fun stat(v: String, u: String, l: String) = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.BOTTOM
                addView(W.number(ctx, v, 30f)); if (u.isNotEmpty()) addView(W.number(ctx, " $u", 16f).apply { setPadding(0, 0, 0, Ui.dp(ctx, 3f)) })
            })
            addView(W.title(ctx, l, 12f, R.color.text_secondary).apply { setPadding(0, Ui.dp(ctx, 6f), 0, 0); maxLines = 1 })
        }
        fun render() {
            box.removeAllViews()
            val p = strengthPage
            val card = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; setBackgroundResource(R.drawable.bg_card_w) }
            val head = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                background = SUi.rounded(ctx, android.graphics.Color.parseColor("#262D32"), 14f)
                setPadding(Ui.dp(ctx, 4f), Ui.dp(ctx, 4f), Ui.dp(ctx, 12f), Ui.dp(ctx, 4f))
            }
            val vol: Double; val reps: Int
            if (p == 0) {
                head.addView(android.widget.FrameLayout(ctx).apply {
                    background = SUi.rounded(ctx, android.graphics.Color.parseColor("#33393E"), 8f)
                    layoutParams = LinearLayout.LayoutParams(Ui.dp(ctx, 64f), Ui.dp(ctx, 56f))
                    addView(ImageView(ctx).apply { setImageResource(R.drawable.ic_dumbbell); setColorFilter(android.graphics.Color.WHITE)
                        layoutParams = android.widget.FrameLayout.LayoutParams(Ui.dp(ctx, 28f), Ui.dp(ctx, 28f), Gravity.CENTER) })
                })
                head.addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(W.body(ctx, "${log.exercises.size} ejercicios", 15.5f, R.color.text_primary))
                    addView(W.body(ctx, "${log.setCount} series", 13.5f, R.color.strain_blue))
                }, W.weight().apply { marginStart = Ui.dp(ctx, 14f) })
                vol = log.volume; reps = log.reps
                highlight(emptyList())
            } else {
                val e = log.exercises[p - 1]
                head.addView(SUi.thumb(ctx, Strength.exercise(e.exId)?.group, 50f))
                head.addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(W.body(ctx, e.name, 15f, R.color.text_primary))
                    addView(W.body(ctx, "${e.sets.size} series", 13.5f, R.color.w_mint))
                }, W.weight().apply { marginStart = Ui.dp(ctx, 14f) })
                head.addView(W.icon(ctx, R.drawable.ic_chevron_right, 18f, R.color.text_secondary))
                vol = e.volume; reps = e.reps
                highlight(e.sets.mapNotNull { st -> if (st.startMs != null && st.endMs != null) st.startMs!! to st.endMs!! else null })
            }
            card.addView(head)
            card.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(Ui.dp(ctx, 20f), Ui.dp(ctx, 18f), Ui.dp(ctx, 16f), Ui.dp(ctx, 20f))
                addView(stat(SUi.kg(vol), "kg", "Volumen de carga"), W.weight())
                addView(stat("$reps", "", "Repeticiones totales"), W.weight())
            })
            card.isClickable = true
            card.setOnClickListener { if (p > 0) openSummary() }
            // deslizar a izquierda / derecha
            val gd = android.view.GestureDetector(ctx, object : android.view.GestureDetector.SimpleOnGestureListener() {
                override fun onDown(e: android.view.MotionEvent): Boolean = true
                override fun onFling(e1: android.view.MotionEvent?, e2: android.view.MotionEvent, vx: Float, vy: Float): Boolean {
                    if (kotlin.math.abs(vx) < kotlin.math.abs(vy)) return false
                    strengthPage = if (vx < 0) (p + 1).coerceAtMost(pages - 1) else (p - 1).coerceAtLeast(0)
                    render(); return true
                }
                override fun onSingleTapUp(e: android.view.MotionEvent): Boolean { if (p > 0) openSummary(); return true }
            })
            var dx0 = 0f; var dy0 = 0f
            card.setOnTouchListener { v, ev ->
                when (ev.actionMasked) {
                    android.view.MotionEvent.ACTION_DOWN -> { dx0 = ev.x; dy0 = ev.y }
                    android.view.MotionEvent.ACTION_MOVE -> if (kotlin.math.abs(ev.x - dx0) > kotlin.math.abs(ev.y - dy0) && kotlin.math.abs(ev.x - dx0) > Ui.dp(ctx, 8f))
                        v.parent.requestDisallowInterceptTouchEvent(true)
                }
                gd.onTouchEvent(ev)
            }
            box.addView(card)
            dots.removeAllViews()
            for (i in 0 until pages) dots.addView(View(ctx).apply {
                background = SUi.rounded(ctx, if (i == p) android.graphics.Color.WHITE else android.graphics.Color.parseColor("#55FFFFFF"), 4f)
                layoutParams = LinearLayout.LayoutParams(Ui.dp(ctx, 7f), Ui.dp(ctx, 7f)).apply { marginEnd = Ui.dp(ctx, 7f) }
                isClickable = true
                setOnClickListener { strengthPage = i; render() }
            })
            box.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = Ui.dp(ctx, 14f) }
                addView(View(ctx), W.weight())
                addView(dots)
                addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                    layoutParams = W.weight().apply { }
                    gravity = Gravity.END or Gravity.CENTER_VERTICAL
                    addView(W.title(ctx, "Ver todo", 14f))
                    addView(W.icon(ctx, R.drawable.ic_arrow_right, 18f).apply { (layoutParams as LinearLayout.LayoutParams).marginStart = Ui.dp(ctx, 8f) })
                    isClickable = true
                    setOnClickListener { openSummary() }
                })
            })
        }
        render()
        content.addView(box)
    }

    private fun openSummary() {
        startActivity(Intent(this, StrengthSummaryActivity::class.java).putExtra(StrengthSummaryActivity.EXTRA_SESSION_ID, sessionId))
    }

    private fun trendOf(value: Double, avg: Double): Trend = when {
        kotlin.math.abs(value - avg) < 0.005 * kotlin.math.max(1.0, kotlin.math.abs(avg)) -> Trend.SAME
        value > avg -> Trend.UP
        else -> Trend.DOWN
    }

    private fun hm(sec: Long) = "%d:%02d".format(sec / 3600, (sec % 3600) / 60)
    private fun hms(sec: Long) = "%d:%02d:%02d".format(sec / 3600, (sec % 3600) / 60, sec % 60)

    /** "Hoy de las 17:35 a las 19:26", "Ayer de las …" o "16 oct. de las …". */
    private fun whenText(s: ActivitySession): String {
        val t = SimpleDateFormat("HH:mm", esLocale)
        val start = Calendar.getInstance().apply { timeInMillis = s.startMillis }
        val today = Calendar.getInstance()
        val days = ((Ui.todayStartMillis() - Calendar.getInstance().apply {
            timeInMillis = s.startMillis; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis) / 86_400_000L).toInt()
        val day = when (days) {
            0 -> "Hoy"
            1 -> "Ayer"
            else -> SimpleDateFormat(if (start.get(Calendar.YEAR) == today.get(Calendar.YEAR)) "d MMM" else "d MMM yyyy", esLocale).format(Date(s.startMillis))
        }
        return "$day de las ${t.format(Date(s.startMillis))} a las ${t.format(Date(s.endMillis))}"
    }

    private fun bigStat(value: String, colorRes: Int, trend: Trend?, avgText: String?, label: String): LinearLayout {
        val ctx = this
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(W.number(ctx, value, 56f, colorRes))
                if (avgText != null) addView(W.trendChip(ctx, trend, avgText).apply {
                    layoutParams = W.wrap().apply { marginStart = Ui.dp(ctx, 10f) }
                })
            })
            addView(W.title(ctx, label, 16f, R.color.text_secondary).apply {
                setPadding(0, Ui.dp(ctx, 10f), 0, 0)
                setLineSpacing(Ui.dp(ctx, 5f).toFloat(), 1f)
            })
        }
    }

    private fun zoneRow(z: Int, range: String, seconds: Int, fraction: Float, colorRes: Int, typical: Pair<Float, Float>?,
                        timeline: IntArray? = null, dimmed: Boolean = false): LinearLayout {
        val ctx = this
        val empty = seconds == 0
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundResource(R.drawable.bg_card_w)
            setPadding(Ui.dp(ctx, 18f), Ui.dp(ctx, 14f), Ui.dp(ctx, 18f), Ui.dp(ctx, if (empty) 14f else 12f))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin = Ui.dp(ctx, 12f)
            }
            alpha = if (empty || dimmed) 0.55f else 1f
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(W.title(ctx, "Zona $z", 15.5f))
                addView(W.title(ctx, range, 15.5f, R.color.text_secondary).apply { setPadding(Ui.dp(ctx, 14f), 0, 0, 0) })
                addView(W.number(ctx, "%.0f %%".format(fraction * 100), 16f, colorRes).apply {
                    setPadding(Ui.dp(ctx, 14f), 0, 0, 0); layoutParams = W.weight()
                })
                val h = seconds / 3600; val m = (seconds % 3600) / 60; val sec = seconds % 60
                addView(W.number(ctx, "%d:%02d".format(h, m), 22f))
                addView(W.number(ctx, ":%02d".format(sec), 15f, R.color.text_secondary))
            })
            if (!empty && timeline != null) addView(StageTimelineBarView(ctx).apply {
                // Zona elegida: dónde cae a lo largo de la actividad (como la barra de una fase del sueño)
                setData(timeline, z, Ui.color(ctx, colorRes), true)
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Ui.dp(ctx, 30f)).apply { topMargin = Ui.dp(ctx, 10f) }
            }) else if (!empty) addView(ZoneBarView(ctx).apply {
                setData(fraction, Ui.color(ctx, colorRes), typical?.first, typical?.second)
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Ui.dp(ctx, 44f)).apply { topMargin = Ui.dp(ctx, 6f) }
            })
        }
    }

    private fun statCard(icon: Int, label: String, value: String, unit: String, trend: Trend?, avgText: String?): LinearLayout {
        val ctx = this
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundResource(R.drawable.bg_card_w)
            setPadding(Ui.dp(ctx, 18f), Ui.dp(ctx, 18f), Ui.dp(ctx, 18f), Ui.dp(ctx, 18f))
            layoutParams = LinearLayout.LayoutParams(Ui.dp(ctx, 176f), LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginEnd = Ui.dp(ctx, 12f) }
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(W.icon(ctx, icon, 22f, R.color.text_secondary))
                addView(W.title(ctx, label, 14f, R.color.text_secondary).apply { setPadding(Ui.dp(ctx, 10f), 0, 0, 0) })
            })
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.BOTTOM
                setPadding(0, Ui.dp(ctx, 22f), 0, 0)
                addView(W.number(ctx, value, 48f))
                addView(W.body(ctx, unit, 20f, R.color.text_primary).apply { setPadding(Ui.dp(ctx, 6f), 0, 0, Ui.dp(ctx, 4f)) })
            })
            addView(W.trendChip(ctx, trend, avgText ?: "sin media").apply {
                layoutParams = W.wrap().apply { topMargin = Ui.dp(ctx, 14f) }
            })
        }
    }
}
