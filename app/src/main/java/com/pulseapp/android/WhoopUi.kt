package com.pulseapp.android

import android.content.Context
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.res.ResourcesCompat

/** Piezas de interfaz con el aspecto de WHOOP (17/10) que se crean por código en Inicio, Salud, Estrés y actividades. */
object W {

    private fun dp(ctx: Context, v: Float) = Ui.dp(ctx, v)
    private fun c(ctx: Context, res: Int) = Ui.color(ctx, res)

    /** Color del anillo y de la gráfica de recuperación (verde WHOOP / ámbar / rojo). */
    fun recoveryColor(score: Int): Int = when {
        score >= 67 -> R.color.w_recovery_high
        score >= 34 -> R.color.alert_amber
        else -> R.color.alert_red
    }

    fun stressColor(level: String): Int = when (level) {
        "ALTO" -> R.color.alert_amber
        "MEDIO" -> R.color.w_mint
        else -> R.color.w_low_blue
    }

    /** Icono según el deporte. */
    fun sportIcon(type: String): Int {
        val t = type.lowercase()
        return when {
            "fútbol" in t || "futbol" in t -> R.drawable.ic_ball
            "pádel" in t || "padel" in t || "pickle" in t || "tenis" in t -> R.drawable.ic_racket
            "fuerza" in t -> R.drawable.ic_dumbbell
            else -> R.drawable.ic_run
        }
    }

    fun title(ctx: Context, text: String, sizeSp: Float = 14.5f, colorRes: Int = R.color.text_primary): TextView =
        TextView(ctx).apply {
            this.text = text.uppercase(java.util.Locale("es", "ES"))
            textSize = sizeSp
            letterSpacing = 0.14f
            typeface = ResourcesCompat.getFont(ctx, R.font.barlow_condensed_bold)
            setTextColor(c(ctx, colorRes))
            includeFontPadding = false
        }

    fun body(ctx: Context, text: String, sizeSp: Float = 15f, colorRes: Int = R.color.text_secondary): TextView =
        TextView(ctx).apply {
            this.text = text
            textSize = sizeSp
            typeface = ResourcesCompat.getFont(ctx, R.font.archivo)
            setTextColor(c(ctx, colorRes))
            setLineSpacing(dp(ctx, 3f).toFloat(), 1f)
        }

    fun number(ctx: Context, text: String, sizeSp: Float, colorRes: Int = R.color.text_primary): TextView =
        TextView(ctx).apply {
            this.text = text
            textSize = sizeSp
            typeface = ResourcesCompat.getFont(ctx, R.font.barlow_condensed_bold)
            setTextColor(c(ctx, colorRes))
            includeFontPadding = false
            fontFeatureSettings = "tnum"
        }

    fun icon(ctx: Context, res: Int, sizeDp: Float, tintRes: Int = R.color.text_primary): ImageView =
        ImageView(ctx).apply {
            setImageResource(res)
            setColorFilter(c(ctx, tintRes))
            layoutParams = LinearLayout.LayoutParams(dp(ctx, sizeDp), dp(ctx, sizeDp))
        }

    fun rounded(ctx: Context, colorRes: Int, radiusDp: Float): GradientDrawable = Ui.rounded(ctx, colorRes, radiusDp)

    fun card(ctx: Context, topMarginDp: Float = 12f): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundResource(R.drawable.bg_card_w)
        val p = dp(ctx, 16f)
        setPadding(p, p, p, p)
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(ctx, topMarginDp)
        }
    }

    fun wrap(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
    fun weight(w: Float = 1f): LinearLayout.LayoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, w)

    /** Píldora con flecha de tendencia (▲ ▼ ●) y texto, fondo gris: "▲ 7,4". */
    fun trendChip(ctx: Context, trend: Trend?, text: String, arrowColorRes: Int = R.color.text_primary): LinearLayout =
        LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rounded(ctx, R.color.w_chip, 6f)
            setPadding(dp(ctx, 8f), dp(ctx, 4f), dp(ctx, 8f), dp(ctx, 4f))
            if (trend != null) {
                addView(icon(ctx, when (trend) {
                    Trend.UP -> R.drawable.ic_triangle_up
                    Trend.DOWN -> R.drawable.ic_triangle_down
                    Trend.SAME -> R.drawable.ic_dot
                }, 11f, arrowColorRes).apply { (layoutParams as LinearLayout.LayoutParams).marginEnd = dp(ctx, 6f) })
            }
            addView(number(ctx, text, 15f, R.color.text_primary).apply { alpha = 0.92f })
        }

    /** Fila de "Mi panel de control": icono, nombre, valor con tendencia y tu media debajo. */
    fun panelRow(ctx: Context, row: PanelRow): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setBackgroundResource(R.drawable.bg_card_w)
        minimumHeight = dp(ctx, 68f)
        setPadding(dp(ctx, 16f), dp(ctx, 10f), dp(ctx, 16f), dp(ctx, 10f))
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            bottomMargin = dp(ctx, 12f)
        }
        addView(icon(ctx, row.iconRes, 24f, R.color.text_primary).apply { alpha = 0.85f })
        addView(title(ctx, row.label, 14.5f).apply {
            layoutParams = weight().apply { marginStart = dp(ctx, 14f); marginEnd = dp(ctx, 8f) }
            setLineSpacing(dp(ctx, 4f).toFloat(), 1f)
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
        })
        val right = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.END
        }
        val top = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        top.addView(number(ctx, row.value, 27f))
        val trendColor = when (row.good) {
            true -> R.color.w_mint
            false -> R.color.w_trend_amber
            null -> R.color.text_secondary
        }
        val trendIcon = when (row.trend) {
            Trend.UP -> R.drawable.ic_triangle_up
            Trend.DOWN -> R.drawable.ic_triangle_down
            Trend.SAME -> R.drawable.ic_dot
            null -> 0
        }
        top.addView(View(ctx).apply { layoutParams = LinearLayout.LayoutParams(dp(ctx, 8f), 1) })
        if (trendIcon != 0) top.addView(icon(ctx, trendIcon, 13f, trendColor))
        else top.addView(View(ctx).apply { layoutParams = LinearLayout.LayoutParams(dp(ctx, 13f), 1) })
        right.addView(top)
        right.addView(number(ctx, row.average ?: "", 15.5f, R.color.text_secondary).apply {
            setPadding(0, dp(ctx, 3f), dp(ctx, 21f), 0)
            fontFeatureSettings = "tnum"
        })
        addView(right)
    }

    /** Fila de "Actividades de hoy": píldora de color con icono y valor, nombre, horas y barra. */
    fun activityRow(ctx: Context, pillColorRes: Int, iconRes: Int, value: String, name: String, start: String, end: String): LinearLayout =
        LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundResource(R.drawable.bg_row_w)
            isClickable = true
            val p = dp(ctx, 8f)
            setPadding(p, p, dp(ctx, 12f), p)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(ctx, 66f)).apply { bottomMargin = dp(ctx, 10f) }
            val pill = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                background = rounded(ctx, pillColorRes, 10f)
                layoutParams = LinearLayout.LayoutParams(dp(ctx, 112f), LinearLayout.LayoutParams.MATCH_PARENT)
                addView(icon(ctx, iconRes, 22f, R.color.text_primary))
                addView(number(ctx, value, 23f).apply { setPadding(dp(ctx, 10f), 0, 0, 0) })
            }
            addView(pill)
            addView(title(ctx, name, 16f).apply {
                layoutParams = weight().apply { marginStart = dp(ctx, 18f) }
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            })
            val times = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.END
                addView(number(ctx, start, 15f, R.color.text_secondary))
                addView(number(ctx, end, 15f, R.color.text_secondary).apply { setPadding(0, dp(ctx, 8f), 0, 0) })
            }
            addView(times)
            addView(View(ctx).apply {
                background = rounded(ctx, pillColorRes, 2f)
                layoutParams = LinearLayout.LayoutParams(dp(ctx, 3f), dp(ctx, 36f)).apply { marginStart = dp(ctx, 12f) }
            })
        }
}
