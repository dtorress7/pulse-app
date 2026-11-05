package com.pulseapp.android

import android.app.AlertDialog
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.ui.StressTrendChartView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.ZoneId

/**
 * "Vista de tendencias" del Monitor de estrés (5/11, copiada de las capturas de WHOOP): elegir Estrés total diurno / no relacionado
 * con la actividad / del sueño; S (7 días) · M (30 días) · 6 M (26 semanas, una barra por semana); "Estrés alto prom." con la
 * diferencia frente al periodo anterior; barras al 100 % de bajo / medio / alto. El promedio no incluye el día de hoy.
 */
class StressTrendsActivity : AppCompatActivity() {
    companion object {
        const val EXTRA_CATEGORY = "category"
        const val EXTRA_DAY_OFFSET = "day_offset"
    }

    private val zone: ZoneId = ZoneId.systemDefault()
    private val names = listOf("Estrés total diurno", "Estrés no relacionado con la actividad", "Estrés del sueño")
    private val icons = listOf(R.drawable.ic_gauge, R.drawable.ic_person_still, R.drawable.ic_moon)
    private val months = arrayOf("ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic")
    private val wd = arrayOf("L", "M", "X", "J", "V", "S", "D")
    private var category = 0
    private var period = 1        // 0 = S, 1 = M, 2 = 6 M
    private var shift = 0         // periodos hacia atrás
    private lateinit var screen: SUi.Screen
    private var data: Map<LocalDate, StressBreakdown.Day?> = emptyMap()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Formulas.init(this)
        category = intent.getIntExtra(EXTRA_CATEGORY, 0).coerceIn(0, 2)
        screen = SUi.screen(this)
        screen.top.addView(SUi.header(this, R.drawable.ic_chevron_left, { finish() }, "Vista de tendencias"))
        load()
    }

    /** Lee (o calcula) los días necesarios: el periodo elegido y el anterior para la comparación. */
    private fun load() {
        val ctx = this
        lifecycleScope.launch {
            val db = AppDatabase.getInstance(ctx)
            screen.content.removeAllViews()
            screen.content.addView(W.body(ctx, "Calculando… (la primera vez puede tardar un poco)", 14f).apply { setPadding(0, SUi.dp(ctx, 40f), 0, 0) })
            val (from, to) = range()
            val len = java.time.temporal.ChronoUnit.DAYS.between(from, to) + 1
            val need = (0 until len * 2).map { from.minusDays(len).plusDays(it) }.filter { it <= LocalDate.now(zone) }
            data = withContext(Dispatchers.IO) {
                val stored = db.dailyMetricsDao().getLastDays(400).associateBy { it.date }
                StressDays.load(getExternalFilesDir(null)!!, need, stored, db.activitySessionDao().getAll(), BaselineProvider().compute(db), zone)
            }
            render()
        }
    }

    private fun range(): Pair<LocalDate, LocalDate> {
        val today = LocalDate.now(zone)
        return when (period) {
            0 -> today.minusDays(6L + 7L * shift) to today.minusDays(7L * shift)
            1 -> today.minusDays(29L + 30L * shift) to today.minusDays(30L * shift)
            else -> today.minusWeeks(26L * (shift + 1)).plusDays(1) to today.minusWeeks(26L * shift)
        }
    }

    private fun pick(d: StressBreakdown.Day?): StressBreakdown.Mins? = d?.let { when (category) { 0 -> it.total; 1 -> it.noActivity; else -> it.sleep } }
        ?.takeIf { it.total > 0 }

    private fun hm(min: Double): String { val m = Math.round(min).toInt(); return "%d:%02d".format(m / 60, m % 60) }

    private fun render() {
        val ctx = this
        val c = screen.content
        c.removeAllViews()
        val today = LocalDate.now(zone)
        val (from, to) = range()
        val len = java.time.temporal.ChronoUnit.DAYS.between(from, to) + 1
        val days = (0 until len).map { from.plusDays(it) }
        val prevDays = days.map { it.minusDays(len) }
        // Promedio de alto (sin hoy, como WHOOP)
        fun avgHigh(ds: List<LocalDate>): Double? = ds.filter { it != today }.mapNotNull { pick(data[it]) }.map { it.high.toDouble() }
            .takeIf { it.isNotEmpty() }?.average()
        val avg = avgHigh(days); val prev = avgHigh(prevDays)

        // Selector de apartado
        c.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setBackgroundResource(R.drawable.bg_card_w)
            setPadding(SUi.dp(ctx, 18f), SUi.dp(ctx, 18f), SUi.dp(ctx, 16f), SUi.dp(ctx, 18f))
            layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 16f) }
            addView(W.icon(ctx, icons[category], 22f, R.color.text_secondary))
            addView(W.title(ctx, names[category], 15f), W.weight().apply { marginStart = SUi.dp(ctx, 16f) })
            addView(W.icon(ctx, R.drawable.ic_chevron_down, 20f))
            isClickable = true
            setOnClickListener {
                AlertDialog.Builder(ctx).setItems(names.toTypedArray()) { _, i -> category = i; render() }.show()
            }
        })
        // Estrés alto prom. + S / M / 6 M + fechas
        c.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 26f) }
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                addView(W.title(ctx, "Estrés alto prom.", 12.5f, R.color.text_secondary))
                addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.HORIZONTAL; gravity = Gravity.BOTTOM
                    setPadding(0, SUi.dp(ctx, 6f), 0, 0)
                    addView(W.number(ctx, avg?.let { hm(it) } ?: "--", 38f))
                    addView(W.number(ctx, " hr", 17f).apply { setPadding(0, 0, 0, SUi.dp(ctx, 4f)) })
                })
                if (avg != null && prev != null && prev > 0) {
                    val pct = Math.round(Math.abs(avg - prev) * 100 / prev)
                    val down = avg <= prev
                    val what = listOf("la semana anterior", "el mes anterior", "los 6 meses anteriores")[period]
                    addView(W.number(ctx, (if (down) "▼ " else "▲ ") + "$pct % vs. $what", 13f, if (down) R.color.w_mint else R.color.alert_amber).apply {
                        background = SUi.rounded(ctx, if (down) Color.parseColor("#1A00F88A") else Color.parseColor("#22F9C718"), 5f)
                        setPadding(SUi.dp(ctx, 6f), SUi.dp(ctx, 3f), SUi.dp(ctx, 6f), SUi.dp(ctx, 3f))
                        layoutParams = W.wrap().apply { topMargin = SUi.dp(ctx, 6f) }
                    })
                }
            }, W.weight())
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL; gravity = Gravity.END
                addView(SUi.segmented(ctx, listOf("S", "M", "6 M"), period) { period = it; shift = 0; load() }.apply {
                    layoutParams = LinearLayout.LayoutParams(SUi.dp(ctx, 190f), LinearLayout.LayoutParams.WRAP_CONTENT)
                })
                addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                    layoutParams = W.wrap().apply { topMargin = SUi.dp(ctx, 8f) }
                    addView(SUi.iconButton(ctx, R.drawable.ic_chevron_left) { shift++; load() })
                    addView(W.title(ctx, "${from.dayOfMonth} ${months[from.monthValue - 1]}. - ${to.dayOfMonth} ${months[to.monthValue - 1]}. ${to.year % 100}", 13f))
                    addView(SUi.iconButton(ctx, R.drawable.ic_chevron_right) { if (shift > 0) { shift--; load() } }.apply { alpha = if (shift > 0) 1f else 0.3f })
                })
            })
        })
        // Texto
        val esto = listOf("Esta semana", "Este mes", "En estos 6 meses")[period].let { if (shift > 0) "En este periodo" else it }
        val antes = listOf("los 7 días anteriores", "los 30 días anteriores", "los 6 meses anteriores")[period]
        val donde = listOf("", "", " mientras dormías")[category]
        val extra = listOf(" Esto incluye el tiempo dedicado a actividades de sueño y esfuerzo.",
            " Esto excluye el tiempo dedicado a actividades de sueño y esfuerzo.", "")[category]
        val txt = if (avg == null) "Aún no hay días con datos en este periodo." else
            "$esto pasaste un promedio de ${hm(avg)} horas en la zona de estrés alto$donde" +
                (if (prev != null) ", lo cual es ${if (avg <= prev) "inferior" else "superior"} a tu promedio de $antes (${hm(prev)})." else ".") + extra
        c.addView(W.body(ctx, txt, 16f, R.color.text_primary).apply { setPadding(0, SUi.dp(ctx, 22f), 0, 0) })
        // Leyenda
        c.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(0, SUi.dp(ctx, 24f), 0, 0)
            for ((l, col) in listOf("Alto" to R.color.alert_amber, "Medio" to R.color.w_mint, "Bajo" to R.color.w_low_blue)) {
                addView(View(ctx).apply { background = W.rounded(ctx, col, 1f) }, LinearLayout.LayoutParams(SUi.dp(ctx, 11f), SUi.dp(ctx, 11f)))
                addView(W.title(ctx, l, 12.5f, R.color.text_secondary).apply { setPadding(SUi.dp(ctx, 6f), 0, SUi.dp(ctx, 16f), 0) })
            }
        })
        // Barras
        val bars: List<StressTrendChartView.Bar?>; val labels: List<Pair<String, String>?>
        if (period == 2) {
            val weeks = days.chunked(7)
            bars = weeks.map { wk ->
                val ms = wk.mapNotNull { pick(data[it]) }
                if (ms.isEmpty()) null else StressTrendChartView.Bar(ms.sumOf { it.low }, ms.sumOf { it.mid }, ms.sumOf { it.high })
            }
            labels = weeks.mapIndexed { i, wk -> val d = wk.first(); if (i == 0 || d.monthValue != weeks[i - 1].first().monthValue) months[d.monthValue - 1] to "" else null }
        } else {
            bars = days.map { d -> pick(data[d])?.let { StressTrendChartView.Bar(it.low, it.mid, it.high) } }
            labels = days.mapIndexed { i, d ->
                if (period == 0) wd[d.dayOfWeek.value - 1] to "${d.dayOfMonth}"
                else if ((days.size - 1 - i) % 7 == 0) months[d.monthValue - 1] to "${d.dayOfMonth}" else null
            }
        }
        c.addView(StressTrendChartView(ctx).apply {
            setData(bars, labels)
            layoutParams = SUi.mp(SUi.dp(ctx, 290f)).apply { topMargin = SUi.dp(ctx, 12f) }
        })
        if (to == today) c.addView(W.body(ctx, "ⓘ  El promedio no incluye el día de hoy (${today.dayOfMonth} ${months[today.monthValue - 1]}.)", 13f).apply {
            setPadding(0, SUi.dp(ctx, 10f), 0, 0)
        })
        // ¿Qué es…?
        val what = listOf(
            "¿Qué es el Estrés total diurno?" to "El estrés es la respuesta natural del organismo a un desafío físico o mental. Es una medida del grado de alerta o activación de tu organismo en un momento dado. El Estrés total diurno incluye todo el día: también el sueño y las actividades.",
            "¿Qué es el Estrés no relacionado con la actividad?" to "El estrés es la respuesta natural del organismo a un desafío físico o mental. Aquí solo cuenta el tiempo fuera del sueño y de las actividades de esfuerzo: el estrés del día a día (trabajo, emociones, cafeína, enfermedad…).",
            "¿Qué es el Estrés del sueño?" to "El estrés es la respuesta natural del organismo a un desafío físico o mental. El Estrés del sueño mide la activación mientras duermes: lo normal es que casi todo sea bajo; más medio o alto puede venir de entrenar tarde, alcohol, cenas copiosas o estar enfermo.")[category]
        c.addView(W.card(ctx, 26f).apply {
            setPadding(SUi.dp(ctx, 18f), SUi.dp(ctx, 20f), SUi.dp(ctx, 18f), SUi.dp(ctx, 22f))
            addView(W.body(ctx, what.first, 20f, R.color.text_primary))
            addView(W.body(ctx, what.second, 15f).apply { setPadding(0, SUi.dp(ctx, 12f), 0, 0) })
            addView(W.body(ctx, "Bajo < 1 · Medio 1–2 · Alto ≥ 2 en la escala de 0 a 3, cada 5 minutos, frente a tu FC en reposo y tu VFC habituales.", 13.5f).apply {
                setPadding(0, SUi.dp(ctx, 12f), 0, 0)
            })
        })
    }
}
