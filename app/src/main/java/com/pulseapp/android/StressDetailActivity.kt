package com.pulseapp.android

import android.os.Bundle
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.ui.SemicircularGaugeView
import com.pulseapp.android.ui.StressChartView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Calendar

/** Detalle del Monitor de Estrés (rediseño): medidor, gráfica del día y reparto de tiempo. */
class StressDetailActivity : AppCompatActivity() {

    private val stressCalculator = StressCalculator()
    private val baselineProvider = BaselineProvider()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_stress_detail)
        Ui.setupDetailHeader(this, "Monitor de estrés")
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun t(id: Int): TextView = findViewById(id)

    private fun load() {
        lifecycleScope.launch {
            val ctx = this@StressDetailActivity
            val db = AppDatabase.getInstance(ctx)
            val profile = db.userProfileDao().getOnce()
            val baseline = baselineProvider.compute(db)
            val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
            val summary = withContext(Dispatchers.IO) {
                MetricsCalculator(ageYears = profile?.ageYears() ?: 30).analyze(file)
            }
            val stress = withContext(Dispatchers.IO) { stressCalculator.analyze(file, summary.restingHr, baseline) }

            val score = stress.currentScore
            findViewById<SemicircularGaugeView>(R.id.gauge).setValue(score ?: 0f)
            t(R.id.detailScoreText).text = score?.let { Ui.comma(it.toDouble()) } ?: "--"
            t(R.id.detailLevelText).apply {
                text = if (score != null) stress.level else "Sin datos"
                setTextColor(Ui.color(ctx, Ui.stressColor(stress.level)))
            }
            t(R.id.detailTimeText).text = stress.lastUpdateMinute?.let {
                "Actualizado a las %02d:%02d".format(it / 60, it % 60)
            } ?: if (baseline == null) "Necesita pulso de hoy y tu FC en reposo" else ""

            val chart: StressChartView = findViewById(R.id.fullDayChart)
            chart.setSeries(stress.series)
            chart.setSleepWindow(summary.sleepStartMinuteOfDay, summary.sleepEndMinuteOfDay)
            val today = db.activitySessionDao().getAll().filter { it.startMillis >= Ui.todayStartMillis() }
            chart.setActivities(today.map {
                val s = Calendar.getInstance().apply { timeInMillis = it.startMillis }
                val e = Calendar.getInstance().apply { timeInMillis = it.endMillis }
                com.pulseapp.android.ui.ActivityPeriod(
                    s.get(Calendar.HOUR_OF_DAY) * 60 + s.get(Calendar.MINUTE),
                    e.get(Calendar.HOUR_OF_DAY) * 60 + e.get(Calendar.MINUTE)
                )
            })

            t(R.id.interpretiveText).text = when {
                score == null -> "Aún no hay suficientes datos de hoy para calcular tu estrés."
                stress.level == "BAJO" -> "Tu cuerpo indica estrés bajo. Tu sistema cardiovascular está estable y cerca de su estado de reposo."
                stress.level == "MEDIO" -> "Tu cuerpo indica estrés medio. Es normal tras moverte o con carga mental; si sigue así en reposo, haz una pausa."
                else -> "Tu cuerpo indica estrés alto. Si no estás entrenando, prueba unos minutos de respiración lenta."
            }

            // Reparto del día (cada punto = 5 min)
            val low = stress.series.count { it.score < 1f } * 5
            val mid = stress.series.count { it.score >= 1f && it.score < 2f } * 5
            val high = stress.series.count { it.score >= 2f } * 5
            Ui.fillStackedBar(
                findViewById(R.id.stressBar),
                listOf(low.toFloat() to R.color.strain_blue, mid.toFloat() to R.color.recovery_green, high.toFloat() to R.color.alert_amber)
            )
            t(R.id.lowTimeText).text = Ui.hm(low)
            t(R.id.mediumTimeText).text = Ui.hm(mid)
            t(R.id.highTimeText).text = Ui.hm(high)
        }
    }
}
