package com.pulseapp.android

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** "Resumen del ejercicio" (5/11, como WHOOP): volumen y repeticiones, y cada ejercicio con sus series, peso, FC media y récords. */
class StrengthSummaryActivity : AppCompatActivity() {
    companion object { const val EXTRA_SESSION_ID = "session_id" }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Formulas.init(this)
        val id = intent.getLongExtra(EXTRA_SESSION_ID, -1L)
        val w = Strength.logFor(id) ?: run { finish(); return }
        val screen = SUi.screen(this)
        screen.top.addView(SUi.header(this, R.drawable.ic_chevron_left, { finish() }, "Resumen del ejercicio", null, R.drawable.ic_pencil) {
            startActivity(Intent(this, StrengthSessionActivity::class.java)
                .putExtra(StrengthSessionActivity.EXTRA_MODE, StrengthSessionActivity.MODE_LOG)
                .putExtra(StrengthSessionActivity.EXTRA_SESSION_ID, id))
            finish()
        })
        lifecycleScope.launch {
            val hr = withContext(Dispatchers.IO) { setHeartRates(File(getExternalFilesDir(null), "hr_log.csv"), w) }
            val rec = withContext(Dispatchers.IO) { Strength.records(w) }
            fill(this@StrengthSummaryActivity, screen.content, w, hr, rec)
        }
    }

    private fun fill(ctx: Context, c: LinearLayout, w: Strength.Workout, hr: Map<Pair<Int, Int>, Int?>, rec: List<List<Boolean>>) {
        c.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 18f) }
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.HORIZONTAL; gravity = Gravity.BOTTOM
                    addView(W.number(ctx, SUi.kg(w.volume), 40f, R.color.strain_blue))
                    addView(W.number(ctx, " kg", 18f, R.color.strain_blue).apply { setPadding(0, 0, 0, SUi.dp(ctx, 4f)) })
                })
                addView(W.title(ctx, "Volumen de carga", 13f, R.color.text_secondary).apply { setPadding(0, SUi.dp(ctx, 4f), 0, 0) })
            })
            addView(View(ctx).apply { setBackgroundColor(Color.parseColor("#33FFFFFF")) },
                LinearLayout.LayoutParams(SUi.dp(ctx, 1f), SUi.dp(ctx, 50f)).apply { marginStart = SUi.dp(ctx, 22f); marginEnd = SUi.dp(ctx, 22f) })
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                addView(W.number(ctx, "${w.reps}", 40f))
                addView(W.title(ctx, "Reps.", 13f, R.color.text_secondary).apply { setPadding(0, SUi.dp(ctx, 4f), 0, 0) })
            })
        })
        var i = 0
        while (i < w.exercises.size) {
            val g = w.exercises[i].superset
            var j = i + 1
            if (g != 0) while (j < w.exercises.size && w.exercises[j].superset == g) j++
            if (j - i > 1) {
                val box = LinearLayout(ctx).apply {
                    orientation = LinearLayout.VERTICAL
                    background = SUi.rounded(ctx, Color.TRANSPARENT, 16f, Color.parseColor("#77FFFFFF"), dashed = true)
                    setPadding(SUi.dp(ctx, 8f), SUi.dp(ctx, 12f), SUi.dp(ctx, 8f), SUi.dp(ctx, 8f))
                    layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 16f) }
                    addView(LinearLayout(ctx).apply {
                        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                        setPadding(SUi.dp(ctx, 6f), 0, 0, SUi.dp(ctx, 4f))
                        addView(W.icon(ctx, R.drawable.ic_superset, 22f, R.color.text_secondary))
                        addView(W.title(ctx, "Superset", 13.5f, R.color.text_secondary).apply { setPadding(SUi.dp(ctx, 10f), 0, 0, 0) })
                    })
                }
                for (k in i until j) box.addView(exerciseTable(ctx, w, k, hr, rec))
                c.addView(box)
            } else c.addView(exerciseTable(ctx, w, i, hr, rec))
            i = j
        }
        c.addView(W.body(ctx, "FC prom. = pulso medio de la serie entre \"Comenzar\" y \"Finalizar serie\" (\"--\" si no se cronometró). " +
            "Medalla = récord personal en ese ejercicio (más 1RM estimado que cualquier serie anterior).", 13f).apply {
            setPadding(0, SUi.dp(ctx, 18f), 0, 0)
        })
    }
}

/** Tarjeta de un ejercicio con su tabla REPS / PESO / FC PROM. y el total (la usan el resumen y el detalle). */
fun exerciseTable(ctx: Context, w: Strength.Workout, k: Int, hr: Map<Pair<Int, Int>, Int?>, rec: List<List<Boolean>>): LinearLayout {
    val e = w.exercises[k]
    return LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundResource(R.drawable.bg_card_w)
        layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 12f) }
        addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            background = SUi.rounded(ctx, Color.parseColor("#262D32"), 14f)
            setPadding(SUi.dp(ctx, 4f), SUi.dp(ctx, 4f), SUi.dp(ctx, 12f), SUi.dp(ctx, 4f))
            addView(SUi.thumb(ctx, Strength.exercise(e.exId)?.group, 50f))
            addView(W.body(ctx, e.name, 15.5f, R.color.text_primary), W.weight().apply { marginStart = SUi.dp(ctx, 14f) })
        })
        val body = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; setPadding(SUi.dp(ctx, 20f), SUi.dp(ctx, 14f), SUi.dp(ctx, 16f), SUi.dp(ctx, 18f)) }
        fun row(a: View, b: View, c: View, d: View?) = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 10f) }
            addView(a, W.weight(1f)); addView(b, W.weight(1.3f)); addView(c, W.weight(1.3f))
            addView(d ?: View(ctx), LinearLayout.LayoutParams(SUi.dp(ctx, 24f), SUi.dp(ctx, 20f)))
        }
        body.addView(row(W.title(ctx, "Reps.", 12.5f, R.color.text_secondary), W.title(ctx, "Peso", 12.5f, R.color.text_secondary),
            W.title(ctx, "FC prom.", 12.5f, R.color.text_secondary), null))
        e.sets.forEachIndexed { si, s ->
            fun unit(v: String, u: String) = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.BOTTOM
                addView(W.number(ctx, v, 19f)); addView(W.body(ctx, " $u", 14f, R.color.text_secondary))
            }
            val h = hr[k to si]
            body.addView(row(W.number(ctx, "${s.reps}", 19f), unit(SUi.kg(s.kg), "kg"), unit(h?.toString() ?: "--", "lpm"),
                if (rec.getOrNull(k)?.getOrNull(si) == true) SUi.medal(ctx) else null))
        }
        body.addView(View(ctx).apply { setBackgroundColor(Color.parseColor("#22FFFFFF")) }, SUi.mp(SUi.dp(ctx, 1f)).apply { topMargin = SUi.dp(ctx, 16f) })
        body.addView(row(W.title(ctx, "Total", 12.5f, R.color.text_secondary), View(ctx), View(ctx), null).apply { (layoutParams as LinearLayout.LayoutParams).topMargin = SUi.dp(ctx, 14f) })
        body.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.BOTTOM
            layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 6f) }
            addView(W.number(ctx, "${e.reps}", 22f), W.weight(1f))
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.BOTTOM
                addView(W.number(ctx, SUi.kg(e.volume), 22f, R.color.strain_blue)); addView(W.body(ctx, " kg", 14f, R.color.text_secondary))
            }, W.weight(2.6f))
            addView(View(ctx), LinearLayout.LayoutParams(SUi.dp(ctx, 24f), 1))
        })
        addView(body)
    }
}
