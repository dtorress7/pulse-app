package com.pulseapp.android

import android.content.Intent
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
import java.text.SimpleDateFormat
import java.time.LocalDate
import java.util.Date
import java.util.Locale

/**
 * Esfuerzo con el aspecto de WHOOP (17/10): anillo grande con la marca del esfuerzo recomendado, zonas de FC, fuerza y
 * pasos frente a tus últimos 30 días, explicación del nivel, actividades del día, tendencias semanales y el historial.
 * Se abre desde Inicio con el día elegido (EXTRA_DAY_OFFSET) o desde la pestaña Esfuerzo (hoy).
 */
class ActivitiesListActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_DAY_OFFSET = "day_offset"
    }

    private val es = Locale("es", "ES")
    private var offset = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_activities)
        window.statusBarColor = Ui.color(this, R.color.w_bg_top)
        offset = intent.getIntExtra(EXTRA_DAY_OFFSET, 0)
        Ui.setupDetailHeader(this, W.dateTitle(LocalDate.now().plusDays(offset.toLong())))
        findViewById<View>(R.id.backButton).visibility = if (intent.hasExtra(EXTRA_DAY_OFFSET)) View.VISIBLE else View.INVISIBLE
        Ui.setupTabBar(this, Ui.Tab.ACTIVITIES)
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun dp(v: Float) = Ui.dp(this, v)

    private fun load() {
        lifecycleScope.launch {
            val ctx = this@ActivitiesListActivity
            val d = HomeDataLoader(ctx).load(offset)
            val day = d.day
            val prev = d.records.filter { it.date < d.date && it.date >= d.date.minusDays(30) }
            val byDate = d.records.associateBy { it.date }
            val week = (6 downTo 0).map { d.date.minusDays(it.toLong()) }
            val content = findViewById<LinearLayout>(R.id.detailContent)
            content.removeAllViews()

            // ---------- Anillo ----------
            val strain = day.strain ?: 0.0
            val target = when {                      // esfuerzo recomendado según la recuperación (como WHOOP)
                day.recovery == null -> null
                day.recovery >= 67 -> 16.0
                day.recovery >= 34 -> 12.0
                else -> 8.0
            }
            content.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(0, dp(14f), 0, 0)
                addView(CircularRingView(ctx).apply {
                    strokeRatio = 0.055f; numberRatio = 0.28f; labelRatio = 0.055f
                    topText = "PULSE"
                    setTrackColor(Ui.color(ctx, R.color.w_track)); setLabelColor(Ui.color(ctx, R.color.text_primary))
                    markerFraction = target?.let { (it / 21.0).toFloat() }
                    setValue((strain / 21.0).toFloat(), day.strain?.let { Ui.comma(it) } ?: "--", "Esfuerzo", Ui.color(ctx, R.color.strain_blue))
                    layoutParams = LinearLayout.LayoutParams(dp(260f), dp(260f))
                })
            })

            // ---------- Zonas, fuerza y pasos frente a 30 días ----------
            fun zoneMin(r: DayRecord?, pick: (ZoneDay) -> Int) = r?.zones?.let { pick(it) / 60 }
            fun avgOf(f: (DayRecord) -> Int?) = prev.mapNotNull(f).takeIf { it.isNotEmpty() }?.average()
            content.addView(W.card(ctx, 18f).apply {
                setPadding(dp(16f), dp(4f), dp(16f), dp(16f))
                fun row(icon: Int, label: String, v: Int?, a: Double?, fmt: (Int) -> String) {
                    addView(W.valueRow(ctx, icon, label, v?.let(fmt) ?: "--", W.trendOf(v?.toDouble(), a), true, a?.let { fmt(Math.round(it).toInt()) }))
                    addView(W.divider(ctx))
                }
                row(R.drawable.ic_heart_zone, "Zonas de frecuencia cardíaca 1-3", zoneMin(day) { it.z13Seconds }, avgOf { r -> zoneMin(r) { it.z13Seconds } }) { Ui.hm(it) }
                row(R.drawable.ic_heart_up, "Zonas de frecuencia cardíaca 4-5", zoneMin(day) { it.z45Seconds }, avgOf { r -> zoneMin(r) { it.z45Seconds } }) { Ui.hm(it) }
                row(R.drawable.ic_dumbbell, "Tiempo de actividad de fuerza", day.strengthMinutes, avgOf { it.strengthMinutes }) { Ui.hm(it) }
                row(R.drawable.ic_steps, "Pasos", day.steps, avgOf { it.steps }) { Ui.thousands(it.toLong()) }
                removeViewAt(childCount - 1)
                addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    background = W.rounded(ctx, R.color.background, 8f)
                    setPadding(dp(12f), dp(10f), dp(12f), dp(10f))
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10f) }
                    addView(W.icon(ctx, R.drawable.ic_triangle_up, 10f, R.color.w_mint))
                    addView(W.icon(ctx, R.drawable.ic_triangle_down, 10f, R.color.w_trend_amber))
                    addView(W.body(ctx, "${W.dateShort(d.date)} vs. los últimos 30 días", 14f, R.color.text_primary).apply { setPadding(dp(10f), 0, 0, 0) })
                })
            })

            // ---------- Explicación del nivel ----------
            val weekLoad = week.mapNotNull { byDate[it]?.strain }.sum()
            val prevWeeks = prev.mapNotNull { it.strain }.takeIf { it.size >= 7 }?.average()?.times(7)
            val levelText = when {
                day.strain == null -> "Todavía no hay esfuerzo calculado para este día."
                strain < 10 -> "Se considera que el esfuerzo por debajo de 10 es ligero."
                strain < 14 -> "Se considera que el esfuerzo entre 10 y 13,9 es moderado."
                strain < 18 -> "Se considera que el esfuerzo entre 14 y 17,9 es alto."
                else -> "Un esfuerzo de 18 o más es máximo: tu cuerpo necesitará recuperarse bien."
            }
            val loadText = prevWeeks?.let {
                when {
                    weekLoad < it * 0.8 -> " Tu carga cardiovascular acumulada es baja."
                    weekLoad > it * 1.2 -> " Tu carga cardiovascular acumulada es alta."
                    else -> " Tu carga cardiovascular acumulada está en tu media."
                }
            } ?: ""
            val targetText = target?.let { " Para tu recuperación de hoy, el esfuerzo recomendado ronda ${Ui.comma(it, 0)} (la marca blanca del anillo)." } ?: ""
            content.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                background = android.graphics.drawable.GradientDrawable().apply {
                    cornerRadius = dp(14f).toFloat()
                    setStroke(dp(1.5f), Ui.color(ctx, R.color.w_insight_border))
                    setColor(Ui.color(ctx, R.color.w_bg_mid))
                }
                setPadding(dp(16f), dp(16f), dp(16f), dp(16f))
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16f) }
                addView(W.body(ctx, levelText + loadText + targetText, 15.5f, R.color.text_primary))
            })

            // ---------- Actividades del día ----------
            content.addView(TextView(ctx).apply {
                text = if (d.isToday) "Actividades de hoy" else "Actividades del día"
                setTextAppearance(R.style.HeadingW); setPadding(0, dp(30f), 0, dp(14f))
            })
            val time = SimpleDateFormat("H:mm", es)
            if (d.sessions.isEmpty()) content.addView(W.body(ctx, "No hay actividades este día. Añádelas con el + de Inicio.", 14f))
            d.sessions.forEach { s ->
                content.addView(W.activityRow(ctx, R.color.strain_blue, W.sportIcon(s.type), Ui.comma(s.strain), s.type,
                    time.format(Date(s.startMillis)), time.format(Date(s.endMillis))).apply {
                    setOnClickListener {
                        startActivity(Intent(ctx, ActivityDetailActivity::class.java).putExtra(ActivityDetailActivity.EXTRA_SESSION_ID, s.id))
                    }
                })
            }

            // ---------- Tendencias semanales ----------
            content.addView(TextView(ctx).apply {
                text = "Tendencias semanales"; setTextAppearance(R.style.HeadingW); setPadding(0, dp(28f), 0, dp(2f))
            })
            val days = W.weekDays(week)
            val recs = week.map { byDate[it] }
            val blue = Ui.color(ctx, R.color.strain_blue)
            val white = Ui.color(ctx, R.color.text_primary)
            content.addView(W.chartCard(ctx, "Esfuerzo", emptyList(), WeekChartView(ctx).apply {
                setBars(days, recs.map { r -> r?.strain?.let { listOf(it.toFloat() to blue) } },
                    recs.map { r -> r?.strain?.let { WeekChartView.Label(Ui.comma(it), blue) } }, 21f)
            }))
            val z = listOf(R.color.w_zone1_bar, R.color.w_zone2_bar, R.color.w_zone3_bar, R.color.w_zone4_bar, R.color.w_zone5_bar).map { Ui.color(ctx, it) }
            content.addView(W.chartCard(ctx, "Zonas de FC 1-3", listOf("Zona 1" to R.color.w_zone1_bar, "Zona 2" to R.color.w_zone2_bar, "Zona 3" to R.color.w_zone3_bar),
                WeekChartView(ctx).apply {
                    setBars(days, recs.map { r -> r?.zones?.let { listOf(it.z1 / 60f to z[0], it.z2 / 60f to z[1], it.z3 / 60f to z[2]) } },
                        recs.map { r -> r?.zones?.let { WeekChartView.Label(Ui.hm(it.z13Seconds / 60), white) } })
                }))
            content.addView(W.chartCard(ctx, "Zonas de FC 4-5", listOf("Zona 4" to R.color.w_zone4_bar, "Zona 5" to R.color.w_zone5_bar),
                WeekChartView(ctx).apply {
                    setBars(days, recs.map { r -> r?.zones?.let { listOf(it.z4 / 60f to z[3], it.z5 / 60f to z[4]) } },
                        recs.map { r -> r?.zones?.let { WeekChartView.Label(Ui.hm(it.z45Seconds / 60), white) } }, 30f)
                }))
            content.addView(W.chartCard(ctx, "Pasos", emptyList(), WeekChartView(ctx).apply {
                setBars(days, recs.map { r -> r?.steps?.let { listOf(it.toFloat() to blue) } },
                    recs.map { r -> r?.steps?.let { WeekChartView.Label(Ui.thousands(it.toLong()), blue) } })
            }))
            content.addView(W.chartCard(ctx, "Calorías", emptyList(), WeekChartView(ctx).apply {
                setBars(days, recs.map { r -> r?.kcal?.let { listOf(it.toFloat() to blue) } },
                    recs.map { r -> r?.kcal?.let { WeekChartView.Label(Ui.thousands(Math.round(it)), blue) } })
            }))
            content.addView(W.chartCard(ctx, "Tiempo de actividad de fuerza", emptyList(), WeekChartView(ctx).apply {
                setBars(days, week.map { dd -> listOf((byDate[dd]?.strengthMinutes ?: 0).toFloat() to blue) },
                    week.map { dd -> WeekChartView.Label(Ui.hm(byDate[dd]?.strengthMinutes ?: 0), white) }, 30f)
            }))

            // ---------- Historial ----------
            val all = AppDatabaseHolder.get(ctx).activitySessionDao().getAll().sortedByDescending { it.startMillis }.take(30)
            if (all.isNotEmpty()) {
                content.addView(TextView(ctx).apply {
                    text = "Todas las actividades"; setTextAppearance(R.style.HeadingW); setPadding(0, dp(28f), 0, dp(14f))
                })
                val dayFmt = SimpleDateFormat("d MMM", es)
                all.forEach { s ->
                    content.addView(W.activityRow(ctx, R.color.strain_blue, W.sportIcon(s.type), Ui.comma(s.strain), s.type,
                        dayFmt.format(Date(s.startMillis)), time.format(Date(s.startMillis))).apply {
                        setOnClickListener {
                            startActivity(Intent(ctx, ActivityDetailActivity::class.java).putExtra(ActivityDetailActivity.EXTRA_SESSION_ID, s.id))
                        }
                    })
                }
            }
        }
    }
}
