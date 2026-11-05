package com.pulseapp.android

import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

/** Seleccionar ejercicios (5/11, como WHOOP): buscar, filtrar por grupo, personalizado, varios a la vez o en superserie. */
class ExercisePickerActivity : AppCompatActivity() {
    companion object {
        const val RESULT_IDS = "ids"
        const val RESULT_SUPERSET = "superset"
    }

    private lateinit var screen: SUi.Screen
    private val selected = LinkedHashSet<String>()
    private var query = ""
    private var group: String? = null
    private lateinit var list: LinearLayout
    private val esLocale = java.util.Locale("es", "ES")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Formulas.init(this)
        screen = SUi.screen(this)
        val ctx = this
        screen.top.addView(SUi.header(ctx, R.drawable.ic_chevron_left, { finish() }, "Seleccionar ejercicios"))
        screen.top.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 12f); bottomMargin = SUi.dp(ctx, 4f) }
            val search: EditText = SUi.textField(ctx, "Buscar un ejercicio…").apply {
                setCompoundDrawablesRelativeWithIntrinsicBounds(R.drawable.ic_search, 0, 0, 0)
                compoundDrawablePadding = SUi.dp(ctx, 10f)
                addTextChangedListener(object : android.text.TextWatcher {
                    override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                    override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                    override fun afterTextChanged(s: android.text.Editable?) { query = s?.toString() ?: ""; renderList() }
                })
            }
            addView(search, W.weight())
            addView(FrameLayout(ctx).apply {
                background = SUi.rounded(ctx, Color.parseColor("#1F262B"), 12f)
                layoutParams = LinearLayout.LayoutParams(SUi.dp(ctx, 52f), SUi.dp(ctx, 50f)).apply { marginStart = SUi.dp(ctx, 10f) }
                addView(ImageView(ctx).apply {
                    setImageResource(R.drawable.ic_filter); setColorFilter(Color.WHITE)
                    layoutParams = FrameLayout.LayoutParams(SUi.dp(ctx, 22f), SUi.dp(ctx, 22f), Gravity.CENTER)
                })
                isClickable = true
                setOnClickListener { chooseGroup() }
            })
        })
        screen.content.addView(SUi.dashedAdd(ctx, "Agregar ejercicio personalizado", false) { addCustom() })
        list = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
        screen.content.addView(list)
        renderList()
        renderBottom()
    }

    private fun chooseGroup() {
        val items = arrayOf("Todos") + Strength.GROUPS.toTypedArray()
        AlertDialog.Builder(this).setTitle("Grupo muscular").setItems(items) { _, i ->
            group = if (i == 0) null else items[i]; renderList()
        }.show()
    }

    private fun renderList() {
        val ctx = this
        list.removeAllViews()
        val q = Strength.norm(query.trim())
        val words = q.split(' ').filter { it.isNotBlank() }
        val items = Strength.library().filter { e ->
            (group == null || e.group == group) && words.all { Strength.norm(e.name).contains(it) }
        }
        group?.let { g ->
            list.addView(W.title(ctx, "Filtro: $g  ✕", 13f, R.color.w_mint).apply {
                setPadding(0, SUi.dp(ctx, 14f), 0, 0); isClickable = true; setOnClickListener { group = null; renderList() }
            })
        }
        var letter = ""
        for (e in items) {
            val l = Strength.norm(e.name).take(1).uppercase(esLocale)
            if (l != letter) {
                letter = l
                list.addView(W.title(ctx, l, 14f, R.color.text_secondary).apply { setPadding(SUi.dp(ctx, 4f), SUi.dp(ctx, 18f), 0, SUi.dp(ctx, 2f)) })
            }
            list.addView(row(e))
        }
        if (items.isEmpty()) list.addView(W.body(ctx, "Ningún ejercicio con ese nombre. Puedes crearlo con \"Agregar ejercicio personalizado\".", 14.5f).apply {
            setPadding(0, SUi.dp(ctx, 18f), 0, 0)
        })
    }

    private fun row(e: Strength.Exercise): LinearLayout {
        val ctx = this
        val on = e.id in selected
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            background = SUi.rounded(ctx, Ui.color(ctx, R.color.w_card), 12f, if (on) Color.parseColor("#2BD4A0") else null)
            setPadding(SUi.dp(ctx, 4f), SUi.dp(ctx, 4f), SUi.dp(ctx, 8f), SUi.dp(ctx, 4f))
            layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 8f) }
            addView(SUi.thumb(ctx, e.group, 52f))
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                addView(W.body(ctx, e.name, 15.5f, R.color.text_primary))
                addView(W.body(ctx, "${e.group} · ${e.equipment}", 12.5f))
            }, W.weight().apply { marginStart = SUi.dp(ctx, 14f) })
            if (on) addView(W.icon(ctx, R.drawable.ic_check, 22f, R.color.w_mint).apply {
                (layoutParams as LinearLayout.LayoutParams).marginEnd = SUi.dp(ctx, 6f)
            })
            addView(SUi.iconButton(ctx, R.drawable.ic_info) { info(e) }.apply { alpha = 0.7f })
            isClickable = true
            setOnClickListener {
                if (!selected.add(e.id)) selected.remove(e.id)
                renderList(); renderBottom()
            }
        }
    }

    private fun info(e: Strength.Exercise) {
        val hist = Strength.logs().flatMap { w -> w.exercises.filter { it.exId == e.id }.map { w to it } }
        val sb = StringBuilder("${e.group} · ${e.equipment}")
        if (e.bodyweight > 0) sb.append("\nCuenta el ${Math.round(e.bodyweight * 100)} % de tu peso corporal.")
        if (hist.isEmpty()) sb.append("\n\nAún no lo has registrado.")
        else {
            val best = hist.flatMap { it.second.sets }.maxByOrNull { Strength.setScore(it) }!!
            val last = hist.maxByOrNull { it.first.startMs }!!
            sb.append("\n\nVeces registrado: ${hist.size}")
            sb.append("\nMejor serie: ${best.reps} × ${SUi.kg(best.kg)} kg")
            sb.append("\nÚltima vez: ${SUi.dateLower(last.first.startMs)} — " + last.second.sets.joinToString(", ") { "${it.reps}×${SUi.kg(it.kg)}" })
        }
        AlertDialog.Builder(this).setTitle(e.name).setMessage(sb.toString()).setPositiveButton("OK", null).show()
    }

    private fun addCustom() {
        val ctx = this
        val box = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; setPadding(SUi.dp(ctx, 20f), SUi.dp(ctx, 10f), SUi.dp(ctx, 20f), 0) }
        val name = EditText(ctx).apply { hint = "Nombre del ejercicio"; setText(query) }
        box.addView(name)
        var g = Strength.GROUPS.first(); var eq = Strength.EQUIPMENT.first()
        val gText = TextView(ctx).apply { text = "Grupo: $g"; textSize = 16f; setPadding(0, SUi.dp(ctx, 14f), 0, SUi.dp(ctx, 6f)) }
        val eText = TextView(ctx).apply { text = "Material: $eq"; textSize = 16f; setPadding(0, SUi.dp(ctx, 8f), 0, SUi.dp(ctx, 6f)) }
        gText.setOnClickListener { AlertDialog.Builder(ctx).setItems(Strength.GROUPS.toTypedArray()) { _, i -> g = Strength.GROUPS[i]; gText.text = "Grupo: $g" }.show() }
        eText.setOnClickListener { AlertDialog.Builder(ctx).setItems(Strength.EQUIPMENT.toTypedArray()) { _, i -> eq = Strength.EQUIPMENT[i]; eText.text = "Material: $eq" }.show() }
        box.addView(gText); box.addView(eText)
        AlertDialog.Builder(ctx).setTitle("Ejercicio personalizado").setView(box)
            .setPositiveButton("Crear") { _, _ ->
                val n = name.text.toString().trim()
                if (n.isEmpty()) return@setPositiveButton
                // Con tu peso corporal: si es de peso corporal se cuenta el 60 %, como un ejercicio típico
                val ex = Strength.addCustomExercise(n, g, eq, if (eq == "Peso corporal") 0.6 else 0.0)
                selected.add(ex.id); renderList(); renderBottom()
            }
            .setNegativeButton("Cancelar", null).show()
    }

    private fun renderBottom() {
        val ctx = this
        val b = screen.bottom
        b.removeAllViews()
        val n = selected.size
        b.addView(SUi.button(ctx, "Súper conjunto", primary = false, enabled = n >= 2) { done(true) },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = SUi.dp(ctx, 10f) })
        b.addView(SUi.button(ctx, if (n > 0) "Añadir ($n)" else "Añadir", enabled = n > 0) { done(false) },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    }

    private fun done(superset: Boolean) {
        setResult(RESULT_OK, Intent().putExtra(RESULT_IDS, selected.toTypedArray()).putExtra(RESULT_SUPERSET, superset))
        finish()
    }
}
