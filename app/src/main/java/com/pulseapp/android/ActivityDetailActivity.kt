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
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setItems(arrayOf("Editar actividad", "Eliminar actividad")) { _, which ->
                if (which == 0) {
                    startActivity(Intent(this, EditSessionActivity::class.java).putExtra(EditSessionActivity.EXTRA_SESSION_ID, sessionId))
                } else {
                    androidx.appcompat.app.AlertDialog.Builder(this)
                        .setTitle("¿Eliminar esta actividad?")
                        .setMessage("Se borra el registro de la actividad. El pulso guardado no se toca.")
                        .setPositiveButton("Eliminar") { _, _ ->
                            lifecycleScope.launch {
                                val db = AppDatabase.getInstance(this@ActivityDetailActivity)
                                db.activitySessionDao().getById(sessionId)?.let { db.activitySessionDao().delete(it) }
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

    private class Stats(val strain: Double, val steps: Int?, val kcal: Double, val avgHr: Int, val maxHr: Int, val seconds: Long)

    private fun load() {
        lifecycleScope.launch {
            val ctx = this@ActivityDetailActivity
            val db = AppDatabase.getInstance(ctx)
            val s = db.activitySessionDao().getById(sessionId) ?: run { finish(); return@launch }
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
                addView(bigStat(me.steps?.let { Ui.thousands(it.toLong()) } ?: "--", R.color.text_primary,
                    if (me.steps != null && avgSteps != null) trendOf(me.steps.toDouble(), avgSteps) else null,
                    avgSteps?.let { Ui.thousands(Math.round(it)) }, "Pasos de la actividad").apply { layoutParams = W.weight(1.15f) })
            })

            // Gráfica de pulso (medias de 10 s)
            val chartPts = samples.groupBy { it.timeMillis / 10_000 }.entries.sortedBy { it.key }
                .map { (k, v) -> k * 10_000 to Math.round(v.map { it.bpm }.average()).toInt() }
            var hrChart: ActivityHrChartView? = null
            if (chartPts.size >= 2) {
                content.addView(ActivityHrChartView(ctx).apply {
                    hrChart = this
                    setData(chartPts, s.startMillis, s.endMillis)
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Ui.dp(ctx, 360f)).apply {
                        topMargin = Ui.dp(ctx, 22f)
                    }
                })
            } else {
                content.addView(W.body(ctx, "No hay pulso guardado de esta actividad.", 14f).apply { setPadding(0, Ui.dp(ctx, 22f), 0, 0) })
            }

            // Rango típico + duración
            val durSec = (s.endMillis - s.startMillis) / 1000
            content.addView(LinearLayout(ctx).apply {
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
            content.addView(zoneBox)
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
                if (sel != null) hrChart?.setHighlights(zoneRuns[sel], Ui.color(ctx, zoneColors[sel]))
                else hrChart?.setHighlights(emptyList(), 0)
            }
            renderZones()
            content.addView(W.body(ctx, "Las zonas salen de tu reserva de FC, como en WHOOP: entre tu FC en reposo (${Formulas.zoneRestingHr()} lpm) y tu FC máxima (${Math.round(hrMax)} lpm), que puedes cambiar en Sobre mí.", 14.5f).apply {
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
            if (s.autoDetected) {
                content.addView(W.body(ctx, "Actividad detectada automáticamente. Puedes cambiar el deporte o la hora desde ···", 14f).apply {
                    setPadding(0, Ui.dp(ctx, 18f), 0, 0)
                })
            }
        }
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
