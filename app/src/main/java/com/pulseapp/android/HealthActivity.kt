package com.pulseapp.android

import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.res.ResourcesCompat
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.ui.StressChartView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.sqrt

/**
 * Pestaña Salud (rediseño): señales vitales de la noche comparadas con tu rango habitual
 * (media ± desviación de los últimos 14 días guardados), pasos, calorías, VO2 máx y estrés.
 */
class HealthActivity : AppCompatActivity() {

    private data class Vital(
        val label: String, val value: Double?, val unit: String, val decimals: Int,
        val history: List<Double>, val emptyNote: String
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_health)
        Ui.setupTabBar(this, Ui.Tab.HEALTH)
        findViewById<View>(R.id.stressCard).setOnClickListener {
            startActivity(Intent(this, StressDetailActivity::class.java))
        }
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun load() {
        lifecycleScope.launch {
            val ctx = this@HealthActivity
            val db = AppDatabase.getInstance(ctx)
            val profile = db.userProfileDao().getOnce()
            val age = profile?.ageYears() ?: 30
            val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
            val summary = withContext(Dispatchers.IO) { MetricsCalculator(ageYears = age).analyze(file) }
            val days = db.dailyMetricsDao().getLastDays(14)

            val vitals = listOf(
                Vital("VFC", summary.avgHrv, "ms", 0, days.mapNotNull { it.avgHrv }, "Sin RR esta noche"),
                Vital("FC reposo", summary.restingHr?.toDouble(), "lpm", 0, days.mapNotNull { it.restingHr?.toDouble() }, "Sin noche detectada"),
                Vital("Respiración", summary.respiratoryRate, "rpm", 1, days.mapNotNull { it.respiratoryRate }, "Sin datos"),
                Vital("Temp. piel", null, "°C", 1, emptyList(), "Pendiente de la pulsera")
            )

            var withRange = 0
            var inRange = 0
            val grid: LinearLayout = findViewById(R.id.vitalsGrid)
            grid.removeAllViews()
            vitals.chunked(2).forEachIndexed { rowIndex, pair ->
                val row = LinearLayout(ctx).apply {
                    orientation = LinearLayout.HORIZONTAL
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                        if (rowIndex > 0) topMargin = Ui.dp(ctx, 12f)
                    }
                }
                pair.forEachIndexed { i, v ->
                    val range = rangeOf(v.history)
                    val status: Boolean? = if (range != null && v.value != null) v.value in range.first..range.second else null
                    if (status != null) { withRange++; if (status) inRange++ }
                    row.addView(vitalTile(v, range, status).apply {
                        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f).apply {
                            if (i == 0) marginEnd = Ui.dp(ctx, 6f) else marginStart = Ui.dp(ctx, 6f)
                        }
                    })
                }
                grid.addView(row)
            }

            val statusTitle = findViewById<TextView>(R.id.statusTitle)
            val statusIcon = findViewById<ImageView>(R.id.statusIcon)
            when {
                withRange == 0 -> {
                    statusTitle.text = "Calibrando"
                    statusTitle.setTextColor(Ui.color(ctx, R.color.text_primary))
                    statusIcon.setColorFilter(Ui.color(ctx, R.color.text_secondary))
                    findViewById<TextView>(R.id.statusSub).text = "Tu rango habitual aparece con ${BaselineProvider.MIN_DAYS_REQUIRED} noches guardadas"
                }
                inRange == withRange -> {
                    statusTitle.text = "Dentro del rango"
                    statusTitle.setTextColor(Ui.color(ctx, R.color.recovery_green))
                    statusIcon.setColorFilter(Ui.color(ctx, R.color.recovery_green))
                    findViewById<TextView>(R.id.statusSub).text = "$inRange de $withRange señales en tu rango habitual"
                }
                else -> {
                    statusTitle.text = "Fuera del rango"
                    statusTitle.setTextColor(Ui.color(ctx, R.color.alert_amber))
                    statusIcon.setColorFilter(Ui.color(ctx, R.color.alert_amber))
                    findViewById<TextView>(R.id.statusSub).text = "$inRange de $withRange señales en tu rango habitual"
                }
            }

            // Pasos, calorías, VO2 máx
            val extras: LinearLayout = findViewById(R.id.extrasList)
            extras.removeAllViews()
            val steps = withContext(Dispatchers.IO) { Ui.stepsToday(ctx) }
            extras.addView(Ui.listRow(ctx, "Pasos", if (steps > 0) Ui.thousands(steps.toLong()) else "--", R.color.text_primary))
            extras.addView(Ui.hairline(ctx))
            val kcal = profile?.let {
                val now = java.util.Calendar.getInstance()
                val elapsed = now.get(java.util.Calendar.HOUR_OF_DAY) * 60.0 + now.get(java.util.Calendar.MINUTE)
                val activityKcal = db.activitySessionDao().getAll().filter { s -> s.startMillis >= Ui.todayStartMillis() }.sumOf { s -> s.caloriesKcal }
                CalorieCalculator().estimateDailyTotal(elapsed, activityKcal, age, it.weightKg, it.heightCm, it.sex)
            }
            extras.addView(Ui.listRow(ctx, "Calorías", kcal?.let { Ui.thousands(it.toLong()) + " kcal" } ?: "--", R.color.text_primary,
                if (profile == null) "Rellena Sobre mí" else null))
            extras.addView(Ui.hairline(ctx))
            extras.addView(Ui.listRow(ctx, "VO₂ máx", profile?.vo2Max?.let { "%.0f".format(it) } ?: "--", R.color.text_primary, "Se actualiza los martes"))
            extras.addView(Ui.hairline(ctx))
            extras.addView(Ui.listRow(ctx, "FC media de hoy", summary.avgHr?.let { "$it lpm" } ?: "--", R.color.text_primary))

            // Estrés
            val baseline = BaselineProvider().compute(db)
            val stress = withContext(Dispatchers.IO) { StressCalculator().analyze(file, summary.restingHr, baseline) }
            findViewById<TextView>(R.id.stressScoreText).text = stress.currentScore?.let { Ui.comma(it.toDouble()) } ?: "--"
            findViewById<TextView>(R.id.stressLevelText).apply {
                text = if (stress.currentScore != null) stress.level else ""
                setTextColor(Ui.color(ctx, Ui.stressColor(stress.level)))
            }
            findViewById<StressChartView>(R.id.stressChart).apply {
                setSeries(stress.series)
                setSleepWindow(summary.sleepStartMinuteOfDay, summary.sleepEndMinuteOfDay)
            }
        }
    }

    /** Rango habitual = media ± 1 desviación (mínimo ±5 % de la media). Null con menos de 3 días. */
    private fun rangeOf(history: List<Double>): Pair<Double, Double>? {
        if (history.size < BaselineProvider.MIN_DAYS_REQUIRED) return null
        val mean = history.average()
        val sd = sqrt(history.map { (it - mean) * (it - mean) }.average())
        val half = maxOf(sd, mean * 0.05)
        return (mean - half) to (mean + half)
    }

    private fun fmt(v: Double, decimals: Int) = if (decimals == 0) "%.0f".format(v) else Ui.comma(v, decimals)

    private fun vitalTile(v: Vital, range: Pair<Double, Double>?, inRange: Boolean?): LinearLayout {
        val ctx = this
        val valueColor = when (inRange) {
            true -> R.color.recovery_green
            false -> R.color.alert_amber
            null -> R.color.text_primary
        }
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundResource(R.drawable.bg_card)
            val p = Ui.dp(ctx, 16f)
            setPadding(p, p, p, p)

            addView(TextView(ctx).apply {
                text = v.label.uppercase()
                textSize = 12f
                letterSpacing = 0.14f
                typeface = ResourcesCompat.getFont(ctx, R.font.barlow_condensed_semibold)
                setTextColor(Ui.color(ctx, R.color.text_secondary))
            })
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.BOTTOM
                setPadding(0, Ui.dp(ctx, 10f), 0, 0)
                addView(TextView(ctx).apply {
                    text = v.value?.let { fmt(it, v.decimals) } ?: "–"
                    textSize = 32f
                    typeface = Ui.boldCondensed(ctx)
                    setTextColor(Ui.color(ctx, valueColor))
                    includeFontPadding = false
                })
                addView(TextView(ctx).apply {
                    text = v.unit
                    textSize = 12f
                    setTextColor(Ui.color(ctx, R.color.text_secondary))
                    setPadding(Ui.dp(ctx, 4f), 0, 0, Ui.dp(ctx, 2f))
                })
            })
            addView(TextView(ctx).apply {
                text = when {
                    v.value == null -> v.emptyNote
                    range != null -> "Tu rango ${fmt(range.first, v.decimals)}–${fmt(range.second, v.decimals)}"
                    else -> "Rango con ${BaselineProvider.MIN_DAYS_REQUIRED} noches"
                }
                textSize = 12f
                setTextColor(Ui.color(ctx, R.color.text_secondary))
                setPadding(0, Ui.dp(ctx, 8f), 0, 0)
            })
            if (inRange != null) addView(TextView(ctx).apply {
                text = if (inRange) "● DENTRO DEL RANGO" else "● FUERA DEL RANGO"
                textSize = 10f
                letterSpacing = 0.12f
                typeface = ResourcesCompat.getFont(ctx, R.font.barlow_condensed_semibold)
                setTextColor(Ui.color(ctx, valueColor))
                setPadding(0, Ui.dp(ctx, 8f), 0, 0)
            })
        }
    }
}
