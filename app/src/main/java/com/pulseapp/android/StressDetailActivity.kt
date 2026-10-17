package com.pulseapp.android

import android.graphics.Typeface
import android.os.Bundle
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
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

/**
 * Monitor de estrés con el aspecto de WHOOP (17/10): tres tarjetas (Día total, Sin actividad, Sueño) con el reparto de
 * hoy (00:00 → ahora) frente a tu día habitual a la misma hora: la media de los mismos días de la semana de las
 * últimas 4 semanas (si no hay, los últimos 7 días).
 */
class StressDetailActivity : AppCompatActivity() {

    private val zone: ZoneId = ZoneId.systemDefault()
    private val weekdays = arrayOf("LUN", "MAR", "MIÉ", "JUE", "VIE", "SÁB", "DOM")
    private val weekdayNames = arrayOf("LUNES", "MARTES", "MIÉRCOLES", "JUEVES", "VIERNES", "SÁBADO", "DOMINGO")
    private val months = arrayOf("ENE", "FEB", "MAR", "ABR", "MAY", "JUN", "JUL", "AGO", "SEP", "OCT", "NOV", "DIC")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_stress_detail)
        window.statusBarColor = Ui.color(this, R.color.w_bg_top)
        Ui.setupDetailHeader(this, "Monitor de estrés")
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun load() {
        lifecycleScope.launch {
            val ctx = this@StressDetailActivity
            val db = AppDatabase.getInstance(ctx)
            val home = HomeDataLoader(ctx).load(0)
            val baseline = BaselineProvider().compute(db)
            val file = File(getExternalFilesDir(null), "hr_log.csv")
            val today = LocalDate.now(zone)
            val todayStart = today.atStartOfDay(zone).toInstant().toEpochMilli()
            val now = System.currentTimeMillis()
            val elapsed = now - todayStart
            val sessions = db.activitySessionDao().getAll().map { it.startMillis..it.endMillis }
            val stored = db.dailyMetricsDao().getLastDays(40).associateBy { it.date }

            // Hoy
            val sleepToday = listOfNotNull(home.sleepFromMillis?.let { f -> home.sleepToMillis?.let { t -> f..t } })
            val todayDay = StressBreakdown.of(home.stressSeries, sleepToday, sessions)

            // Días anteriores a la misma hora: primero los mismos días de la semana; si no hay, la última semana
            val calc = StressCalculator()
            val samples = withContext(Dispatchers.IO) { calc.loadSamples(file, todayStart - 28L * 86_400_000L) }
            fun dayFor(d: LocalDate): StressBreakdown.Day? {
                val s = d.atStartOfDay(zone).toInstant().toEpochMilli()
                val series = calc.seriesBetween(samples, s, s + elapsed, null, baseline)
                if (series.size * 5 < todayDay.total.total / 2 || series.isEmpty()) return null
                val row = stored[d.toString()]
                val sleep = if (row?.sleepStartMinuteOfDay != null && row.sleepEndMinuteOfDay != null) {
                    val end = s + row.sleepEndMinuteOfDay * 60_000L
                    val start = if (row.sleepStartMinuteOfDay > row.sleepEndMinuteOfDay) s - (1440 - row.sleepStartMinuteOfDay) * 60_000L
                    else s + row.sleepStartMinuteOfDay * 60_000L
                    listOf(start..end)
                } else emptyList()
                return StressBreakdown.of(series, sleep, sessions)
            }
            val sameWeekday = withContext(Dispatchers.Default) { (1..4).mapNotNull { dayFor(today.minusWeeks(it.toLong())) } }
            val habitualDays = if (sameWeekday.isNotEmpty()) sameWeekday
            else withContext(Dispatchers.Default) { (1..7).mapNotNull { dayFor(today.minusDays(it.toLong())) } }
            val habitual = StressBreakdown.average(habitualDays)
            val vsText = if (sameWeekday.isNotEmpty()) "VS. UN ${weekdayNames[today.dayOfWeek.value - 1]} HABITUAL" else "VS. UN DÍA HABITUAL"
            val dateText = "${weekdays[today.dayOfWeek.value - 1]}., ${months[today.monthValue - 1]}. ${today.dayOfMonth} ESTRÉS "

            val cards = findViewById<LinearLayout>(R.id.stressCards)
            cards.removeAllViews()
            cards.addView(card(R.drawable.ic_gauge, "Día total", dateText, vsText, todayDay.total, habitual?.total,
                "El estrés experimentado a lo largo del día, incluso durante el sueño y las actividades."))
            cards.addView(card(R.drawable.ic_person_still, "Sin actividad", dateText, vsText, todayDay.noActivity, habitual?.noActivity,
                "El estrés experimentado fuera de las actividades de esfuerzo y el sueño."))
            cards.addView(card(R.drawable.ic_moon, "Sueño", dateText, vsText, todayDay.sleep, habitual?.sleep,
                "El estrés experimentado durante el sueño."))
            if (habitual == null) {
                cards.addView(W.body(ctx, "Aún no hay días anteriores con datos a esta hora para comparar. La barra de abajo aparecerá cuando los haya.", 14f).apply {
                    setPadding(0, Ui.dp(ctx, 4f), 0, 0)
                })
            }
        }
    }

    private fun card(icon: Int, title: String, dateText: String, vsText: String, today: StressBreakdown.Mins,
                     habitual: StressBreakdown.Mins?, description: String): LinearLayout {
        val ctx = this
        val card = W.card(ctx, 16f).apply { setPadding(Ui.dp(ctx, 18f), Ui.dp(ctx, 20f), Ui.dp(ctx, 18f), Ui.dp(ctx, 22f)) }
        card.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(W.icon(ctx, icon, 22f, R.color.text_secondary))
            addView(W.title(ctx, title, 15f).apply { setPadding(Ui.dp(ctx, 12f), 0, 0, 0) })
        })
        card.addView(W.title(ctx, "", 13.5f).apply {
            val sb = SpannableStringBuilder(dateText)
            val start = sb.length
            sb.append(vsText)
            sb.setSpan(ForegroundColorSpan(Ui.color(ctx, R.color.text_secondary)), start, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            text = sb
            setPadding(0, Ui.dp(ctx, 22f), 0, 0)
        })
        // Barra de hoy (colores vivos) y la del día habitual (apagados)
        card.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Ui.dp(ctx, 14f)).apply { topMargin = Ui.dp(ctx, 20f) }
            Ui.fillStackedBar(this, listOf(today.low.toFloat() to R.color.w_low_blue, today.mid.toFloat() to R.color.w_mint, today.high.toFloat() to R.color.alert_amber))
        })
        if (habitual != null) card.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Ui.dp(ctx, 8f)).apply { topMargin = Ui.dp(ctx, 8f) }
            Ui.fillStackedBar(this, listOf(habitual.low.toFloat() to R.color.w_stress_low_dim, habitual.mid.toFloat() to R.color.w_stress_mid_dim,
                habitual.high.toFloat() to R.color.w_stress_high_dim))
        })
        // Tres columnas: tiempo, diferencia y leyenda
        val cols = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = Ui.dp(ctx, 22f) }
        }
        listOf(
            Triple("BAJO", today.low to habitual?.low, R.color.w_low_blue),
            Triple("MEDIO", today.mid to habitual?.mid, R.color.w_mint),
            Triple("ALTO", today.high to habitual?.high, R.color.alert_amber)
        ).forEach { (label, values, color) ->
            cols.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = W.weight()
                addView(W.number(ctx, Ui.hm(values.first), 27f))
                val h = values.second
                val chip = if (h != null) {
                    val (trend, txt) = StressBreakdown.delta(values.first, h)
                    W.trendChip(ctx, trend, txt)
                } else W.trendChip(ctx, null, "—")
                chip.layoutParams = W.wrap().apply { topMargin = Ui.dp(ctx, 8f) }
                addView(chip)
                addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    layoutParams = W.wrap().apply { topMargin = Ui.dp(ctx, 10f) }
                    addView(View(ctx).apply {
                        background = W.rounded(ctx, color, 1f)
                        layoutParams = LinearLayout.LayoutParams(Ui.dp(ctx, 11f), Ui.dp(ctx, 11f))
                    })
                    addView(W.title(ctx, label, 14f, R.color.text_secondary).apply { setPadding(Ui.dp(ctx, 8f), 0, 0, 0) })
                })
            })
        }
        card.addView(cols)
        card.addView(W.body(ctx, description, 16f).apply {
            setPadding(0, Ui.dp(ctx, 22f), 0, 0)
            typeface = Typeface.create(typeface, Typeface.NORMAL)
        })
        return card
    }
}
