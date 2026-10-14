package com.pulseapp.android

import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Locale

class RecoveryDetailActivity : AppCompatActivity() {

    private val recoveryCalculator = RecoveryCalculator()
    private val baselineProvider = BaselineProvider()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_recovery_detail)

        val backButton: TextView = findViewById(R.id.backButton)
        val recoveryPercentText: TextView = findViewById(R.id.recoveryPercentText)
        val recoveryLevelText: TextView = findViewById(R.id.recoveryLevelText)
        val recoveryExplanationText: TextView = findViewById(R.id.recoveryExplanationText)
        val hrvValueText: TextView = findViewById(R.id.hrvValueText)
        val hrvDeltaText: TextView = findViewById(R.id.hrvDeltaText)
        val hrvBaselineText: TextView = findViewById(R.id.hrvBaselineText)
        val rhrValueText: TextView = findViewById(R.id.rhrValueText)
        val rhrDeltaText: TextView = findViewById(R.id.rhrDeltaText)
        val rhrBaselineText: TextView = findViewById(R.id.rhrBaselineText)
        val trendList: LinearLayout = findViewById(R.id.trendList)

        backButton.setOnClickListener { finish() }

        lifecycleScope.launch {
            val db = AppDatabase.getInstance(this@RecoveryDetailActivity)
            val profile = db.userProfileDao().getOnce()
            val baseline = baselineProvider.compute(db)

            val metricsCalculator = MetricsCalculator(ageYears = profile?.ageYears() ?: 30)
            val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
            val summary = metricsCalculator.analyze(file)

            val sleepPlan = SleepPlanner().computeTonightPlan(db, summary.strain)
            val recoveryScore = recoveryCalculator.calculate(
                summary.avgHrv, summary.restingHr, summary.sleepMinutes,
                sleepPlan.totalNeedMinutes, summary.sleepEfficiencyPct, baseline
            )

            // Badge principal
            val (color, level) = when {
                recoveryScore >= 67 -> R.color.recovery_green to "ALTA"
                recoveryScore >= 34 -> R.color.alert_amber to "MEDIA"
                else -> R.color.alert_red to "BAJA"
            }
            recoveryPercentText.text = "$recoveryScore%"
            recoveryPercentText.setTextColor(ContextCompat.getColor(this@RecoveryDetailActivity, color))
            recoveryLevelText.text = level
            recoveryLevelText.setTextColor(ContextCompat.getColor(this@RecoveryDetailActivity, color))
            recoveryExplanationText.text = when (level) {
                "ALTA" -> "Tu cuerpo está bien recuperado. Buen día para empujar en el entreno."
                "MEDIA" -> "Recuperación moderada. Escucha a tu cuerpo antes de forzar hoy."
                else -> "Recuperación baja. Hoy sería buen día para bajar revoluciones."
            }

            // HRV
            hrvValueText.text = summary.avgHrv?.let { "%.0f ms".format(it) } ?: "-- ms"
            if (baseline != null && summary.avgHrv != null) {
                val diff = summary.avgHrv - baseline.avgHrv
                hrvDeltaText.text = (if (diff >= 0) "+%.0f ms".format(diff) else "%.0f ms".format(diff))
                hrvDeltaText.setTextColor(
                    ContextCompat.getColor(this@RecoveryDetailActivity, if (diff >= 0) R.color.recovery_green else R.color.alert_amber)
                )
                hrvBaselineText.text = "Línea base (${baseline.daysUsed} días): %.0f ms".format(baseline.avgHrv)
            } else {
                hrvBaselineText.text = "Línea base: necesitas ${BaselineProvider.MIN_DAYS_REQUIRED}+ días guardados"
            }

            // FC reposo
            rhrValueText.text = summary.restingHr?.let { "$it bpm" } ?: "-- bpm"
            if (baseline != null && summary.restingHr != null) {
                val diff = summary.restingHr - baseline.avgRestingHr
                rhrDeltaText.text = (if (diff >= 0) "+%.0f bpm".format(diff) else "%.0f bpm".format(diff))
                // FC reposo más baja que la base = bueno (verde); más alta = atención (ámbar)
                rhrDeltaText.setTextColor(
                    ContextCompat.getColor(this@RecoveryDetailActivity, if (diff <= 0) R.color.recovery_green else R.color.alert_amber)
                )
                rhrBaselineText.text = "Línea base (${baseline.daysUsed} días): %.0f bpm".format(baseline.avgRestingHr)
            } else {
                rhrBaselineText.text = "Línea base: necesitas ${BaselineProvider.MIN_DAYS_REQUIRED}+ días guardados"
            }

            // Tendencia: últimos días guardados
            val lastDays = db.dailyMetricsDao().getLastDays(7).sortedByDescending { it.date }
            val dateFmt = SimpleDateFormat("yyyy-MM-dd", Locale.US)
            val displayFmt = SimpleDateFormat("dd MMM", Locale("es"))

            if (lastDays.isEmpty()) {
                val emptyRow = TextView(this@RecoveryDetailActivity).apply {
                    text = "Todavía no hay días guardados. Vuelve en 1-2 días."
                    setTextColor(ContextCompat.getColor(this@RecoveryDetailActivity, R.color.text_secondary))
                    setPadding(32, 32, 32, 32)
                    textSize = 13f
                }
                trendList.addView(emptyRow)
            } else {
                lastDays.forEach { day ->
                    val row = LinearLayout(this@RecoveryDetailActivity).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        setPadding(32, 24, 32, 24)
                    }
                    val dateLabel = TextView(this@RecoveryDetailActivity).apply {
                        text = try { displayFmt.format(dateFmt.parse(day.date)!!) } catch (e: Exception) { day.date }
                        setTextColor(ContextCompat.getColor(this@RecoveryDetailActivity, R.color.text_primary))
                        textSize = 13f
                        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                    }
                    val hrvLabel = TextView(this@RecoveryDetailActivity).apply {
                        text = day.avgHrv?.let { "%.0f ms".format(it) } ?: "--"
                        setTextColor(ContextCompat.getColor(this@RecoveryDetailActivity, R.color.recovery_green))
                        textSize = 12f
                        setPadding(16, 0, 16, 0)
                    }
                    val rhrLabel = TextView(this@RecoveryDetailActivity).apply {
                        text = day.restingHr?.let { "$it bpm" } ?: "--"
                        setTextColor(ContextCompat.getColor(this@RecoveryDetailActivity, R.color.text_secondary))
                        textSize = 12f
                    }
                    row.addView(dateLabel)
                    row.addView(hrvLabel)
                    row.addView(rhrLabel)
                    trendList.addView(row)
                }
            }
        }
    }
}
