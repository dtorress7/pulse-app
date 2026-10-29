package com.pulseapp.android

import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.ui.CircularRingView
import com.pulseapp.android.ui.WeekChartView
import kotlinx.coroutines.launch
import java.time.LocalDate

/**
 * Recuperación con el aspecto de WHOOP (29/10, copiado de su pantalla "Hoy → Recuperación"): anillo grande, tarjeta con VFC,
 * FC en reposo, frecuencia respiratoria y calificación del sueño (valor, flecha y tu media de 30 días debajo) y la leyenda
 * "Hoy vs. los últimos 30 días". Debajo, cómo se calcula y la recuperación de la semana. Abre el día elegido en Inicio.
 */
class RecoveryDetailActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_DAY_OFFSET = "day_offset"
    }

    private var offset = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_sleep_detail)
        window.statusBarColor = Ui.color(this, R.color.w_bg_top)
        offset = intent.getIntExtra(EXTRA_DAY_OFFSET, 0)
        Ui.setupDetailHeader(this, if (offset == 0) "HOY" else W.dateTitle(LocalDate.now().plusDays(offset.toLong())))
        Ui.setupTabBar(this, Ui.Tab.HOME)
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun dp(v: Float) = Ui.dp(this, v)

    private fun load() {
        lifecycleScope.launch {
            val ctx = this@RecoveryDetailActivity
            val d = HomeDataLoader(ctx).load(offset)
            val day = d.day
            val rec = day.recovery
            val prev = d.records.filter { it.date < d.date && it.date >= d.date.minusDays(30) }
            fun avgD(f: (DayRecord) -> Double?): Double? = prev.mapNotNull(f).takeIf { it.isNotEmpty() }?.average()
            val hrvAvg = avgD { it.hrv }
            val rhrAvg = avgD { it.rhr?.toDouble() }
            val respAvg = avgD { it.resp }
            val scoreAvg = avgD { it.sleepScore?.toDouble() }

            val content = findViewById<LinearLayout>(R.id.detailContent)
            content.removeAllViews()

            // ---------- Anillo ----------
            content.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(0, dp(14f), 0, 0)
                addView(CircularRingView(ctx).apply {
                    strokeRatio = 0.055f; numberRatio = 0.26f; suffixRatio = 0.5f; suffixSameColor = true; labelRatio = 0.052f
                    topText = "PULSE"
                    setTrackColor(Ui.color(ctx, R.color.w_track)); setLabelColor(Ui.color(ctx, R.color.text_primary))
                    setValue((rec ?: 0) / 100f, rec?.let { "$it%" } ?: "--", "Recuperación",
                        Ui.color(ctx, rec?.let { W.recoveryColor(it) } ?: R.color.w_recovery_high))
                    layoutParams = LinearLayout.LayoutParams(dp(260f), dp(260f))
                })
            })

            // ---------- Las 4 métricas, como WHOOP ----------
            content.addView(W.card(ctx, 18f).apply {
                addView(W.valueRow(ctx, R.drawable.ic_hrv, "Variabilidad de la\nfrecuencia cardíaca", day.hrv?.let { "%.0f".format(it) } ?: "--",
                    W.trendOf(day.hrv, hrvAvg, 1.0), true, hrvAvg?.let { "%.0f".format(it) }))
                addView(W.divider(ctx))
                addView(W.valueRow(ctx, R.drawable.ic_heart, "Frecuencia cardíaca\nen reposo", day.rhr?.toString() ?: "--",
                    W.trendOf(day.rhr?.toDouble(), rhrAvg, 0.5), false, rhrAvg?.let { "%.0f".format(it) }))
                addView(W.divider(ctx))
                addView(W.valueRow(ctx, R.drawable.ic_lungs, "Frecuencia\nrespiratoria", day.resp?.let { Ui.comma(it) } ?: "--",
                    W.trendOf(day.resp, respAvg, 0.05), false, respAvg?.let { Ui.comma(it) }))
                addView(W.divider(ctx))
                addView(W.valueRow(ctx, R.drawable.ic_moon, "Calificación\ndel sueño", day.sleepScore?.let { "$it %" } ?: "--",
                    W.trendOf(day.sleepScore?.toDouble(), scoreAvg, 0.5), true, scoreAvg?.let { "%.0f %%".format(it) }))
                addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    background = W.rounded(ctx, R.color.w_bg_bottom, 8f)
                    setPadding(dp(16f), dp(12f), dp(16f), dp(12f))
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(12f) }
                    addView(W.icon(ctx, R.drawable.ic_triangle_up, 9f, R.color.w_mint))
                    addView(W.icon(ctx, R.drawable.ic_triangle_down, 9f, R.color.w_trend_amber))
                    addView(W.body(ctx, if (offset == 0) "Hoy vs. los últimos 30 días" else "Este día vs. los 30 días anteriores", 14.5f, R.color.text_primary)
                        .apply { setPadding(dp(8f), 0, 0, 0) })
                })
            })

            // ---------- Cómo se calcula ----------
            content.addView(TextView(ctx).apply {
                text = "Cómo se calcula"; setTextAppearance(R.style.HeadingW); setPadding(0, dp(34f), 0, dp(2f))
            })
            content.addView(W.card(ctx, 14f).apply {
                val s = d.summary
                if (d.isToday && s != null) {
                    val b = RecoveryCalculator().breakdown(s.avgHrv, s.restingHr, BaselineProvider().compute(AppDatabaseHolder.get(ctx)), s.respiratoryRate)
                    addView(W.valueRow(ctx, null, "VFC frente a tu media", b.hrvDeltaPct?.let { (if (it >= 0) "+" else "") + Ui.comma(it) + " %" } ?: "--"))
                    addView(W.divider(ctx))
                    addView(W.valueRow(ctx, null, "FC en reposo frente a tu media", b.rhrDelta?.let { (if (it >= 0) "+" else "") + Ui.comma(it) + " lpm" } ?: "--"))
                    addView(W.divider(ctx))
                }
                addView(W.body(ctx, "Como en WHOOP, la recuperación sale de tu VFC y tu FC en reposo de esta noche comparadas con tu propia " +
                    "media de las últimas semanas (más VFC y menos pulso que de costumbre = más recuperación). Si la respiración se dispara, baja. " +
                    "La calificación del sueño se muestra como en WHOOP pero no cambia la nota: en tus 199 noches de WHOOP no mejoraba el cálculo.", 14f)
                    .apply { setPadding(0, dp(12f), 0, dp(6f)) })
            })

            // ---------- Semana ----------
            content.addView(TextView(ctx).apply {
                text = "Tendencias semanales"; setTextAppearance(R.style.HeadingW); setPadding(0, dp(34f), 0, dp(2f))
            })
            val week = (6 downTo 0).map { d.date.minusDays(it.toLong()) }
            val byDate = d.records.associateBy { it.date }
            val recs = week.map { byDate[it]?.recovery ?: if (it == d.date) rec else null }
            content.addView(W.chartCard(ctx, "Recuperación", emptyList(), WeekChartView(ctx).apply {
                setBars(W.weekDays(week),
                    recs.map { v -> v?.let { listOf(it.toFloat() to Ui.color(ctx, W.recoveryColor(it))) } },
                    recs.map { v -> v?.let { WeekChartView.Label("$it %", Ui.color(ctx, W.recoveryColor(it))) } }, 100f)
            }))
            content.addView(View(ctx).apply { layoutParams = LinearLayout.LayoutParams(1, dp(30f)) })
        }
    }
}
