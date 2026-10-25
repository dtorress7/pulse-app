package com.pulseapp.android

import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.ui.ActivityHrChartView
import com.pulseapp.android.ui.CircularRingView
import com.pulseapp.android.ui.SleepTimelineBar
import com.pulseapp.android.ui.StressDayChartView
import com.pulseapp.android.ui.TriSegmentView
import com.pulseapp.android.ui.WeekChartView
import com.pulseapp.android.ui.StageTimelineBarView
import com.pulseapp.android.ui.ZoneBarView
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
 * Sueño con el aspecto de WHOOP (17/10): calificación con sus 4 componentes, "El sueño de anoche" (pulso, fases, sueño
 * reparador, latencia), horas vs lo necesario, regularidad, eficiencia, estrés del sueño y tendencias semanales.
 * Se abre desde Inicio con el día elegido (EXTRA_DAY_OFFSET) o desde la pestaña Sueño (hoy).
 */
class SleepDetailActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_DAY_OFFSET = "day_offset"
    }

    private val zone: ZoneId = ZoneId.systemDefault()
    private var offset = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_sleep_detail)
        window.statusBarColor = Ui.color(this, R.color.w_bg_top)
        offset = intent.getIntExtra(EXTRA_DAY_OFFSET, 0)
        Ui.setupDetailHeader(this, W.dateTitle(LocalDate.now().plusDays(offset.toLong())))
        findViewById<View>(R.id.backButton).visibility = if (intent.hasExtra(EXTRA_DAY_OFFSET)) View.VISIBLE else View.INVISIBLE
        Ui.setupTabBar(this, Ui.Tab.SLEEP)
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun hm(m: Int?) = m?.let { Ui.hm(it) } ?: "--"
    private fun dp(v: Float) = Ui.dp(this, v)

    /** Minuto del día → minutos desde las 12:00 del día anterior (la noche queda continua en las gráficas). */
    private fun nightAxis(m: Int) = (if (m >= 720) m - 720 else m + 720).toFloat()

    private fun level(v: Int?, opt: Int, ok: Int) = when { v == null -> -1; v >= opt -> 2; v >= ok -> 1; else -> 0 }

    private fun load() {
        lifecycleScope.launch {
            val ctx = this@SleepDetailActivity
            val d = HomeDataLoader(ctx).load(offset)
            val day = d.day
            val prev = d.records.filter { it.date < d.date && it.date >= d.date.minusDays(30) }
            val week = (6 downTo 0).map { d.date.minusDays(it.toLong()) }
            val byDate = d.records.associateBy { it.date }
            fun avg(f: (DayRecord) -> Int?): Double? = prev.mapNotNull(f).takeIf { it.isNotEmpty() }?.average()

            // Noches de la semana (para el estrés del sueño) + la de hoy con margen para la gráfica de pulso
            val nights: Map<LocalDate, LongRange> = week.mapNotNull { date ->
                val r = byDate[date] ?: return@mapNotNull null
                if (date == d.date && d.sleepFromMillis != null && d.sleepToMillis != null) return@mapNotNull date to (d.sleepFromMillis..d.sleepToMillis)
                val s = r.sleepStartMinute ?: return@mapNotNull null
                val e = r.sleepEndMinute ?: return@mapNotNull null
                val dayStart = date.atStartOfDay(zone).toInstant().toEpochMilli()
                val to = dayStart + e * 60_000L
                val from = if (s > e) dayStart - (1440 - s) * 60_000L else dayStart + s * 60_000L
                date to (from..to)
            }.toMap()
            val file = File(getExternalFilesDir(null), "hr_log.csv")
            val calc = StressCalculator()
            val samples = withContext(Dispatchers.IO) {
                calc.loadSamplesIn(file, nights.values.map { (it.first - 15 * 60_000L)..(it.last + 15 * 60_000L) })
            }
            val baseline = BaselineProvider().compute(AppDatabaseHolder.get(ctx))
            val nightStress = nights.mapValues { (date, r) ->
                if (date == d.date && d.sleepStressSeries.isNotEmpty()) d.sleepStressSeries
                else calc.seriesBetween(samples, r.first, r.last, byDate[date]?.rhr, baseline)
            }
            fun stressMins(date: LocalDate): StressBreakdown.Mins? = nightStress[date]?.takeIf { it.isNotEmpty() }?.let {
                StressBreakdown.of(it, emptyList(), emptyList()).total
            }
            fun highPct(m: StressBreakdown.Mins?) = m?.takeIf { it.total > 0 }?.let { Math.round(it.high * 100.0 / it.total).toInt() }

            val content = findViewById<LinearLayout>(R.id.detailContent)
            content.removeAllViews()

            // ---------- Calificación ----------
            val score = day.sleepScore
            content.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(0, dp(14f), 0, 0)
                addView(CircularRingView(ctx).apply {
                    strokeRatio = 0.055f; numberRatio = 0.26f; suffixRatio = 0.5f; suffixSameColor = true; labelRatio = 0.052f
                    topText = "PULSE"
                    setTrackColor(Ui.color(ctx, R.color.w_track)); setLabelColor(Ui.color(ctx, R.color.text_primary))
                    setValue((score ?: 0) / 100f, score?.let { "$it%" } ?: "--", "Calificación\ndel sueño", Ui.color(ctx, R.color.w_ring_sleep))
                    layoutParams = LinearLayout.LayoutParams(dp(260f), dp(260f))
                })
            })

            val hvn = day.hoursVsNeedPct
            val stressToday = stressMins(d.date)
            val high = highPct(stressToday)
            content.addView(W.card(ctx, 18f).apply {
                setPadding(dp(16f), dp(6f), dp(16f), dp(16f))
                fun row(icon: Int, label: String, value: String, lvl: Int) {
                    addView(LinearLayout(ctx).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        setPadding(0, dp(16f), 0, dp(16f))
                        addView(W.icon(ctx, icon, 20f, R.color.text_secondary))
                        addView(W.title(ctx, label, 13f).apply { layoutParams = W.weight().apply { marginStart = dp(12f) } })
                        addView(TriSegmentView(ctx).apply { this.level = lvl; layoutParams = LinearLayout.LayoutParams(dp(54f), dp(5f)) })
                        addView(W.number(ctx, value, 23f).apply {
                            gravity = Gravity.END; layoutParams = LinearLayout.LayoutParams(dp(64f), LinearLayout.LayoutParams.WRAP_CONTENT)
                        })
                    })
                    addView(W.divider(ctx))
                }
                row(R.drawable.ic_sleep_need, "Horas vs. lo necesario", hvn?.let { "$it %" } ?: "--", level(hvn, 85, 70))
                row(R.drawable.ic_regularity, "Regularidad del sueño", day.consistency?.let { "$it %" } ?: "--", level(day.consistency, 80, 65))
                row(R.drawable.ic_efficiency, "Eficiencia del sueño", day.efficiency?.let { "$it %" } ?: "--", level(day.efficiency, 90, 80))
                row(R.drawable.ic_gauge, "Estrés del sueño alto", high?.let { "$it %" } ?: "--",
                    if (high == null) -1 else if (high == 0) 2 else if (high <= 5) 1 else 0)
                removeViewAt(childCount - 1)
                addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER
                    background = W.rounded(ctx, R.color.background, 8f)
                    setPadding(dp(10f), dp(10f), dp(10f), dp(10f))
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(12f) }
                    listOf("Deficiente" to R.color.w_trend_amber, "Suficiente" to R.color.text_secondary, "Óptimo" to R.color.w_mint).forEach { (n, c) ->
                        addView(View(ctx).apply { background = W.rounded(ctx, c, 2f); layoutParams = LinearLayout.LayoutParams(dp(14f), dp(4f)).apply { marginStart = dp(14f) } })
                        addView(W.body(ctx, n, 13.5f).apply { setPadding(dp(8f), 0, 0, 0) })
                    }
                })
            })

            // ---------- El sueño de anoche ----------
            content.addView(android.widget.TextView(ctx).apply {
                text = "El sueño de anoche"
                setTextAppearance(R.style.HeadingW)
                setPadding(0, dp(34f), 0, 0)
            })
            content.addView(W.body(ctx, "${W.dateShort(d.date)} vs. los 30 días anteriores", 14f))

            val sleepCard = W.card(ctx, 16f)
            sleepCard.addView(W.metricHeader(ctx, "Horas de sueño", hm(day.sleepMinutes),
                W.trendOf(day.sleepMinutes?.toDouble(), avg { it.sleepMinutes }, 5.0), true, avg { it.sleepMinutes }?.let { Ui.hm(Math.round(it).toInt()) },
                "Tiempo dormido de verdad: la noche menos los ratos despierto."))
            val from = d.sleepFromMillis; val to = d.sleepToMillis
            val hyp = d.stages
            var hrChart: ActivityHrChartView? = null
            if (from != null && to != null) {
                val pts = samples.filter { it.timeMillis in (from - 10 * 60_000L)..(to + 10 * 60_000L) }
                    .groupBy { it.timeMillis / 30_000 }.entries.sortedBy { it.key }
                    .map { (k, v) -> k * 30_000 to Math.round(v.map { it.bpm }.average()).toInt() }
                if (pts.size >= 2) sleepCard.addView(ActivityHrChartView(ctx).apply {
                    yStep = 20.0; filled = false; setLineColor(Ui.color(ctx, R.color.w_hr_sleep))
                    setData(pts, from, to)
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(220f)).apply { topMargin = dp(14f) }
                    hrChart = this
                })
            }
            // Fase elegida (como WHOOP: se pinta en la gráfica de pulso y en su barra) y "Rango típico"
            var selected: Int? = null
            var showTypical = hyp == null
            val typicalBox = View(ctx).apply { layoutParams = LinearLayout.LayoutParams(dp(14f), dp(14f)) }
            fun paintTypicalBox() {
                typicalBox.setBackgroundResource(if (showTypical) R.drawable.bg_avatar_w else R.drawable.bg_outline_card_w)
            }
            paintTypicalBox()
            val stageBox = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
            var render: () -> Unit = {}
            sleepCard.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, dp(18f), 0, dp(4f))
                addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    addView(typicalBox)
                    addView(W.title(ctx, "Rango típico", 13f, R.color.text_secondary).apply { setPadding(dp(10f), 0, 0, 0) })
                    if (hyp != null) setOnClickListener { showTypical = !showTypical; paintTypicalBox(); render() }
                    layoutParams = W.weight()
                })
                addView(W.title(ctx, "Duración  ", 13f, R.color.text_secondary))
                addView(W.number(ctx, hm(day.inBed), 17f))
            })
            sleepCard.addView(stageBox)
            val inBed = day.inBed
            if (day.light != null && day.deep != null && day.rem != null && inBed != null && inBed > 0) {
                fun typical(f: (DayRecord) -> Int?): Pair<Float, Float>? {
                    val fr = prev.mapNotNull { r -> val v = f(r); val ib = r.inBed; if (v != null && ib != null && ib > 0) v.toFloat() / ib else null }.sorted()
                    return when {
                        fr.size >= 4 -> fr[fr.size / 4] to fr[(fr.size * 3) / 4]
                        fr.size >= 2 -> fr.first() to fr.last()
                        else -> null
                    }
                }
                val awake = day.awake ?: (inBed - day.light - day.deep - day.rem).coerceAtLeast(0)
                val rows = listOf(
                    Triple("Despierto", awake, R.color.w_stage_awake) to typical { it.awake },
                    Triple("Ligero", day.light, R.color.w_stage_light) to typical { it.light },
                    Triple("Sueño profundo (SWS)", day.deep, R.color.w_stage_deep) to typical { it.deep },
                    Triple("REM", day.rem, R.color.w_stage_rem) to typical { it.rem }
                )
                render = {
                    stageBox.removeAllViews()
                    rows.forEachIndexed { idx, (st, typ) ->
                        val (name, mins, color) = st
                        val frac = mins.toFloat() / inBed
                        val on = selected == idx
                        val row = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
                        row.addView(LinearLayout(ctx).apply {
                            orientation = LinearLayout.HORIZONTAL
                            gravity = Gravity.CENTER_VERTICAL
                            setPadding(0, dp(16f), 0, 0)
                            addView(android.widget.FrameLayout(ctx).apply {
                                setBackgroundResource(R.drawable.bg_avatar_w)
                                if (on) addView(View(ctx).apply {
                                    background = android.graphics.drawable.GradientDrawable().apply {
                                        shape = android.graphics.drawable.GradientDrawable.OVAL; setColor(Ui.color(ctx, R.color.text_primary))
                                    }
                                    layoutParams = android.widget.FrameLayout.LayoutParams(dp(14f), dp(14f), Gravity.CENTER)
                                })
                                layoutParams = LinearLayout.LayoutParams(dp(24f), dp(24f))
                            })
                            addView(W.title(ctx, name, 14f).apply { setPadding(dp(12f), 0, 0, 0) })
                            addView(W.number(ctx, "${Math.round(frac * 100)} %", 14f, if (selected == null || on) color else R.color.text_secondary)
                                .apply { setPadding(dp(10f), 0, 0, 0); layoutParams = W.weight() })
                            addView(W.number(ctx, Ui.hm(mins), 19f))
                        })
                        if (hyp != null && !showTypical) {
                            row.addView(StageTimelineBarView(ctx).apply {
                                setData(hyp.stages, idx, Ui.color(ctx, color), on)
                                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(30f)).apply { topMargin = dp(4f) }
                            })
                        } else {
                            row.addView(ZoneBarView(ctx).apply {
                                setData(frac, Ui.color(ctx, color), typ?.first, typ?.second)
                                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(30f)).apply { topMargin = dp(4f) }
                            })
                        }
                        if (hyp != null) row.setOnClickListener {
                            selected = if (on) null else idx
                            row.performHapticFeedback(android.view.HapticFeedbackConstants.CLOCK_TICK)
                            render()
                        }
                        stageBox.addView(row)
                    }
                    val sel = selected
                    if (hyp != null && sel != null) {
                        val ranges = ArrayList<Pair<Long, Long>>()
                        var i = 0
                        while (i < hyp.stages.size) {
                            if (hyp.stages[i] != sel) { i++; continue }
                            var j = i
                            while (j < hyp.stages.size && hyp.stages[j] == sel) j++
                            ranges.add(hyp.startMillis + i * 60_000L to hyp.startMillis + j * 60_000L)
                            i = j
                        }
                        hrChart?.setHighlights(ranges, Ui.color(ctx, rows[sel].first.third))
                    } else hrChart?.setHighlights(emptyList(), 0)
                }
                render()
            } else {
                sleepCard.addView(W.body(ctx, "Las fases (ligero, profundo y REM) aparecen las noches en que el movimiento estaba activado en Mi WHOOP.", 14f)
                    .apply { setPadding(0, dp(10f), 0, dp(4f)) })
            }
            sleepCard.addView(View(ctx).apply { layoutParams = LinearLayout.LayoutParams(1, dp(10f)) })
            sleepCard.addView(W.divider(ctx))
            sleepCard.addView(W.valueRow(ctx, null, "■  Sueño reparador", hm(day.restorative),
                W.trendOf(day.restorative?.toDouble(), avg { it.restorative }, 5.0), true, avg { it.restorative }?.let { Ui.hm(Math.round(it).toInt()) }))
            sleepCard.addView(W.divider(ctx))
            sleepCard.addView(W.valueRow(ctx, null, "■  Latencia de inicio del sueño", hm(day.latency)))
            content.addView(sleepCard)

            // ---------- Horas vs. lo necesario ----------
            val need = day.needLastNight
            content.addView(W.card(ctx, 14f).apply {
                addView(W.metricHeader(ctx, "Horas vs. lo necesario", hvn?.let { "$it %" } ?: "--",
                    W.trendOf(hvn?.toDouble(), avg { it.hoursVsNeedPct }), true, avg { it.hoursVsNeedPct }?.let { "%.0f %%".format(it) },
                    "Lo que dormiste frente a lo que necesitabas: un mínimo saludable para tu edad más lo que suman el esfuerzo de la víspera y la deuda de sueño."))
                if (need != null && need > 0) {
                    val slept = day.sleepMinutes ?: 0
                    addView(LinearLayout(ctx).apply {
                        orientation = LinearLayout.HORIZONTAL
                        setPadding(dp(8f), dp(20f), dp(8f), dp(8f))
                        addView(W.title(ctx, "Horas de sueño", 13f, R.color.text_secondary).apply { layoutParams = W.weight() })
                        addView(W.number(ctx, Ui.hm(slept), 17f))
                    })
                    addView(Ui.progressBar(ctx, (slept.toFloat() / need).coerceAtMost(1f), R.color.w_ring_sleep).apply {
                        (layoutParams as LinearLayout.LayoutParams).height = dp(14f)
                    })
                    addView(LinearLayout(ctx).apply {
                        orientation = LinearLayout.HORIZONTAL
                        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(14f)).apply { topMargin = dp(14f) }
                        Ui.fillStackedBar(this, listOf((day.needBase ?: 0).toFloat() to R.color.w_need_base,
                            (day.needStrainAdj ?: 0).toFloat() to R.color.strain_blue, (day.needDebtAdj ?: 0).toFloat() to R.color.w_need_debt))
                    })
                    addView(LinearLayout(ctx).apply {
                        orientation = LinearLayout.HORIZONTAL
                        setPadding(dp(8f), dp(10f), dp(8f), dp(12f))
                        addView(W.title(ctx, "Sueño necesario", 13f, R.color.text_secondary).apply { layoutParams = W.weight() })
                        addView(W.number(ctx, Ui.hm(need), 17f))
                    })
                    addView(LinearLayout(ctx).apply {
                        orientation = LinearLayout.VERTICAL
                        background = W.rounded(ctx, R.color.background, 8f)
                        setPadding(dp(14f), dp(6f), dp(14f), dp(6f))
                        listOf(Triple("Mínimo saludable", Ui.hm(day.needBase ?: 0), R.color.w_need_base),
                            Triple("Esfuerzo reciente", "+" + Ui.hm(day.needStrainAdj ?: 0), R.color.strain_blue),
                            Triple("Deuda del sueño", "+" + Ui.hm(day.needDebtAdj ?: 0), R.color.w_need_debt)).forEach { (n, v, c) ->
                            addView(LinearLayout(ctx).apply {
                                orientation = LinearLayout.HORIZONTAL
                                gravity = Gravity.CENTER_VERTICAL
                                setPadding(0, dp(8f), 0, dp(8f))
                                addView(View(ctx).apply { background = W.rounded(ctx, c, 2f); layoutParams = LinearLayout.LayoutParams(dp(12f), dp(12f)) })
                                addView(W.body(ctx, n, 14.5f, R.color.text_primary).apply { setPadding(dp(12f), 0, 0, 0); layoutParams = W.weight() })
                                addView(W.number(ctx, v, 16f))
                            })
                        }
                    })
                }
            })

            // ---------- Regularidad ----------
            val wake = SleepPlanner.wakeMinute(ctx)
            val last5 = week.takeLast(5)
            content.addView(W.card(ctx, 14f).apply {
                addView(W.metricHeader(ctx, "Regularidad del sueño", day.consistency?.let { "$it %" } ?: "--",
                    W.trendOf(day.consistency?.toDouble(), avg { it.consistency }), true, avg { it.consistency }?.let { "%.0f %%".format(it) },
                    "Lo parecida que es tu hora de dormirte cada noche (últimas 7 noches)."))
                addView(W.title(ctx, "- -  Hora óptima de acostarse/despertar", 12f, R.color.text_secondary).apply {
                    gravity = Gravity.END; setPadding(0, dp(6f), 0, 0)
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                })
                val ranges = last5.map { date ->
                    val r = byDate[date]
                    val s = r?.sleepStartMinute; val e = r?.sleepEndMinute
                    if (s == null || e == null) null
                    else WeekChartView.Range(nightAxis(s), nightAxis(e), if (date == d.date) "%02d:%02d".format(s / 60, s % 60) else null,
                        if (date == d.date) "%d:%02d".format(e / 60, e % 60) else null)
                }
                val optimal = last5.map { date ->
                    val n = byDate[date]?.needLastNight ?: return@map null
                    val bed = ((wake - n) % 1440 + 1440) % 1440
                    nightAxis(bed) to nightAxis(wake)
                }
                addView(WeekChartView(ctx).apply {
                    setRanges(W.weekDays(last5), ranges, Ui.color(ctx, R.color.w_ring_sleep), dimPrevious = true,
                        yLabels = listOf(nightAxis(19 * 60) to "19:00", nightAxis(23 * 60) to "23:00", nightAxis(3 * 60) to "03:00", nightAxis(7 * 60) to "07:00"),
                        optimal = optimal)
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(230f)).apply { topMargin = dp(8f) }
                })
            })

            // ---------- Eficiencia ----------
            content.addView(W.card(ctx, 14f).apply {
                addView(W.metricHeader(ctx, "Eficiencia del sueño", day.efficiency?.let { "$it %" } ?: "--",
                    W.trendOf(day.efficiency?.toDouble(), avg { it.efficiency }), true, avg { it.efficiency }?.let { "%.0f %%".format(it) },
                    "El porcentaje del tiempo en cama que estuviste dormido."))
                fun labelRow(name: String, v: String) = LinearLayout(ctx).apply {
                    orientation = LinearLayout.HORIZONTAL
                    setPadding(dp(8f), dp(16f), dp(8f), dp(8f))
                    addView(W.title(ctx, name, 13f, R.color.text_secondary).apply { layoutParams = W.weight() })
                    addView(W.number(ctx, v, 17f))
                }
                val stages = d.stages
                addView(labelRow("Dormido", hm(day.sleepMinutes)))
                if (stages != null) {
                    addView(SleepTimelineBar(ctx).apply { setStages(stages.stages, false); layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(16f)) })
                    addView(SleepTimelineBar(ctx).apply {
                        setStages(stages.stages, true)
                        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(16f)).apply { topMargin = dp(10f) }
                    })
                } else {
                    addView(Ui.progressBar(ctx, (day.efficiency ?: 0) / 100f, R.color.w_ring_sleep).apply { (layoutParams as LinearLayout.LayoutParams).height = dp(16f) })
                }
                addView(labelRow("Despierto", hm(day.awake)))
                addView(W.divider(ctx))
                addView(W.valueRow(ctx, null, "■  Episodios de despertar", day.wakeEpisodes?.toString() ?: "--",
                    W.trendOf(day.wakeEpisodes?.toDouble(), avg { it.wakeEpisodes }), false, avg { it.wakeEpisodes }?.let { "%.0f".format(it) }))
            })

            // ---------- Estrés del sueño ----------
            val avgHigh = week.filter { it < d.date }.mapNotNull { highPct(stressMins(it)) }.takeIf { it.isNotEmpty() }?.average()
            content.addView(W.card(ctx, 14f).apply {
                addView(W.metricHeader(ctx, "Estrés del sueño", high?.let { "$it %" } ?: "--", W.trendOf(high?.toDouble(), avgHigh), false,
                    avgHigh?.let { "%.0f %%".format(it) }, "Porcentaje de la noche con estrés alto (los demás niveles, debajo)."))
                if (from != null && to != null && d.sleepStressSeries.isNotEmpty()) {
                    addView(StressDayChartView(ctx).apply {
                        setData(d.sleepStressSeries, from, to, from, to, true)
                        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(230f)).apply { topMargin = dp(10f) }
                    })
                }
                val m = stressToday
                if (m != null && m.total > 0) listOf(Triple("Alto", m.high, R.color.alert_amber), Triple("Medio", m.mid, R.color.w_mint), Triple("Bajo", m.low, R.color.w_low_blue))
                    .forEach { (n, v, c) ->
                        val f = v.toFloat() / m.total
                        addView(LinearLayout(ctx).apply {
                            orientation = LinearLayout.HORIZONTAL
                            gravity = Gravity.CENTER_VERTICAL
                            setPadding(0, dp(16f), 0, 0)
                            addView(W.title(ctx, n, 13.5f))
                            addView(W.number(ctx, "${Math.round(f * 100)} %", 13.5f, c).apply { setPadding(dp(8f), 0, 0, 0); layoutParams = W.weight() })
                            addView(W.number(ctx, Ui.hm(v), 18f))
                        })
                        addView(ZoneBarView(ctx).apply {
                            setData(f, Ui.color(ctx, c), null, null)
                            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(28f))
                        })
                    }
            })

            // ---------- Tendencias semanales ----------
            content.addView(android.widget.TextView(ctx).apply {
                text = "Tendencias semanales"; setTextAppearance(R.style.HeadingW); setPadding(0, dp(34f), 0, dp(2f))
            })
            val days = W.weekDays(week)
            val recs = week.map { byDate[it] }
            val blue = Ui.color(ctx, R.color.w_ring_sleep)
            fun bars(values: List<Int?>, color: Int, label: (Int) -> String) = WeekChartView(ctx).apply {
                setBars(days, values.map { v -> v?.let { listOf(it.toFloat() to color) } }, values.map { v -> v?.let { WeekChartView.Label(label(it), color) } })
            }
            content.addView(W.chartCard(ctx, "Calificación del sueño", emptyList(), bars(recs.map { it?.sleepScore }, blue) { "$it %" }))
            val mint = Ui.color(ctx, R.color.w_mint)
            content.addView(W.chartCard(ctx, "Horas vs. lo necesario (horas)",
                listOf("Horas de sueño" to R.color.w_ring_sleep, "Sueño necesario" to R.color.w_mint),
                WeekChartView(ctx).apply {
                    setLines(days, listOf(
                        WeekChartView.Series(recs.map { it?.sleepMinutes?.toFloat() }, blue, recs.map { it?.sleepMinutes?.let { m -> Ui.hm(m) } }, true),
                        WeekChartView.Series(recs.map { it?.needLastNight?.toFloat() }, mint, recs.map { it?.needLastNight?.let { m -> Ui.hm(m) } }, false)
                    ))
                }))
            content.addView(W.chartCard(ctx, "Horas vs. lo necesario (%)", emptyList(), bars(recs.map { it?.hoursVsNeedPct }, blue) { "$it %" }))
            val deepC = Ui.color(ctx, R.color.w_stage_deep); val remC = Ui.color(ctx, R.color.w_stage_rem)
            content.addView(W.chartCard(ctx, "Sueño reparador (horas)", listOf("Sueño profundo" to R.color.w_stage_deep, "Sueño REM" to R.color.w_stage_rem),
                WeekChartView(ctx).apply {
                    setBars(days, recs.map { r -> if (r?.deep != null && r.rem != null) listOf(r.rem.toFloat() to remC, r.deep.toFloat() to deepC) else null },
                        recs.map { r -> r?.restorative?.let { WeekChartView.Label(Ui.hm(it), Ui.color(ctx, R.color.text_primary)) } })
                }))
            content.addView(W.chartCard(ctx, "Regularidad del sueño", emptyList(), bars(recs.map { it?.consistency }, blue) { "$it %" }))
            content.addView(W.chartCard(ctx, "Tiempo en cama", emptyList(), WeekChartView(ctx).apply {
                setRanges(days, recs.map { r ->
                    val s = r?.sleepStartMinute; val e = r?.sleepEndMinute
                    if (s == null || e == null) null else WeekChartView.Range(nightAxis(s), nightAxis(e), "%02d:%02d".format(s / 60, s % 60), "%02d:%02d".format(e / 60, e % 60))
                }, blue)
            }))
            content.addView(W.chartCard(ctx, "Eficiencia del sueño", emptyList(), WeekChartView(ctx).apply {
                setLines(days, listOf(WeekChartView.Series(recs.map { it?.efficiency?.toFloat() }, blue, recs.map { it?.efficiency?.let { e -> "$e %" } }, false)))
            }))
            content.addView(W.chartCard(ctx, "Deuda de sueño", emptyList(), bars(recs.map { it?.debt }, blue) { Ui.hm(it) }))
            val lowC = Ui.color(ctx, R.color.w_low_blue); val amber = Ui.color(ctx, R.color.alert_amber)
            val weekStress = week.map { stressMins(it) }
            content.addView(W.chartCard(ctx, "Estrés del sueño", listOf("Alto" to R.color.alert_amber, "Medio" to R.color.w_mint, "Bajo" to R.color.w_low_blue),
                WeekChartView(ctx).apply {
                    setBars(days, weekStress.map { m -> m?.let { listOf(it.low.toFloat() to lowC, it.mid.toFloat() to mint, it.high.toFloat() to amber) } },
                        weekStress.map { m -> m?.let { WeekChartView.Label(Ui.hm(it.high), amber) } })
                }))
        }
    }
}

/** Acceso corto a la base de datos desde las pantallas nuevas. */
object AppDatabaseHolder {
    fun get(ctx: android.content.Context) = com.pulseapp.android.data.AppDatabase.getInstance(ctx)
}
