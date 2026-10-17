package com.pulseapp.android

import android.os.Bundle
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.ui.CircularRingView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/** Pestaña Sueño (rediseño): rendimiento, fases, necesidad, planificador, consistencia/eficiencia e histórico. */
class SleepDetailActivity : AppCompatActivity() {

    private val es = Locale("es", "ES")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_sleep_detail)
        Ui.setupTabBar(this, Ui.Tab.SLEEP)

        val yesterday = Calendar.getInstance().apply { add(Calendar.DAY_OF_MONTH, -1) }
        val today = Calendar.getInstance()
        findViewById<TextView>(R.id.sleepNightText).text =
            "Noche del ${yesterday.get(Calendar.DAY_OF_MONTH)} al ${SimpleDateFormat("d 'de' MMMM", es).format(today.time)}"
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun t(id: Int): TextView = findViewById(id)

    private fun load() {
        lifecycleScope.launch {
            val db = AppDatabase.getInstance(this@SleepDetailActivity)
            val profile = db.userProfileDao().getOnce()
            val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
            val summary = withContext(Dispatchers.IO) {
                MetricsCalculator(ageYears = profile?.ageYears() ?: 30).analyze(file)
            }

            // Misma fórmula que Inicio (base + esfuerzo + deuda)
            val wake = SleepPlanner.wakeMinute(this@SleepDetailActivity)
            val plan = SleepPlanner().computeTonightPlan(db, summary.strain, wake / 60, wake % 60)
            // Lo que necesitabas la noche que acabas de dormir (con el esfuerzo de ayer), como WHOOP
            val need = SleepPlanner().planForLastNight(db, summary).totalNeedMinutes
            val slept = summary.sleepMinutes
            val perf = slept?.let { (it * 100 / need.coerceAtLeast(1)).coerceIn(0, 100) }

            findViewById<CircularRingView>(R.id.sleepPerfRing).setValue(
                (perf ?: 0) / 100f, perf?.let { "$it%" } ?: "--", "Rendimiento",
                Ui.color(this@SleepDetailActivity, R.color.sleep_blue)
            )
            t(R.id.sleptText).text = slept?.let { Ui.hm(it) } ?: "--"
            t(R.id.needText).text = Ui.hm(need)
            t(R.id.inBedText).text = summary.timeInBedMinutes?.let { Ui.hm(it) } ?: "--"

            // Fases con movimiento + pulso + VFC (SleepStager). Sin movimiento esa noche solo despierto / dormido.
            val stages = summary.stages
            val hypnogram = findViewById<com.pulseapp.android.ui.HypnogramView>(R.id.hypnogram)
            if (stages != null) {
                hypnogram.visibility = android.view.View.VISIBLE
                hypnogram.setStages(stages.startMillis, stages.stages)
                t(R.id.stageAwakeText).text = Ui.hm(stages.awakeMinutes)
                t(R.id.stageLightText).text = Ui.hm(stages.lightMinutes)
                t(R.id.stageRemText).text = Ui.hm(stages.remMinutes)
                t(R.id.stageDeepText).text = Ui.hm(stages.deepMinutes)
                Ui.fillStackedBar(
                    findViewById(R.id.stageBar),
                    listOf(
                        stages.awakeMinutes.toFloat() to R.color.stage_awake,
                        stages.lightMinutes.toFloat() to R.color.stage_light,
                        stages.deepMinutes.toFloat() to R.color.stage_deep,
                        stages.remMinutes.toFloat() to R.color.stage_rem
                    )
                )
                t(R.id.stagesNote).text = "Dormido ${Ui.hm(stages.asleepMinutes)} · ${stages.awakenings} despertares. " +
                    "Fases estimadas con el movimiento, el pulso y la VFC de la pulsera; es una primera versión que se afinará con más noches."
            } else {
                hypnogram.visibility = android.view.View.GONE
                val awake = summary.awakeMinutes
                t(R.id.stageAwakeText).text = awake?.let { Ui.hm(it) } ?: "–"
                t(R.id.stageLightText).text = "–"
                t(R.id.stageRemText).text = "–"
                t(R.id.stageDeepText).text = "–"
                Ui.fillStackedBar(
                    findViewById(R.id.stageBar),
                    listOf((awake ?: 0).toFloat() to R.color.stage_awake, (slept ?: 0).toFloat() to R.color.sleep_blue)
                )
                t(R.id.stagesNote).text = if (slept != null) {
                    "Dormido ${Ui.hm(slept)}. Para ver Ligero, REM y Profundo, activa «Movimiento y pasos» en Mi WHOOP antes de dormir " +
                        "y deja el móvil cerca (carga la pulsera al menos al 30 %)."
                } else {
                    "Todavía no hay una noche detectada. Duerme con la pulsera conectada y aparecerá aquí."
                }
            }

            // Necesidad
            t(R.id.needBaseText).text = Ui.hm(plan.baselineMinutes)
            t(R.id.needStrainText).text = "+" + Ui.hm(plan.strainAdjustmentMinutes)
            t(R.id.needDebtText).text = "+" + Ui.hm(plan.debtAdjustmentMinutes)
            t(R.id.needNapText).text = "−" + Ui.hm(plan.napAdjustmentMinutes)
            t(R.id.needTotalText).text = Ui.hm(need)

            // Planificador: ventana de ±15 min alrededor de la hora sugerida
            val bed = plan.suggestedBedtime
            if (bed != null) {
                val (h, m) = bed.split(":").map { it.toInt() }
                fun shift(delta: Int): String {
                    val total = ((h * 60 + m + delta) % 1440 + 1440) % 1440
                    return "%02d:%02d".format(total / 60, total % 60)
                }
                t(R.id.bedWindowText).text = "${shift(-15)} – ${shift(15)}"
                t(R.id.bedTimeText).text = bed
                t(R.id.plannerNote).text = "Con ese horario cubres tus ${Ui.hm(need)} y despiertas a las %02d:%02d.".format(wake / 60, wake % 60)
            }

            // Eficiencia y consistencia
            val eff = summary.sleepEfficiencyPct
            t(R.id.efficiencyText).text = eff?.let { "$it%" } ?: "--"
            findViewById<LinearLayout>(R.id.efficiencyCard).apply {
                if (childCount > 2) removeViewAt(2)
                addView(Ui.progressBar(this@SleepDetailActivity, (eff ?: 0) / 100f, R.color.sleep_blue))
            }
            val recentStarts = db.dailyMetricsDao().getLastDays(7).mapNotNull { it.sleepStartMinuteOfDay }
            val consistency: Int? = Formulas.sleepConsistency(recentStarts)
            t(R.id.consistencyText).text = consistency?.let { "$it%" } ?: "--"
            findViewById<LinearLayout>(R.id.consistencyCard).apply {
                if (childCount > 2) removeViewAt(2)
                if (consistency != null) {
                    addView(Ui.progressBar(this@SleepDetailActivity, consistency / 100f, R.color.sleep_blue))
                } else {
                    addView(TextView(this@SleepDetailActivity).apply {
                        text = "Necesita 3 noches"
                        textSize = 12f
                        setTextColor(Ui.color(this@SleepDetailActivity, R.color.text_secondary))
                    })
                }
            }

            // Calificación como WHOOP (ajustada a tus 155 noches): horas vs necesidad + eficiencia + regularidad
            t(R.id.sleepScoreText).text = if (perf != null) {
                "${Formulas.sleepScore(perf, eff, consistency)}%"
            } else "--"
            t(R.id.sleepDebtText).text = Ui.hm(plan.debtAdjustmentMinutes)

            // Estrés durante el sueño: % de la noche con nivel medio o alto
            val start = summary.sleepStartMinuteOfDay
            val end = summary.sleepEndMinuteOfDay
            if (start != null && end != null) {
                val baseline = BaselineProvider().compute(db)
                val stress = withContext(Dispatchers.IO) { StressCalculator().analyze(file, summary.restingHr, baseline) }
                val night = stress.series.filter {
                    if (start <= end) it.minuteOfDay in start..end else it.minuteOfDay >= start || it.minuteOfDay <= end
                }
                t(R.id.sleepStressText).text = if (night.isNotEmpty()) {
                    "${night.count { it.score >= 1f } * 100 / night.size}%"
                } else "--"
            } else {
                t(R.id.sleepStressText).text = "--"
            }

            // Últimas noches
            val history: LinearLayout = findViewById(R.id.historyList)
            history.removeAllViews()
            val days = db.dailyMetricsDao().getLastDays(7).sortedByDescending { it.date }
            if (days.isEmpty()) {
                history.addView(Ui.emptyText(this@SleepDetailActivity, "Todavía no hay noches guardadas. Se guarda una cada día a medianoche."))
            } else {
                val iso = SimpleDateFormat("yyyy-MM-dd", Locale.US)
                val pretty = SimpleDateFormat("EEEE d", es)
                days.forEachIndexed { i, day ->
                    if (i > 0) history.addView(Ui.hairline(this@SleepDetailActivity))
                    val label = try { pretty.format(iso.parse(day.date)!!).replaceFirstChar { it.uppercase() } } catch (e: Exception) { day.date }
                    val sub = day.sleepEfficiencyPct?.let { "Eficiencia $it%" }
                    history.addView(Ui.listRow(this@SleepDetailActivity, label, day.sleepMinutes?.let { Ui.hm(it) } ?: "–", R.color.sleep_blue, sub))
                }
            }
        }
    }
}
