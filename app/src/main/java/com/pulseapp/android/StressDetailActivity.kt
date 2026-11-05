package com.pulseapp.android

import android.app.AlertDialog
import android.content.Intent
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
import com.pulseapp.android.ui.StressDayChartView
import com.pulseapp.android.ui.StressGaugeView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.time.LocalDate
import java.time.ZoneId
import java.util.Date
import java.util.Locale

/**
 * Monitor de estrés con el aspecto de WHOOP (17/10; 5/11 como la app de WHOOP): "< HOY >", medidor 0–3 con el valor de
 * ahora, gráfica de las últimas 24 h con el sueño y las actividades marcadas, y tres tarjetas (Día total, Sin actividad,
 * Sueño) con el reparto del día frente a tu día habitual a la misma hora (mismos días de la semana de las 4 semanas
 * anteriores; si no hay, los últimos 7 días) y "Ver tendencias".
 */
class StressDetailActivity : AppCompatActivity() {
    companion object { const val EXTRA_DAY_OFFSET = "day_offset" }

    private val zone: ZoneId = ZoneId.systemDefault()
    private val weekdays = arrayOf("LUN", "MAR", "MIÉ", "JUE", "VIE", "SÁB", "DOM")
    private val weekdayNames = arrayOf("LUNES", "MARTES", "MIÉRCOLES", "JUEVES", "VIERNES", "SÁBADO", "DOMINGO")
    private val months = arrayOf("ENE", "FEB", "MAR", "ABR", "MAY", "JUN", "JUL", "AGO", "SEP", "OCT", "NOV", "DIC")
    private var dayOffset = 0
    private lateinit var screen: SUi.Screen

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Formulas.init(this)
        dayOffset = intent.getIntExtra(EXTRA_DAY_OFFSET, 0).coerceAtMost(0)
        screen = SUi.screen(this)
        screen.top.addView(SUi.header(this, R.drawable.ic_chevron_left, { finish() }, "Monitor de estrés", null, R.drawable.ic_info) { howItWorks() })
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun howItWorks() {
        AlertDialog.Builder(this).setTitle("Monitor de estrés")
            .setMessage("El estrés (0 a 3) sale de tu pulso y tu VFC cada 5 minutos frente a tu línea base: pulso por encima de tu FC en reposo " +
                "y VFC por debajo de tu media lo suben.\n\nBajo < 1 · Medio 1–2 · Alto ≥ 2.\n\nLas tarjetas comparan el día con tu día " +
                "habitual a la misma hora: la barra de arriba es el día elegido y la de abajo (más apagada) tu media.")
            .setPositiveButton("OK", null).show()
    }

    private fun load() {
        lifecycleScope.launch {
            val ctx = this@StressDetailActivity
            val db = AppDatabase.getInstance(ctx)
            val home = HomeDataLoader(ctx).load(dayOffset)
            val baseline = BaselineProvider().compute(db)
            val file = File(getExternalFilesDir(null), "hr_log.csv")
            val day = LocalDate.now(zone).plusDays(dayOffset.toLong())
            val isToday = dayOffset == 0
            val dayStart = day.atStartOfDay(zone).toInstant().toEpochMilli()
            val now = System.currentTimeMillis()
            val end = if (isToday) now else day.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
            val elapsed = end - dayStart
            val allSessions = db.activitySessionDao().getAll()
            val sessions = allSessions.map { it.startMillis..it.endMillis }
            val stored = db.dailyMetricsDao().getLastDays(60).associateBy { it.date }

            // Día elegido (00:00 → ahora o fin del día)
            val sleepDay = listOfNotNull(home.sleepFromMillis?.let { f -> home.sleepToMillis?.let { t -> f..t } })
            val todayDay = StressBreakdown.of(home.stressSeries, sleepDay, sessions)

            // Gráfica de las 24 h anteriores (como WHOOP) y días habituales: una sola lectura del archivo
            val calc = StressCalculator()
            val samples = withContext(Dispatchers.IO) { calc.loadSamples(file, dayStart - 28L * 86_400_000L).filter { it.timeMillis <= end } }
            val chartFrom = end - 86_400_000L
            val chart = withContext(Dispatchers.Default) { calc.seriesBetween(samples, chartFrom, end, null, baseline) }
            fun sleepOf(d: LocalDate): LongRange? {
                val row = stored[d.toString()] ?: return null
                val ss = row.sleepStartMinuteOfDay ?: return null; val se = row.sleepEndMinuteOfDay ?: return null
                val s = d.atStartOfDay(zone).toInstant().toEpochMilli()
                val e = s + se * 60_000L
                val st = if (ss > se) s - (1440 - ss) * 60_000L else s + ss * 60_000L
                return st..e
            }
            val sleeps = (listOfNotNull(home.sleepFromMillis?.let { f -> home.sleepToMillis?.let { t -> f to t } }) +
                listOfNotNull(sleepOf(day.minusDays(1))?.let { it.first to it.last }) +
                allSessions.filter { it.type == Formulas.NAP_TYPE }.map { it.startMillis to it.endMillis })
                .filter { it.second > chartFrom && it.first < end }.distinctBy { it.first / 60000 }
            val acts = allSessions.filter { it.type != Formulas.NAP_TYPE && it.endMillis > chartFrom && it.startMillis < end }
                .map { it.startMillis to it.endMillis }

            fun dayFor(d: LocalDate): StressBreakdown.Day? {
                val s = d.atStartOfDay(zone).toInstant().toEpochMilli()
                val series = calc.seriesBetween(samples, s, s + elapsed, null, baseline)
                if (series.size * 5 < todayDay.total.total / 2 || series.isEmpty()) return null
                return StressBreakdown.of(series, listOfNotNull(sleepOf(d)), sessions)
            }
            val sameWeekday = withContext(Dispatchers.Default) { (1..4).mapNotNull { dayFor(day.minusWeeks(it.toLong())) } }
            val habitualDays = if (sameWeekday.isNotEmpty()) sameWeekday
            else withContext(Dispatchers.Default) { (1..7).mapNotNull { dayFor(day.minusDays(it.toLong())) } }
            val habitual = StressBreakdown.average(habitualDays)
            val vsText = if (sameWeekday.isNotEmpty()) "VS. UN ${weekdayNames[day.dayOfWeek.value - 1]} HABITUAL" else "VS. UN DÍA HABITUAL"
            val dateText = "${weekdays[day.dayOfWeek.value - 1]}., ${months[day.monthValue - 1]}. ${day.dayOfMonth} ESTRÉS "

            val c = screen.content
            c.removeAllViews()
            // < HOY >
            c.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER
                addView(SUi.iconButton(ctx, R.drawable.ic_chevron_left) { dayOffset--; load() })
                addView(W.title(ctx, when (dayOffset) { 0 -> "Hoy"; -1 -> "Ayer"; else -> W.dateTitle(day) }, 15f).apply {
                    gravity = Gravity.CENTER; minWidth = SUi.dp(ctx, 110f)
                })
                addView(SUi.iconButton(ctx, R.drawable.ic_chevron_right) { if (dayOffset < 0) { dayOffset++; load() } }.apply { alpha = if (dayOffset < 0) 1f else 0.3f })
            })
            // Medidor
            val last = chart.lastOrNull()
            val level = when { last == null || last.score < 1f -> "BAJO"; last.score < 2f -> "MEDIO"; else -> "ALTO" }
            c.addView(StressGaugeView(ctx).apply {
                setData(last?.score, if (last == null) "" else level, last?.let { SimpleDateFormat("HH:mm", Locale.US).format(Date(it.timeMillis)) } ?: "")
                layoutParams = SUi.mp(SUi.dp(ctx, 230f)).apply { topMargin = SUi.dp(ctx, 4f) }
                setOnClickListener { howItWorks() }
            })
            // Gráfica 24 h
            c.addView(StressDayChartView(ctx).apply {
                whoopStyle = true
                setData(chart, chartFrom, end, null, null, isToday)
                setMarks(acts, sleeps)
                layoutParams = SUi.mp(SUi.dp(ctx, 230f)).apply { topMargin = SUi.dp(ctx, 8f) }
            })
            // Tarjetas
            c.addView(card(R.drawable.ic_gauge, "Día total", dateText, vsText, todayDay.total, habitual?.total,
                "El estrés experimentado a lo largo del día, incluso durante el sueño y las actividades.", 0))
            c.addView(card(R.drawable.ic_person_still, "Sin actividad", dateText, vsText, todayDay.noActivity, habitual?.noActivity,
                "El estrés experimentado fuera de las actividades de esfuerzo y el sueño.", 1))
            c.addView(card(R.drawable.ic_moon, "Sueño", dateText, vsText, todayDay.sleep, habitual?.sleep,
                "El estrés experimentado durante el sueño.", 2))
            if (habitual == null) {
                c.addView(W.body(ctx, "Aún no hay días anteriores con datos a esta hora para comparar. La barra de abajo aparecerá cuando los haya.", 14f).apply {
                    setPadding(0, Ui.dp(ctx, 12f), 0, 0)
                })
            }
        }
    }

    private fun card(icon: Int, title: String, dateText: String, vsText: String, today: StressBreakdown.Mins,
                     habitual: StressBreakdown.Mins?, description: String, category: Int): LinearLayout {
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
        card.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(0, Ui.dp(ctx, 22f), 0, 0)
            addView(W.title(ctx, "Ver tendencias", 14f))
            addView(W.icon(ctx, R.drawable.ic_arrow_right, 18f).apply { (layoutParams as LinearLayout.LayoutParams).marginStart = Ui.dp(ctx, 10f) })
            isClickable = true
            setOnClickListener {
                startActivity(Intent(ctx, StressTrendsActivity::class.java).putExtra(StressTrendsActivity.EXTRA_CATEGORY, category)
                    .putExtra(StressTrendsActivity.EXTRA_DAY_OFFSET, dayOffset))
            }
        })
        return card
    }
}
