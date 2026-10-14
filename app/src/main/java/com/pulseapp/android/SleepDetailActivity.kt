package com.pulseapp.android

import android.os.Bundle
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Locale

class SleepDetailActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_sleep_detail)

        val backButton: TextView = findViewById(R.id.backButton)
        val performancePercentText: TextView = findViewById(R.id.performancePercentText)
        val hoursVsNeedText: TextView = findViewById(R.id.hoursVsNeedText)
        val sleepDebtText: TextView = findViewById(R.id.sleepDebtText)
        val historyList: LinearLayout = findViewById(R.id.historyList)

        backButton.setOnClickListener { finish() }

        lifecycleScope.launch {
            val db = AppDatabase.getInstance(this@SleepDetailActivity)
            val profile = db.userProfileDao().getOnce()

           val metricsCalculator = MetricsCalculator(ageYears = profile?.ageYears() ?: 30)
            val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
            val summary = metricsCalculator.analyze(file)

            // Misma fórmula exacta que la tarjeta de Inicio (Baseline + Strain + Deuda)
            val sleepPlan = SleepPlanner().computeTonightPlan(db, summary.strain)
            val targetMinutes = sleepPlan.totalNeedMinutes
            val sleptMinutes = summary.sleepMinutes ?: 0
            val performancePct = if (targetMinutes > 0) {
                ((sleptMinutes.toFloat() / targetMinutes) * 100).toInt().coerceIn(0, 150)
            } else 0

            performancePercentText.text = if (summary.sleepMinutes != null) "$performancePct%" else "--%"
           hoursVsNeedText.text = if (summary.sleepMinutes != null) {
                val base = "${sleptMinutes / 60}h ${sleptMinutes % 60}min de ${targetMinutes / 60}h ${targetMinutes % 60}min"
                val extra = if (summary.timeInBedMinutes != null && summary.awakeMinutes != null) {
                    "\nTotal en cama: ${summary.timeInBedMinutes!! / 60}h ${summary.timeInBedMinutes!! % 60}min " +
                    "(${summary.awakeMinutes!! / 60}h ${summary.awakeMinutes!! % 60}min despierto)"
                } else ""
                base + extra
            } else {
                "Sin ventana de sueño detectada todavía"
            }

            val debtMinutes = (targetMinutes - sleptMinutes).coerceAtLeast(0)
            sleepDebtText.text = if (summary.sleepMinutes != null) {
                "${debtMinutes / 60}h ${debtMinutes % 60}min"
            } else {
                "--"
            }
            val efficiencyText: TextView = findViewById(R.id.efficiencyText)
            val consistencyText: TextView = findViewById(R.id.consistencyText)
            val sleepStressText: TextView = findViewById(R.id.sleepStressText)
            efficiencyText.text = summary.sleepEfficiencyPct?.let { "$it%" } ?: "--%"

            // Consistencia: compara la hora de inicio de sueño de los últimos días.
            // Cuanto menor la variación entre noches, más alta la puntuación.
            val recentDays = db.dailyMetricsDao().getLastDays(7)
                .mapNotNull { it.sleepStartMinuteOfDay }
            val consistencyPct: Int? = if (recentDays.size >= 3) {
                val avg = recentDays.average()
                val variance = recentDays.map { (it - avg) * (it - avg) }.average()
                val stdDevMinutes = kotlin.math.sqrt(variance)
                val pct = (100 - (stdDevMinutes / 120.0 * 100)).coerceIn(0.0, 100.0).toInt()
                consistencyText.text = "$pct%"
                pct
            } else {
                consistencyText.text = "Faltan días"
                null
            }

            // Sleep Score combinado: Horas vs necesidad (50%) + Eficiencia (30%) + Consistencia (20%)
            val sleepScoreText: TextView = findViewById(R.id.sleepScoreText)
            val effPct = summary.sleepEfficiencyPct
            if (summary.sleepMinutes != null) {
                val performanceComponent = performancePct.coerceIn(0, 100)
                val efficiencyComponent = effPct ?: 70
                val consistencyComponent = consistencyPct ?: 70
                val score = (performanceComponent * 0.5 + efficiencyComponent * 0.3 + consistencyComponent * 0.2).toInt()
                sleepScoreText.text = "$score%"
            } else {
                sleepScoreText.text = "--%"
            }
            // Estrés en el sueño: % de puntos de la ventana nocturna con score MEDIO o ALTO
            if (summary.sleepStartMinuteOfDay != null && summary.sleepEndMinuteOfDay != null) {
                val baselineProvider = BaselineProvider()
                val baseline = baselineProvider.compute(db)
                val stressSummary = StressCalculator().analyze(file, summary.restingHr, baseline)

                val nightPoints = stressSummary.series.filter {
                    it.minuteOfDay >= summary.sleepStartMinuteOfDay!! || it.minuteOfDay <= summary.sleepEndMinuteOfDay!!
                }
                if (nightPoints.isNotEmpty()) {
                    val stressedCount = nightPoints.count { it.score >= 1f }
                    val pct = ((stressedCount.toDouble() / nightPoints.size) * 100).toInt()
                    sleepStressText.text = "$pct%"
                } else {
                    sleepStressText.text = "--%"
                }
            } else {
                sleepStressText.text = "--%"
            }
            // Histórico de los últimos 7 días guardados
            val lastDays = db.dailyMetricsDao().getLastDays(7).sortedByDescending { it.date }
            val dateFmt = SimpleDateFormat("yyyy-MM-dd", Locale.US)
            val displayFmt = SimpleDateFormat("dd MMM", Locale("es"))

            if (lastDays.isEmpty()) {
                val emptyRow = TextView(this@SleepDetailActivity).apply {
                    text = "Todavía no hay noches guardadas."
                    setTextColor(ContextCompat.getColor(this@SleepDetailActivity, R.color.text_secondary))
                    setPadding(32, 32, 32, 32)
                    textSize = 13f
                }
                historyList.addView(emptyRow)
            } else {
                lastDays.forEach { day ->
                    val row = LinearLayout(this@SleepDetailActivity).apply {
                        orientation = LinearLayout.HORIZONTAL
                        setPadding(32, 24, 32, 24)
                    }
                    val dateLabel = TextView(this@SleepDetailActivity).apply {
                        text = try { displayFmt.format(dateFmt.parse(day.date)!!) } catch (e: Exception) { day.date }
                        setTextColor(ContextCompat.getColor(this@SleepDetailActivity, R.color.text_primary))
                        textSize = 13f
                        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                    }
                    val durationLabel = TextView(this@SleepDetailActivity).apply {
                        text = day.sleepMinutes?.let { "${it / 60}h ${it % 60}min" } ?: "Sin datos"
                        setTextColor(ContextCompat.getColor(this@SleepDetailActivity, R.color.sleep_blue))
                        textSize = 13f
                    }
                    row.addView(dateLabel)
                    row.addView(durationLabel)
                    historyList.addView(row)
                }
            }
        }
    }
}
