package com.pulseapp.android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.core.content.res.ResourcesCompat
import java.util.Locale

/** Utilidades compartidas del rediseño: barra inferior, formatos y piezas de UI hechas por código. */
object Ui {

    enum class Tab { HOME, HEALTH, SLEEP, ACTIVITIES, COMMUNITY, NONE }

    // ---------- Formatos ----------
    fun hm(minutes: Int): String = "%d:%02d".format(minutes / 60, kotlin.math.abs(minutes % 60))
    fun comma(value: Double, decimals: Int = 1): String =
        "%.${decimals}f".format(Locale.US, value).replace('.', ',')
    fun thousands(value: Long): String =
        java.text.NumberFormat.getIntegerInstance(Locale("es", "ES")).format(value)
    fun dp(context: Context, v: Float): Int = (v * context.resources.displayMetrics.density).toInt()
    fun color(context: Context, res: Int): Int = ContextCompat.getColor(context, res)

    fun recoveryColor(score: Int): Int = when {
        score >= 67 -> R.color.recovery_green
        score >= 34 -> R.color.alert_amber
        else -> R.color.alert_red
    }

    fun stressColor(level: String): Int = when (level) {
        "ALTO" -> R.color.alert_amber
        "MEDIO" -> R.color.recovery_green
        else -> R.color.strain_blue
    }

    // ---------- Barra inferior ----------
    fun setupTabBar(activity: Activity, selected: Tab) {
        val tabs = mapOf(
            Tab.HOME to (R.id.tabHome to MainActivity::class.java),
            Tab.HEALTH to (R.id.tabHealth to HealthActivity::class.java),
            Tab.SLEEP to (R.id.tabSleep to SleepDetailActivity::class.java),
            Tab.ACTIVITIES to (R.id.tabActivities to ActivitiesListActivity::class.java),
            Tab.COMMUNITY to (R.id.tabCommunity to CommunityActivity::class.java)
        )
        tabs.forEach { (tab, pair) ->
            val view = activity.findViewById<TextView>(pair.first) ?: return@forEach
            val active = tab == selected
            val c = color(activity, if (active) R.color.text_primary else R.color.text_secondary)
            view.setTextColor(c)
            view.compoundDrawableTintList = ColorStateList.valueOf(c)
            view.typeface = ResourcesCompat.getFont(activity, if (active) R.font.archivo_semibold else R.font.archivo_medium)
            view.setOnClickListener {
                if (active) return@setOnClickListener
                val intent = Intent(activity, pair.second).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                activity.startActivity(intent)
                @Suppress("DEPRECATION")
                activity.overridePendingTransition(0, 0)
            }
        }
        activity.findViewById<View>(R.id.tabCoach)?.setOnClickListener {
            Toast.makeText(activity, "Coach: próximamente", Toast.LENGTH_SHORT).show()
        }
    }

    /** Cabecera de detalle (include_detail_header): título + botón atrás. */
    fun setupDetailHeader(activity: Activity, title: String) {
        activity.findViewById<TextView>(R.id.headerTitle)?.text = title
        activity.findViewById<View>(R.id.backButton)?.setOnClickListener { activity.finish() }
    }

    // ---------- Piezas hechas por código ----------

    /** Rellena un LinearLayout horizontal con segmentos proporcionales (barra apilada de 8 dp). */
    fun fillStackedBar(bar: LinearLayout, parts: List<Pair<Float, Int>>) {
        bar.removeAllViews()
        val ctx = bar.context
        val visible = parts.filter { it.first > 0f }
        if (visible.isEmpty()) {
            bar.addView(View(ctx).apply {
                setBackgroundColor(color(ctx, R.color.track_gray))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
            })
            return
        }
        visible.forEachIndexed { i, (weight, colorRes) ->
            bar.addView(View(ctx).apply {
                setBackgroundColor(color(ctx, colorRes))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, weight).apply {
                    if (i > 0) marginStart = dp(ctx, 2f)
                }
            })
        }
    }

    /** Barra de progreso simple (pista gris + relleno de color), 8 dp de alto. */
    fun progressBar(ctx: Context, fraction: Float, colorRes: Int): LinearLayout {
        val f = fraction.coerceIn(0f, 1f)
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            background = rounded(ctx, R.color.track_gray, 4f)
            clipToOutline = true
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(ctx, 8f))
            addView(View(ctx).apply {
                background = rounded(ctx, colorRes, 4f)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, f.coerceAtLeast(0.0001f))
            })
            addView(View(ctx).apply {
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, (1f - f).coerceAtLeast(0.0001f))
            })
        }
    }

    fun rounded(ctx: Context, colorRes: Int, radiusDp: Float): GradientDrawable =
        GradientDrawable().apply {
            setColor(color(ctx, colorRes))
            cornerRadius = radiusDp * ctx.resources.displayMetrics.density
        }

    /**
     * Gráfica de barras de 7 días dentro de [container] (vertical): valor arriba, barra, etiqueta del día abajo.
     * La última barra se resalta como "Hoy". Los días sin dato muestran "–" y una barra mínima gris.
     */
    fun fillWeekBars(
        container: LinearLayout,
        items: List<Triple<String, Double?, Int>>, // etiqueta, valor, color
        max: Double,
        format: (Double) -> String
    ) {
        container.removeAllViews()
        val ctx = container.context
        val barArea = dp(ctx, 96f)
        val condensed = ResourcesCompat.getFont(ctx, R.font.barlow_condensed_bold)
        val labelFont = ResourcesCompat.getFont(ctx, R.font.barlow_condensed_semibold)
        items.forEachIndexed { i, (label, value, colorRes) ->
            val isLast = i == items.lastIndex
            val col = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f).apply {
                    if (i > 0) marginStart = dp(ctx, 8f)
                }
            }
            col.addView(TextView(ctx).apply {
                text = value?.let(format) ?: "–"
                typeface = condensed
                textSize = 13f
                setTextColor(color(ctx, if (isLast) R.color.text_primary else R.color.text_secondary))
                gravity = Gravity.CENTER
            })
            val h = if (value == null || max <= 0) dp(ctx, 4f) else (barArea * (value / max).coerceIn(0.04, 1.0)).toInt()
            col.addView(View(ctx).apply {
                background = rounded(ctx, if (value == null) R.color.track_gray else colorRes, 6f)
                alpha = if (isLast || value == null) 1f else 0.55f
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, h).apply {
                    topMargin = dp(ctx, 6f); bottomMargin = dp(ctx, 6f)
                }
            })
            col.addView(TextView(ctx).apply {
                text = if (isLast) "HOY" else label.uppercase()
                typeface = labelFont
                letterSpacing = 0.14f
                textSize = 10f
                setTextColor(color(ctx, if (isLast) R.color.text_primary else R.color.text_secondary))
                gravity = Gravity.CENTER
            })
            container.addView(col)
        }
    }

    /** Fila de lista agrupada estilo iOS: texto a la izquierda, valor a la derecha. */
    fun listRow(ctx: Context, title: String, value: String, valueColorRes: Int = R.color.text_secondary, subtitle: String? = null): LinearLayout {
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(ctx, 16f), dp(ctx, 13f), dp(ctx, 16f), dp(ctx, 13f))
            val left = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                addView(TextView(ctx).apply {
                    text = title
                    textSize = 15f
                    setTextColor(color(ctx, R.color.text_primary))
                    typeface = ResourcesCompat.getFont(ctx, R.font.archivo)
                })
                if (subtitle != null) addView(TextView(ctx).apply {
                    text = subtitle
                    textSize = 12f
                    setTextColor(color(ctx, R.color.text_secondary))
                    typeface = ResourcesCompat.getFont(ctx, R.font.archivo)
                })
            }
            addView(left)
            addView(TextView(ctx).apply {
                text = value
                textSize = 18f
                typeface = ResourcesCompat.getFont(ctx, R.font.barlow_condensed_bold)
                setTextColor(color(ctx, valueColorRes))
            })
        }
    }

    fun hairline(ctx: Context, insetStartDp: Float = 16f): View = View(ctx).apply {
        setBackgroundColor(color(ctx, R.color.hairline))
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(ctx, 1f).coerceAtLeast(1)).apply {
            marginStart = dp(ctx, insetStartDp)
        }
    }

    fun emptyText(ctx: Context, message: String): TextView = TextView(ctx).apply {
        text = message
        textSize = 13f
        setTextColor(color(ctx, R.color.text_secondary))
        typeface = ResourcesCompat.getFont(ctx, R.font.archivo)
        val p = dp(ctx, 16f)
        setPadding(p, p, p, p)
    }

    fun boldCondensed(ctx: Context): Typeface? = ResourcesCompat.getFont(ctx, R.font.barlow_condensed_bold)

    /** Pasos de hoy: en directo si el acelerómetro está activo; si no, sumados de motion_minutes.csv. */
    fun stepsToday(ctx: Context): Int {
        val zone = java.time.ZoneId.systemDefault()
        val day = java.time.LocalDate.now(zone)
        val dir = ctx.getExternalFilesDir(null)
        val file = java.io.File(dir, MotionTracker.FILE_NAME)
        // 30/10: con historial de la pulsera de hoy, sus pasos (cuentan aunque el móvil esté lejos) + PulseApp después de su última muestra
        val band = BandSteps.read(dir)
        val dayStart = day.atStartOfDay(zone).toInstant().toEpochMilli()
        if (BandSteps.hasData(band, dayStart, dayStart + 86_400_000L))
            return BandSteps.merged(band, MotionTracker.readMinutes(file), dayStart, System.currentTimeMillis() + 60_000L)
        val live = MotionTrackerHolder.stepsToday()
        if (live > 0) return live
        return MotionTracker.readMinutes(file)
            .filter { java.time.Instant.ofEpochSecond(it.minuteStartUnix).atZone(zone).toLocalDate() == day }
            .sumOf { it.steps }
    }

    /** Inicio del día de hoy en milisegundos. */
    fun todayStartMillis(): Long = java.util.Calendar.getInstance().apply {
        set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
        set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
    }.timeInMillis

    /** Letra del día de la semana (L M X J V S D) para una fecha "yyyy-MM-dd". */
    fun weekdayLetter(isoDate: String): String = try {
        val d = java.time.LocalDate.parse(isoDate)
        arrayOf("L", "M", "X", "J", "V", "S", "D")[d.dayOfWeek.value - 1]
    } catch (e: Exception) { "?" }
}
