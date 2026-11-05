package com.pulseapp.android

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.content.res.ResourcesCompat

/** Piezas de pantalla del entrenador de fuerza (5/11), hechas por código con el aspecto de WHOOP. */
object SUi {
    class Screen(val root: FrameLayout, val top: LinearLayout, val scroll: ScrollView, val content: LinearLayout, val bottom: LinearLayout)

    fun dp(ctx: Context, v: Float) = Ui.dp(ctx, v)
    fun col(ctx: Context, res: Int) = Ui.color(ctx, res)
    fun mp(h: Int = ViewGroup.LayoutParams.WRAP_CONTENT) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, h)

    /** Pantalla: cabecera fija, contenido con scroll y barra inferior fija (botones). */
    fun screen(a: Activity): Screen {
        val ctx: Context = a
        a.window.statusBarColor = col(ctx, R.color.w_bg_top)
        val root = FrameLayout(ctx).apply { setBackgroundResource(R.drawable.bg_screen_whoop) }
        val col = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
        val top = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(ctx, 16f), dp(ctx, 10f), dp(ctx, 16f), 0) }
        val content = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(ctx, 16f), dp(ctx, 4f), dp(ctx, 16f), dp(ctx, 40f)) }
        val scroll = ScrollView(ctx).apply { isFillViewport = true; clipToPadding = false; addView(content) }
        val bottom = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER; setPadding(dp(ctx, 16f), dp(ctx, 8f), dp(ctx, 16f), dp(ctx, 18f)) }
        col.addView(top, mp())
        col.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        col.addView(bottom, mp())
        root.addView(col, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        a.setContentView(root)
        return Screen(root, top, scroll, content, bottom)
    }

    fun iconButton(ctx: Context, res: Int, onClick: () -> Unit): ImageView = ImageView(ctx).apply {
        setImageResource(res)
        setColorFilter(col(ctx, R.color.text_primary))
        setPadding(dp(ctx, 8f), dp(ctx, 8f), dp(ctx, 8f), dp(ctx, 8f))
        layoutParams = LinearLayout.LayoutParams(dp(ctx, 40f), dp(ctx, 40f))
        isClickable = true
        setOnClickListener { onClick() }
    }

    /** Cabecera: botón izquierdo, título (y subtítulo) centrado, botón derecho. */
    fun header(ctx: Context, leftRes: Int?, onLeft: () -> Unit, title: String, subtitle: String? = null,
               rightRes: Int? = null, onRight: (() -> Unit)? = null): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(ctx, 48f)
        if (leftRes != null) addView(iconButton(ctx, leftRes, onLeft)) else addView(View(ctx), LinearLayout.LayoutParams(dp(ctx, 40f), 1))
        addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            layoutParams = W.weight()
            addView(W.title(ctx, title, 15.5f).apply { gravity = Gravity.CENTER; tag = "title" })
            if (subtitle != null) addView(W.number(ctx, subtitle, 14f, R.color.text_secondary).apply {
                gravity = Gravity.CENTER; tag = "subtitle"; setPadding(0, dp(ctx, 3f), 0, 0)
            })
        })
        if (rightRes != null && onRight != null) addView(iconButton(ctx, rightRes, onRight))
        else addView(View(ctx), LinearLayout.LayoutParams(dp(ctx, 40f), 1))
    }

    /** Pestañas con subrayado (PROGRESO / MIS ENTRENAMIENTOS…). */
    fun tabs(ctx: Context, labels: List<String>, selected: Int, onSelect: (Int) -> Unit): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        layoutParams = mp().apply { topMargin = dp(ctx, 10f) }
        labels.forEachIndexed { i, l ->
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                layoutParams = W.weight()
                setPadding(0, dp(ctx, 8f), 0, 0)
                addView(W.title(ctx, l, 13f, if (i == selected) R.color.text_primary else R.color.text_secondary).apply { gravity = Gravity.CENTER })
                addView(View(ctx).apply {
                    setBackgroundColor(if (i == selected) Color.WHITE else Color.TRANSPARENT)
                    layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(ctx, 2f)).apply {
                        topMargin = dp(ctx, 10f); marginStart = dp(ctx, 10f); marginEnd = dp(ctx, 10f)
                    }
                })
                isClickable = true
                setOnClickListener { onSelect(i) }
            })
        }
    }

    /** Selector de dos opciones en píldora (EJERCICIOS / ZONAS DE FC). */
    fun segmented(ctx: Context, labels: List<String>, selected: Int, onSelect: (Int) -> Unit): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        background = rounded(ctx, Color.parseColor("#1A2025"), 12f)
        setPadding(dp(ctx, 4f), dp(ctx, 4f), dp(ctx, 4f), dp(ctx, 4f))
        layoutParams = mp().apply { topMargin = dp(ctx, 20f) }
        labels.forEachIndexed { i, l ->
            addView(W.title(ctx, l, 13f, if (i == selected) R.color.text_primary else R.color.text_secondary).apply {
                gravity = Gravity.CENTER
                setPadding(0, dp(ctx, 14f), 0, dp(ctx, 14f))
                layoutParams = W.weight()
                if (i == selected) background = rounded(ctx, Color.parseColor("#2C3338"), 10f)
                isClickable = true
                setOnClickListener { onSelect(i) }
            })
        }
    }

    fun rounded(ctx: Context, color: Int, radiusDp: Float, strokeColor: Int? = null, dashed: Boolean = false): GradientDrawable =
        GradientDrawable().apply {
            setColor(color)
            cornerRadius = dp(ctx, radiusDp).toFloat()
            if (strokeColor != null) {
                if (dashed) setStroke(dp(ctx, 1.4f), strokeColor, dp(ctx, 5f).toFloat(), dp(ctx, 4f).toFloat())
                else setStroke(dp(ctx, 1.2f), strokeColor)
            }
        }

    /** Botón grande en píldora: blanco (principal) o con borde. */
    fun button(ctx: Context, text: String, primary: Boolean = true, enabled: Boolean = true, accent: Int? = null, onClick: () -> Unit): TextView =
        W.title(ctx, text, 14.5f, if (primary) R.color.background else R.color.text_primary).apply {
            gravity = Gravity.CENTER
            setPadding(dp(ctx, 16f), dp(ctx, 17f), dp(ctx, 16f), dp(ctx, 17f))
            background = when {
                accent != null -> rounded(ctx, Color.TRANSPARENT, 30f, accent)
                primary -> rounded(ctx, Color.WHITE, 30f)
                else -> rounded(ctx, Color.TRANSPARENT, 30f, Color.parseColor("#55FFFFFF"))
            }
            if (accent != null) setTextColor(accent)
            alpha = if (enabled) 1f else 0.35f
            isClickable = enabled
            if (enabled) setOnClickListener { onClick() }
        }

    /** Recuadro discontinuo verde con "+" (AGREGAR EJERCICIO) o gris (Agregar ejercicio personalizado). */
    fun dashedAdd(ctx: Context, text: String, green: Boolean, onClick: () -> Unit): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        val accent = if (green) Color.parseColor("#2BD4A0") else Color.parseColor("#66FFFFFF")
        background = rounded(ctx, if (green) Color.parseColor("#1A2BD4A0") else Color.TRANSPARENT, 12f, accent, dashed = true)
        setPadding(dp(ctx, 10f), dp(ctx, 10f), dp(ctx, 16f), dp(ctx, 10f))
        layoutParams = mp().apply { topMargin = dp(ctx, 14f) }
        addView(FrameLayout(ctx).apply {
            background = rounded(ctx, Color.parseColor("#22FFFFFF"), 8f)
            layoutParams = LinearLayout.LayoutParams(dp(ctx, 64f), dp(ctx, 50f))
            addView(ImageView(ctx).apply {
                setImageResource(R.drawable.ic_plus); setColorFilter(Color.WHITE)
                layoutParams = FrameLayout.LayoutParams(dp(ctx, 22f), dp(ctx, 22f), Gravity.CENTER)
            })
        })
        addView(if (green) W.title(ctx, text, 15f) else W.body(ctx, text, 15.5f, R.color.text_primary), W.weight().apply { marginStart = dp(ctx, 16f) })
        isClickable = true
        setOnClickListener { onClick() }
    }

    /** Miniatura de un ejercicio: cuadrado con el icono del grupo muscular (sin fotos de WHOOP). */
    fun thumb(ctx: Context, group: String?, sizeDp: Float = 56f): FrameLayout = FrameLayout(ctx).apply {
        val c = groupColor(group)
        background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(adjust(c, 0.55f), adjust(c, 0.22f))).apply {
            cornerRadius = dp(ctx, 8f).toFloat()
        }
        layoutParams = LinearLayout.LayoutParams(dp(ctx, sizeDp * 1.15f), dp(ctx, sizeDp))
        addView(ImageView(ctx).apply {
            setImageResource(groupIcon(group)); setColorFilter(Color.WHITE); alpha = 0.92f
            layoutParams = FrameLayout.LayoutParams(dp(ctx, sizeDp * 0.5f), dp(ctx, sizeDp * 0.5f), Gravity.CENTER)
        })
    }

    fun groupIcon(group: String?): Int = when (group) {
        "Piernas", "Glúteos" -> R.drawable.ic_run
        "Core" -> R.drawable.ic_person_still
        "Cardio" -> R.drawable.ic_heart
        "Cuerpo completo" -> R.drawable.ic_bolt
        else -> R.drawable.ic_dumbbell
    }

    fun groupColor(group: String?): Int = when (group) {
        "Pecho" -> Color.parseColor("#1F7A8C")
        "Espalda" -> Color.parseColor("#2E6F9E")
        "Hombros" -> Color.parseColor("#3F6E8F")
        "Bíceps", "Tríceps" -> Color.parseColor("#2A7F7A")
        "Piernas", "Glúteos" -> Color.parseColor("#2F7F5F")
        "Core" -> Color.parseColor("#55708A")
        else -> Color.parseColor("#3A5F73")
    }

    private fun adjust(c: Int, f: Float) = Color.rgb((Color.red(c) * f).toInt(), (Color.green(c) * f).toInt(), (Color.blue(c) * f).toInt())

    /** Campo numérico pequeño (repeticiones / kg) sin línea, centrado. */
    fun numberField(ctx: Context, value: String, decimal: Boolean, onChange: (String) -> Unit): EditText = EditText(ctx).apply {
        setText(value)
        textSize = 18f
        typeface = ResourcesCompat.getFont(ctx, R.font.barlow_condensed_bold)
        setTextColor(col(ctx, R.color.text_primary))
        gravity = Gravity.CENTER
        inputType = if (decimal) InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL else InputType.TYPE_CLASS_NUMBER
        background = rounded(ctx, Color.parseColor("#22FFFFFF"), 8f)
        setPadding(dp(ctx, 4f), dp(ctx, 8f), dp(ctx, 4f), dp(ctx, 8f))
        isSingleLine = true
        setSelectAllOnFocus(true)
        addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: android.text.Editable?) { onChange(s?.toString() ?: "") }
        })
    }

    /** Campo de texto normal (buscar, nombre…). */
    fun textField(ctx: Context, hint: String, multiLine: Boolean = false): EditText = EditText(ctx).apply {
        this.hint = hint
        setHintTextColor(col(ctx, R.color.text_secondary))
        setTextColor(col(ctx, R.color.text_primary))
        textSize = 16f
        typeface = ResourcesCompat.getFont(ctx, R.font.archivo)
        background = rounded(ctx, Color.parseColor("#1F262B"), 12f)
        setPadding(dp(ctx, 16f), dp(ctx, 14f), dp(ctx, 16f), dp(ctx, 14f))
        if (multiLine) {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            minLines = 6; gravity = Gravity.TOP or Gravity.START
        } else {
            isSingleLine = true
        }
    }

    fun kg(v: Double): String = if (v == Math.floor(v)) "%.0f".format(v) else Ui.comma(v, 1)

    fun dateUpper(ms: Long): String {
        val d = java.time.Instant.ofEpochMilli(ms).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
        val m = arrayOf("ENE", "FEB", "MAR", "ABR", "MAY", "JUN", "JUL", "AGO", "SEP", "OCT", "NOV", "DIC")
        return "${d.dayOfMonth} ${m[d.monthValue - 1]} ${d.year}"
    }

    fun dateLower(ms: Long): String = dateUpper(ms).lowercase(java.util.Locale("es", "ES"))

    fun hms(sec: Long): String = "%02d:%02d:%02d".format(sec / 3600, (sec % 3600) / 60, sec % 60)
    fun ms(sec: Long): String = "%d:%02d".format(sec / 60, sec % 60)

    /** Medalla de récord personal (círculo dorado con estrella). */
    fun medal(ctx: Context): ImageView = ImageView(ctx).apply {
        setImageResource(R.drawable.ic_medal)
        layoutParams = LinearLayout.LayoutParams(dp(ctx, 20f), dp(ctx, 20f))
    }
}
