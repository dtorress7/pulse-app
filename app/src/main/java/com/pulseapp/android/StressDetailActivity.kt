package com.pulseapp.android

import android.os.Bundle
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.ui.SemicircularGaugeView
import com.pulseapp.android.ui.StressChartView
import kotlinx.coroutines.launch
import android.view.View

class StressDetailActivity : AppCompatActivity() {

    private val stressCalculator = StressCalculator()
    private val baselineProvider = BaselineProvider()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_stress_detail)

        val backButton: TextView = findViewById(R.id.backButton)
        val gauge: SemicircularGaugeView = findViewById(R.id.gauge)
        val detailScoreText: TextView = findViewById(R.id.detailScoreText)
        val detailLevelText: TextView = findViewById(R.id.detailLevelText)
        val detailTimeText: TextView = findViewById(R.id.detailTimeText)
        val fullDayChart: StressChartView = findViewById(R.id.fullDayChart)
        val interpretiveText: TextView = findViewById(R.id.interpretiveText)
        val barLow: View = findViewById(R.id.barLow)
        val barMedium: View = findViewById(R.id.barMedium)
        val barHigh: View = findViewById(R.id.barHigh)
        val lowTimeText: TextView = findViewById(R.id.lowTimeText)
        val mediumTimeText: TextView = findViewById(R.id.mediumTimeText)
        val highTimeText: TextView = findViewById(R.id.highTimeText)

        backButton.setOnClickListener { finish() }

        lifecycleScope.launch {
            val db = AppDatabase.getInstance(this@StressDetailActivity)
            val profile = db.userProfileDao().getOnce()
            val baseline = baselineProvider.compute(db)

            val metricsCalculator = MetricsCalculator(ageYears = profile?.ageYears() ?: 30)
            val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
            val summary = metricsCalculator.analyze(file)

            val stressSummary = stressCalculator.analyze(file, summary.restingHr, baseline)

            // Medidor + cabecera
            val currentScore = stressSummary.currentScore ?: 0f
            gauge.setValue(currentScore)
            detailScoreText.text = "%.1f".format(currentScore).replace('.', ',')
            detailLevelText.text = stressSummary.level
            detailLevelText.setTextColor(
                ContextCompat.getColor(this@StressDetailActivity, when (stressSummary.level) {
                    "ALTO" -> R.color.alert_amber
                    "MEDIO" -> R.color.recovery_green
                    else -> R.color.strain_blue
                })
            )
            detailTimeText.text = stressSummary.lastUpdateMinute?.let {
                "%02d:%02d".format(it / 60, it % 60)
            } ?: "Sin datos"

            // Gráfica del día completo (misma serie, solo cambia la altura del componente)
            fullDayChart.setSeries(stressSummary.series)
            fullDayChart.setSleepWindow(summary.sleepStartMinuteOfDay, summary.sleepEndMinuteOfDay)

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
            fullDayChart.setActivities(activityPeriods)
            

            // Texto interpretativo
            interpretiveText.text = when (stressSummary.level) {
                "BAJO" -> "Tu cuerpo indica estrés bajo. Esto indica que tu sistema cardiovascular está estable y cerca de su estado de reposo."
                "MEDIO" -> "Tu cuerpo indica estrés medio. Tu sistema nervioso está algo más activado de lo habitual, pero dentro de un rango normal."
                else -> "Tu cuerpo indica estrés alto. Tu FC y HRV muestran una activación notable respecto a tu línea base — puede deberse a esfuerzo físico, carga mental o falta de recuperación."
            }

            // Barra apilada: minutos por nivel (cada punto de la serie = 5 min)
            val lowCount = stressSummary.series.count { it.score < 1f }
            val mediumCount = stressSummary.series.count { it.score in 1f..1.999f }
            val highCount = stressSummary.series.count { it.score >= 2f }
            val total = (lowCount + mediumCount + highCount).coerceAtLeast(1)

            barLow.layoutParams = (barLow.layoutParams as LinearLayout.LayoutParams).apply { weight = lowCount.toFloat().coerceAtLeast(0.01f) }
            barMedium.layoutParams = (barMedium.layoutParams as LinearLayout.LayoutParams).apply { weight = mediumCount.toFloat().coerceAtLeast(0.01f) }
            barHigh.layoutParams = (barHigh.layoutParams as LinearLayout.LayoutParams).apply { weight = highCount.toFloat().coerceAtLeast(0.01f) }

            lowTimeText.text = formatMinutes(lowCount * 5)
            mediumTimeText.text = formatMinutes(mediumCount * 5)
            highTimeText.text = formatMinutes(highCount * 5)
        }
    }

    private fun formatMinutes(totalMinutes: Int): String {
        val h = totalMinutes / 60
        val m = totalMinutes % 60
        return "%d:%02d".format(h, m)
    }
}
