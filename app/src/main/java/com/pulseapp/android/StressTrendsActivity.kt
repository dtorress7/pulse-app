package com.pulseapp.android

import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.LocalDate
import java.time.ZoneId

/** "Ver tendencias" del Monitor de estrés (5/11): los 7 últimos días de Día total / Sin actividad / Sueño en barras apiladas. */
class StressTrendsActivity : AppCompatActivity() {
    companion object {
        const val EXTRA_CATEGORY = "category"
        const val EXTRA_DAY_OFFSET = "day_offset"
    }

    private val zone: ZoneId = ZoneId.systemDefault()
    private val names = listOf("Día total", "Sin actividad", "Sueño")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Formulas.init(this)
        var category = intent.getIntExtra(EXTRA_CATEGORY, 0).coerceIn(0, 2)
        val offset = intent.getIntExtra(EXTRA_DAY_OFFSET, 0)
        val screen = SUi.screen(this)
        screen.top.addView(SUi.header(this, R.drawable.ic_chevron_left, { finish() }, "Tendencias de estrés"))
        val ctx = this
        lifecycleScope.launch {
            val db = AppDatabase.getInstance(ctx)
            val baseline = BaselineProvider().compute(db)
            val last = LocalDate.now(zone).plusDays(offset.toLong())
            val daysList = (6 downTo 0).map { last.minusDays(it.toLong()) }
            val stored = db.dailyMetricsDao().getLastDays(60).associateBy { it.date }
            val sessions = db.activitySessionDao().getAll().map { it.startMillis..it.endMillis }
            val file = File(getExternalFilesDir(null), "hr_log.csv")
            val now = System.currentTimeMillis()
            val result = withContext(Dispatchers.IO) {
                val calc = StressCalculator()
                val start = daysList.first().atStartOfDay(zone).toInstant().toEpochMilli()
                val samples = calc.loadSamples(file, start - 86_400_000L)
                daysList.map { d ->
                    val s = d.atStartOfDay(zone).toInstant().toEpochMilli()
                    val e = minOf(now, d.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli())
                    val series = calc.seriesBetween(samples, s, e, null, baseline)
                    val row = stored[d.toString()]
                    val sleep = if (row?.sleepStartMinuteOfDay != null && row.sleepEndMinuteOfDay != null) {
                        val end = s + row.sleepEndMinuteOfDay * 60_000L
                        val st = if (row.sleepStartMinuteOfDay > row.sleepEndMinuteOfDay) s - (1440 - row.sleepStartMinuteOfDay) * 60_000L
                        else s + row.sleepStartMinuteOfDay * 60_000L
                        listOf(st..end)
                    } else emptyList()
                    if (series.isEmpty()) null else StressBreakdown.of(series, sleep, sessions)
                }
            }
            fun render() {
                val c = screen.content
                c.removeAllViews()
                c.addView(SUi.segmented(ctx, names, category) { category = it; render() })
                val mins = result.map { d -> d?.let { when (category) { 0 -> it.total; 1 -> it.noActivity; else -> it.sleep } } }
                val maxT = mins.maxOfOrNull { it?.total ?: 0 }?.takeIf { it > 0 } ?: 1
                c.addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.HORIZONTAL; gravity = Gravity.BOTTOM
                    layoutParams = SUi.mp(SUi.dp(ctx, 240f)).apply { topMargin = SUi.dp(ctx, 26f) }
                    daysList.forEachIndexed { i, d ->
                        val m = mins[i]
                        addView(LinearLayout(ctx).apply {
                            orientation = LinearLayout.VERTICAL; gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                            val full = SUi.dp(ctx, 180f)
                            if (m != null && m.total > 0) {
                                addView(W.number(ctx, Ui.hm(m.total), 11.5f, R.color.text_secondary).apply { setPadding(0, 0, 0, SUi.dp(ctx, 4f)) })
                                for ((v, col) in listOf(m.high to R.color.alert_amber, m.mid to R.color.w_mint, m.low to R.color.w_low_blue)) {
                                    if (v <= 0) continue
                                    addView(View(ctx).apply { setBackgroundColor(Ui.color(ctx, col)) },
                                        LinearLayout.LayoutParams(SUi.dp(ctx, 22f), (full * v / maxT).coerceAtLeast(SUi.dp(ctx, 2f))).apply { topMargin = SUi.dp(ctx, 1f) })
                                }
                            } else addView(W.number(ctx, "--", 12f, R.color.text_secondary))
                            addView(W.number(ctx, Ui.weekdayLetter(d.toString()) + " " + d.dayOfMonth, 12f,
                                if (i == daysList.size - 1) R.color.text_primary else R.color.text_secondary).apply { setPadding(0, SUi.dp(ctx, 8f), 0, 0) })
                        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f))
                    }
                })
                val valid = mins.filterNotNull().filter { it.total > 0 }
                if (valid.isNotEmpty()) {
                    val avg = StressBreakdown.Mins(valid.map { it.low }.average().toInt(), valid.map { it.mid }.average().toInt(), valid.map { it.high }.average().toInt())
                    c.addView(W.title(ctx, "Media de los días con datos", 14f, R.color.text_secondary).apply { setPadding(0, SUi.dp(ctx, 26f), 0, 0) })
                    c.addView(LinearLayout(ctx).apply {
                        orientation = LinearLayout.HORIZONTAL
                        layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 12f) }
                        for ((label, v, col) in listOf(Triple("Bajo", avg.low, R.color.w_low_blue), Triple("Medio", avg.mid, R.color.w_mint), Triple("Alto", avg.high, R.color.alert_amber))) {
                            addView(LinearLayout(ctx).apply {
                                orientation = LinearLayout.VERTICAL
                                addView(W.number(ctx, Ui.hm(v), 26f))
                                addView(LinearLayout(ctx).apply {
                                    orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                                    setPadding(0, SUi.dp(ctx, 8f), 0, 0)
                                    addView(View(ctx).apply { background = W.rounded(ctx, col, 1f) }, LinearLayout.LayoutParams(SUi.dp(ctx, 11f), SUi.dp(ctx, 11f)))
                                    addView(W.title(ctx, label, 13.5f, R.color.text_secondary).apply { setPadding(SUi.dp(ctx, 8f), 0, 0, 0) })
                                })
                            }, W.weight())
                        }
                    })
                }
                c.addView(W.body(ctx, "Tiempo en estrés bajo, medio y alto de cada día (el último, hasta ahora). " +
                    listOf("Todo el día, también dormido y en actividades.", "Fuera del sueño y de las actividades.", "Solo durante el sueño.")[category], 14f).apply {
                    setPadding(0, SUi.dp(ctx, 20f), 0, 0)
                })
            }
            render()
        }
    }
}
