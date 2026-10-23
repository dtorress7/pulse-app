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

/** Detalle de Recuperación (rediseño): anillo grande, VFC/FC frente a tu media, componentes y 7 días. */
class RecoveryDetailActivity : AppCompatActivity() {

    private val recoveryCalculator = RecoveryCalculator()
    private val baselineProvider = BaselineProvider()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_recovery_detail)
        Ui.setupDetailHeader(this, "Recuperación")
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun t(id: Int): TextView = findViewById(id)

    private fun load() {
        lifecycleScope.launch {
            val ctx = this@RecoveryDetailActivity
            val db = AppDatabase.getInstance(ctx)
            val profile = db.userProfileDao().getOnce()
            val baseline = baselineProvider.compute(db)
            val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
            val summary = withContext(Dispatchers.IO) {
                MetricsCalculator(ageYears = profile?.ageYears() ?: 30).analyze(file)
            }
            val b = recoveryCalculator.breakdown(summary.avgHrv, summary.restingHr, baseline, summary.respiratoryRate)
            val colorRes = Ui.recoveryColor(b.total)
            val label = when {
                b.total >= 67 -> "Recuperado"
                b.total >= 34 -> "Moderada"
                else -> "Baja"
            }
            findViewById<CircularRingView>(R.id.recoveryRing).setValue(
                b.total / 100f, "${b.total}%", label, Ui.color(ctx, colorRes)
            )
            t(R.id.recoveryExplanationText).text = when {
                b.total >= 67 -> "Buena recuperación. Tu cuerpo está preparado para un día de esfuerzo alto."
                b.total >= 34 -> "Recuperación moderada. Escucha a tu cuerpo antes de forzar hoy."
                else -> "Recuperación baja. Hoy es buen día para bajar revoluciones y descansar."
            }

            // VFC frente a tu media
            t(R.id.hrvValueText).text = summary.avgHrv?.let { "%.0f".format(it) } ?: "--"
            if (baseline != null && summary.avgHrv != null) {
                val diff = summary.avgHrv - baseline.avgHrv
                t(R.id.hrvDeltaText).apply {
                    text = (if (diff >= 0) "▲ +" else "▼ −") + "%.0f".format(kotlin.math.abs(diff))
                    setTextColor(Ui.color(ctx, if (diff >= 0) R.color.recovery_green else R.color.alert_amber))
                }
                t(R.id.hrvBaselineText).text = "Tu media: %.0f ms".format(baseline.avgHrv)
            } else {
                t(R.id.hrvDeltaText).text = ""
                t(R.id.hrvBaselineText).text = "Media disponible con ${BaselineProvider.MIN_DAYS_REQUIRED}+ días"
            }

            // FC en reposo frente a tu media (más baja = mejor)
            t(R.id.rhrValueText).text = summary.restingHr?.toString() ?: "--"
            if (baseline != null && summary.restingHr != null) {
                val diff = summary.restingHr - baseline.avgRestingHr
                t(R.id.rhrDeltaText).apply {
                    text = (if (diff > 0) "▲ +" else "▼ −") + "%.0f".format(kotlin.math.abs(diff))
                    setTextColor(Ui.color(ctx, if (diff <= 0) R.color.recovery_green else R.color.alert_amber))
                }
                t(R.id.rhrBaselineText).text = "Tu media: %.0f lpm".format(baseline.avgRestingHr)
            } else {
                t(R.id.rhrDeltaText).text = ""
                t(R.id.rhrBaselineText).text = "Media disponible con ${BaselineProvider.MIN_DAYS_REQUIRED}+ días"
            }

            // Qué la compone
            val list: LinearLayout = findViewById(R.id.compositionList)
            list.removeAllViews()
            fun addRow(title: String, value: String, colorRes: Int, sub: String, bar: Float?) {
                val row = Ui.listRow(ctx, title, value, colorRes, sub)
                row.setPadding(0, Ui.dp(ctx, 12f), 0, Ui.dp(ctx, 6f))
                list.addView(row)
                if (bar != null) list.addView(Ui.progressBar(ctx, bar.coerceIn(0.02f, 1f), colorRes))
            }
            // VFC: lo que más pesa. Barra centrada en el 50 %: ±30 % de tu media llena o vacía la barra.
            val hrvPct = b.hrvDeltaPct
            addRow(
                "VFC frente a tu media  ·  decide la nota",
                hrvPct?.let { (if (it >= 0) "+" else "−") + "%.0f %%".format(kotlin.math.abs(it)) } ?: "--",
                if ((hrvPct ?: 0.0) >= -5) R.color.recovery_green else if (hrvPct!! >= -20) R.color.alert_amber else R.color.alert_red,
                if (b.personalBaseline) "Comparada con tu media ponderada de los últimos 14 días"
                else "Aún sin noches propias: se compara con tu media de WHOOP antes de PulseApp (88 ms)",
                hrvPct?.let { (0.5 + it / 60.0).toFloat() }
            )
            val rd = b.rhrDelta
            addRow(
                "FC en reposo frente a tu media  ·  ajuste pequeño",
                rd?.let { (if (it > 0) "+" else "−") + "%.0f lpm".format(kotlin.math.abs(it)) } ?: "--",
                if ((rd ?: 0.0) <= 2) R.color.recovery_green else R.color.alert_amber,
                "Cada 5 lpm por encima de tu media resta unos 3 puntos",
                null
            )
            addRow(
                "Respiración",
                if (b.respPenalty) "Alta" else if (summary.respiratoryRate != null) "Normal" else "--",
                if (b.respPenalty) R.color.alert_red else R.color.text_primary,
                if (b.respPenalty) "Mucho más alta que tu media: posible inicio de catarro o fatiga, resta puntos"
                else "Solo resta si sube claramente sobre lo normal",
                null
            )
            addRow(
                "Sueño", "No suma", R.color.text_secondary,
                "En tus 155 noches de WHOOP el sueño no cambia la nota: influye a través de la VFC",
                null
            )

            // Últimos 7 días (los días guardados se recalculan con la necesidad base de sueño)
            val days = db.dailyMetricsDao().getLastDays(6).sortedBy { it.date }
            val items = days.map { d ->
                val score = recoveryCalculator.breakdown(d.avgHrv, d.restingHr, baseline, d.respiratoryRate)
                    .total.takeIf { d.avgHrv != null }
                Triple(Ui.weekdayLetter(d.date), score?.toDouble(), Ui.recoveryColor(score ?: 0))
            } + Triple("Hoy", b.total.toDouble(), colorRes)
            Ui.fillWeekBars(findViewById(R.id.trendBars), items, 100.0) { "%.0f".format(it) }
            val valid = items.mapNotNull { it.second }
            t(R.id.trendAverageText).text = if (valid.size > 1) "Media ${valid.average().toInt()} %" else ""
            t(R.id.trendNote).text = if (days.isEmpty()) "Cada día guardado añade una barra. La línea base personal se activa con 3 días." else ""
        }
    }
}
