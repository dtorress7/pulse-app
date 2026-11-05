package com.pulseapp.android

import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Entrenamiento de fuerza (5/11), como el de WHOOP:
 *  - LIVE: "Inicio rápido" o desde un entrenamiento guardado. Cronómetro, "Comenzar serie" / "Finalizar serie" (se guarda la hora
 *    de cada serie para sacar su pulso) y al terminar se crea la actividad "Entrenamiento de fuerza" con sus series.
 *  - TEMPLATE: crear / editar un entrenamiento de "Mis entrenamientos" (sin cronómetro).
 *  - LOG: añadir o corregir las series de una actividad ya guardada (como añadir el entrenador de fuerza a una actividad en WHOOP).
 */
class StrengthSessionActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_MODE = "mode"
        const val EXTRA_SESSION_ID = "session_id"
        const val EXTRA_TEMPLATE_ID = "template_id"
        const val MODE_LIVE = "live"
        const val MODE_TEMPLATE = "template"
        const val MODE_LOG = "log"
        private const val REQ_PICK = 41

        /** Entrenamiento con el que empezar (plantilla, ejemplo o texto generado). */
        @Volatile var pending: Strength.Workout? = null

        fun startLive(ctx: Context, from: Strength.Workout?) {
            if (Strength.live() == null) {
                val w = Strength.Workout(0, System.currentTimeMillis(), 0, from?.name ?: "")
                from?.exercises?.forEach { e ->
                    val sets = e.sets.map { Strength.SetEntry(it.reps, it.kg) }.toMutableList()
                    w.exercises.add(Strength.ExerciseEntry(e.exId, e.name, e.superset, sets))
                }
                Strength.saveLive(w)
            }
            ctx.startActivity(Intent(ctx, StrengthSessionActivity::class.java).putExtra(EXTRA_MODE, MODE_LIVE))
        }
    }

    private lateinit var mode: String
    private lateinit var w: Strength.Workout
    private lateinit var screen: SUi.Screen
    private var tab = 1          // LIVE: 0 = sesión en vivo, 1 = ejercicios
    private var sessionId = -1L
    private var setHr: Map<Pair<Int, Int>, Int?> = emptyMap()
    private val handler = Handler(Looper.getMainLooper())
    private var subtitle: TextView? = null
    private var liveBox: LinearLayout? = null
    private val tick = object : Runnable {
        override fun run() { updateClock(); handler.postDelayed(this, 1000) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Formulas.init(this)
        mode = intent.getStringExtra(EXTRA_MODE) ?: MODE_LIVE
        sessionId = intent.getLongExtra(EXTRA_SESSION_ID, -1L)
        screen = SUi.screen(this)
        w = when (mode) {
            MODE_LIVE -> Strength.live() ?: run { finish(); return }
            MODE_TEMPLATE -> {
                val id = intent.getLongExtra(EXTRA_TEMPLATE_ID, -1L)
                pending?.copy()?.also { pending = null; if (it.id <= 0) it.id = System.currentTimeMillis() }
                    ?: Strength.templates().firstOrNull { it.id == id }?.copy()
                    ?: Strength.Workout(System.currentTimeMillis(), System.currentTimeMillis(), 0, "")
            }
            else -> Strength.logFor(sessionId)?.copy() ?: Strength.Workout(sessionId, 0, 0, "")
        }
        if (mode == MODE_LIVE && w.exercises.isNotEmpty()) tab = 0
        if (mode == MODE_LOG) lifecycleScope.launch {
            val s = com.pulseapp.android.data.AppDatabase.getInstance(this@StrengthSessionActivity).activitySessionDao().getById(sessionId)
            if (s == null) { finish(); return@launch }
            w.startMs = s.startMillis; w.endMs = s.endMillis
            loadSetHr()
            render()
        } else render()
    }

    override fun onResume() {
        super.onResume()
        if (mode == MODE_LIVE) handler.post(tick)
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(tick)
        persist()
    }

    private fun persist() {
        if (mode == MODE_LIVE && ::w.isInitialized) Strength.saveLive(w)
    }

    private suspend fun loadSetHr() {
        val file = File(getExternalFilesDir(null), "hr_log.csv")
        setHr = withContext(Dispatchers.IO) { setHeartRates(file, w) }
    }

    // ---------- Pantalla ----------
    private fun render() {
        val ctx = this
        screen.top.removeAllViews()
        val title = when (mode) {
            MODE_LIVE -> SUi.dateUpper(w.startMs)
            MODE_TEMPLATE -> if (w.name.isNotBlank()) w.name else "Nuevo entrenamiento"
            else -> "Ejercicios de la actividad"
        }
        val head = SUi.header(ctx, if (mode == MODE_LIVE) R.drawable.ic_more else R.drawable.ic_chevron_left, { onLeft() }, title,
            if (mode == MODE_LIVE) SUi.hms((System.currentTimeMillis() - w.startMs) / 1000) else null, R.drawable.ic_plus) { pick(false) }
        subtitle = head.findViewWithTag("subtitle")
        screen.top.addView(head)
        if (mode == MODE_LIVE) screen.top.addView(SUi.tabs(ctx, listOf("Sesión en vivo", "Ejercicios"), tab) { tab = it; render() })

        val c = screen.content
        c.removeAllViews()
        liveBox = null
        if (mode == MODE_LIVE && tab == 0) renderLive(c) else renderExercises(c)
        renderBottom()
    }

    private fun onLeft() {
        if (mode != MODE_LIVE) { if (mode == MODE_TEMPLATE) confirmLeaveTemplate() else finish(); return }
        val items = arrayOf("Finalizar entrenamiento", "Guardar como entrenamiento", "Descartar entrenamiento", "Minimizar (sigue en curso)")
        AlertDialog.Builder(this).setItems(items) { _, i ->
            when (i) {
                0 -> finishWorkout()
                1 -> saveAsTemplate(w)
                2 -> AlertDialog.Builder(this).setTitle("¿Descartar el entrenamiento?")
                    .setMessage("No se guardará la actividad ni las series. El pulso guardado no se toca.")
                    .setPositiveButton("Descartar") { _, _ -> Strength.saveLive(null); finish() }
                    .setNegativeButton("Cancelar", null).show()
                else -> finish()
            }
        }.show()
    }

    private fun confirmLeaveTemplate() {
        AlertDialog.Builder(this).setTitle("¿Salir sin guardar?").setPositiveButton("Salir") { _, _ -> finish() }
            .setNegativeButton("Cancelar", null).show()
    }

    private fun renderExercises(c: LinearLayout) {
        val ctx = this
        if (mode == MODE_TEMPLATE) {
            c.addView(SUi.textField(ctx, "Nombre del entrenamiento").apply {
                setText(w.name)
                layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 10f) }
                addTextChangedListener(object : android.text.TextWatcher {
                    override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                    override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                    override fun afterTextChanged(s: android.text.Editable?) { w.name = s?.toString() ?: "" }
                })
            })
        }
        if (mode == MODE_LOG) {
            c.addView(W.body(ctx, "Apunta las series que hiciste. Sin cronometrar cada serie no se puede sacar su pulso (sale \"--\"), " +
                "pero la carga muscular sí cuenta para el esfuerzo.", 14f).apply { setPadding(0, SUi.dp(ctx, 8f), 0, 0) })
        }
        if (w.exercises.isEmpty()) {
            c.addView(SUi.dashedAdd(ctx, "Agregar ejercicio", true) { pick(false) })
            return
        }
        var i = 0
        while (i < w.exercises.size) {
            val g = w.exercises[i].superset
            var j = i + 1
            if (g != 0) while (j < w.exercises.size && w.exercises[j].superset == g) j++
            if (j - i > 1) {
                val box = LinearLayout(ctx).apply {
                    orientation = LinearLayout.VERTICAL
                    background = SUi.rounded(ctx, Color.TRANSPARENT, 14f, Color.parseColor("#77FFFFFF"), dashed = true)
                    setPadding(SUi.dp(ctx, 8f), SUi.dp(ctx, 12f), SUi.dp(ctx, 8f), SUi.dp(ctx, 8f))
                    layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 14f) }
                    addView(LinearLayout(ctx).apply {
                        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                        setPadding(SUi.dp(ctx, 6f), 0, 0, SUi.dp(ctx, 4f))
                        addView(W.icon(ctx, R.drawable.ic_superset, 20f, R.color.text_secondary))
                        addView(W.title(ctx, "Superserie", 13.5f, R.color.text_secondary).apply { setPadding(SUi.dp(ctx, 10f), 0, 0, 0) })
                    })
                }
                for (k in i until j) box.addView(exerciseCard(k))
                c.addView(box)
            } else c.addView(exerciseCard(i))
            i = j
        }
        c.addView(SUi.dashedAdd(ctx, "Agregar ejercicio", true) { pick(false) })
    }

    private fun exerciseCard(k: Int): LinearLayout {
        val ctx = this
        val e = w.exercises[k]
        val ex = Strength.exercise(e.exId)
        val card = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundResource(R.drawable.bg_card_w)
            setPadding(SUi.dp(ctx, 12f), SUi.dp(ctx, 12f), SUi.dp(ctx, 12f), SUi.dp(ctx, 12f))
            layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 12f) }
        }
        card.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            addView(SUi.thumb(ctx, ex?.group, 46f))
            addView(W.body(ctx, e.name, 16f, R.color.text_primary), W.weight().apply { marginStart = SUi.dp(ctx, 14f) })
            addView(SUi.iconButton(ctx, R.drawable.ic_more) { exerciseMenu(k) })
        })
        // Cabecera de la tabla
        fun row(): LinearLayout = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 8f) }
        }
        card.addView(row().apply {
            addView(W.title(ctx, "Serie", 12f, R.color.text_secondary), W.weight(0.8f))
            addView(W.title(ctx, "Reps.", 12f, R.color.text_secondary).apply { gravity = Gravity.CENTER }, W.weight(1f))
            addView(W.title(ctx, "Peso (kg)", 12f, R.color.text_secondary).apply { gravity = Gravity.CENTER }, W.weight(1.2f))
            addView(W.title(ctx, "FC prom.", 12f, R.color.text_secondary).apply { gravity = Gravity.END }, W.weight(1.1f))
            addView(View(ctx), LinearLayout.LayoutParams(SUi.dp(ctx, 30f), 1))
        })
        e.sets.forEachIndexed { si, s ->
            card.addView(row().apply {
                val active = s.startMs != null && s.endMs == null
                addView(W.number(ctx, "${si + 1}", 18f, if (active) R.color.w_mint else R.color.text_primary), W.weight(0.8f))
                addView(SUi.numberField(ctx, s.reps.toString(), false) { v -> s.reps = v.toIntOrNull() ?: 0; persist() },
                    W.weight(1f).apply { marginEnd = SUi.dp(ctx, 8f) })
                addView(SUi.numberField(ctx, SUi.kg(s.kg), true) { v -> s.kg = v.replace(',', '.').toDoubleOrNull() ?: 0.0; persist() },
                    W.weight(1.2f).apply { marginEnd = SUi.dp(ctx, 8f) })
                val hr = setHr[k to si]
                val right = when {
                    active -> "en curso"
                    hr != null -> "$hr lpm"
                    s.done -> "-- lpm"
                    else -> ""
                }
                addView(W.number(ctx, right, 16f, if (active) R.color.w_mint else R.color.text_secondary).apply { gravity = Gravity.END }, W.weight(1.1f))
                addView(SUi.iconButton(ctx, R.drawable.ic_close) {
                    if (e.sets.size <= 1) { w.exercises.removeAt(k); fixSupersets() } else e.sets.removeAt(si)
                    persist(); render()
                }.apply { alpha = 0.5f; layoutParams = LinearLayout.LayoutParams(SUi.dp(ctx, 30f), SUi.dp(ctx, 30f)) })
            })
        }
        card.addView(W.title(ctx, "+ Agregar serie", 13.5f, R.color.w_mint).apply {
            setPadding(0, SUi.dp(ctx, 14f), 0, SUi.dp(ctx, 4f))
            isClickable = true
            setOnClickListener {
                val last = e.sets.lastOrNull()
                e.sets.add(Strength.SetEntry(last?.reps ?: 10, last?.kg ?: 0.0))
                persist(); render()
            }
        })
        return card
    }

    private fun exerciseMenu(k: Int) {
        val e = w.exercises[k]
        val items = ArrayList<Pair<String, () -> Unit>>()
        if (k > 0) items.add("Subir" to { w.exercises.add(k - 1, w.exercises.removeAt(k)); fixSupersets() })
        if (k < w.exercises.size - 1) items.add("Bajar" to { w.exercises.add(k + 1, w.exercises.removeAt(k)); fixSupersets() })
        if (e.superset == 0 && k < w.exercises.size - 1) items.add("Superserie con el siguiente" to {
            val n = w.exercises[k + 1]
            val g = if (n.superset != 0) n.superset else (w.exercises.maxOf { it.superset } + 1)
            e.superset = g; n.superset = g
        })
        if (e.superset != 0) items.add("Sacar de la superserie" to {
            e.superset = 0
            // si queda uno solo en el grupo, deja de ser superserie
            fixSupersets()
        })
        items.add("Eliminar ejercicio" to { w.exercises.removeAt(k); fixSupersets() })
        AlertDialog.Builder(this).setTitle(e.name).setItems(items.map { it.first }.toTypedArray()) { _, i ->
            items[i].second(); persist(); render()
        }.show()
    }

    /** Las superseries son grupos de ejercicios SEGUIDOS con el mismo número; un grupo de uno deja de serlo. */
    private fun fixSupersets() {
        var i = 0
        while (i < w.exercises.size) {
            val g = w.exercises[i].superset
            var j = i + 1
            if (g != 0) while (j < w.exercises.size && w.exercises[j].superset == g) j++
            if (g != 0 && j - i == 1) w.exercises[i].superset = 0
            i = j
        }
    }

    // ---------- Sesión en vivo ----------
    /** Orden de las series: ejercicio a ejercicio; en una superserie se alternan (A1, B1, A2, B2…). */
    private fun order(): List<Pair<Int, Int>> {
        val out = ArrayList<Pair<Int, Int>>()
        var i = 0
        while (i < w.exercises.size) {
            val g = w.exercises[i].superset
            var j = i + 1
            if (g != 0) while (j < w.exercises.size && w.exercises[j].superset == g) j++
            val maxSets = (i until j).maxOf { w.exercises[it].sets.size }
            if (j - i == 1) for (s in w.exercises[i].sets.indices) out.add(i to s)
            else for (s in 0 until maxSets) for (k in i until j) if (s < w.exercises[k].sets.size) out.add(k to s)
            i = j
        }
        return out
    }

    private fun current(): Pair<Int, Int>? = order().firstOrNull { (k, s) -> w.exercises[k].sets[s].let { it.startMs != null && it.endMs == null } }
    private fun next(): Pair<Int, Int>? = order().firstOrNull { (k, s) -> !w.exercises[k].sets[s].done && w.exercises[k].sets[s].startMs == null }

    private fun renderLive(c: LinearLayout) {
        val ctx = this
        if (w.exercises.isEmpty()) {
            c.addView(SUi.dashedAdd(ctx, "Agregar ejercicio", true) { pick(false) })
            return
        }
        val box = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
        liveBox = box
        c.addView(box)
        fillLive(box)
    }

    private fun fillLive(box: LinearLayout) {
        val ctx = this
        box.removeAllViews()
        val cur = current()
        val nx = cur ?: next()
        val now = System.currentTimeMillis()
        // Pulso en directo
        box.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.BOTTOM
            layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 22f) }
            val bpm = WhoopBackgroundService.lastBpm?.takeIf { now - WhoopBackgroundService.lastBpmTime < 15_000L }
            addView(W.number(ctx, bpm?.toString() ?: "--", 64f, R.color.strain_blue))
            addView(W.number(ctx, " lpm", 22f, R.color.strain_blue).apply { setPadding(0, 0, 0, SUi.dp(ctx, 8f)) })
        })
        val doneSets = w.exercises.sumOf { e -> e.sets.count { it.done } }
        box.addView(W.title(ctx, "$doneSets de ${w.setCount} series hechas", 13.5f, R.color.text_secondary).apply {
            setPadding(0, SUi.dp(ctx, 6f), 0, 0)
        })
        if (nx == null) {
            box.addView(W.card(ctx, 22f).apply {
                addView(W.title(ctx, "Todas las series hechas", 16f))
                addView(W.body(ctx, "Pulsa \"Finalizar entrenamiento\" para guardar la actividad, o agrega otro ejercicio con +.", 14.5f).apply {
                    setPadding(0, SUi.dp(ctx, 8f), 0, 0)
                })
            })
            return
        }
        val e = w.exercises[nx.first]; val s = e.sets[nx.second]
        box.addView(W.card(ctx, 22f).apply {
            setPadding(SUi.dp(ctx, 16f), SUi.dp(ctx, 16f), SUi.dp(ctx, 16f), SUi.dp(ctx, 20f))
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                addView(SUi.thumb(ctx, Strength.exercise(e.exId)?.group, 46f))
                addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(W.body(ctx, e.name, 16.5f, R.color.text_primary))
                    addView(W.title(ctx, (if (cur != null) "Serie en curso · " else "Siguiente · ") + "serie ${nx.second + 1} de ${e.sets.size}",
                        12.5f, if (cur != null) R.color.w_mint else R.color.text_secondary).apply { setPadding(0, SUi.dp(ctx, 6f), 0, 0) })
                }, W.weight().apply { marginStart = SUi.dp(ctx, 14f) })
            })
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 18f) }
                fun stat(v: String, l: String) = LinearLayout(ctx).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(W.number(ctx, v, 34f)); addView(W.title(ctx, l, 12f, R.color.text_secondary).apply { setPadding(0, SUi.dp(ctx, 4f), 0, 0) })
                }
                addView(stat("${s.reps}", "Reps."), W.weight())
                addView(stat(SUi.kg(s.kg) + " kg", "Peso"), W.weight())
                val t = if (cur != null) SUi.ms((now - (s.startMs ?: now)) / 1000) else restText(now)
                addView(stat(t, if (cur != null) "Tiempo de serie" else "Descanso"), W.weight())
            })
        })
        // Lo que queda
        val rest = order().filter { (k, si) -> !w.exercises[k].sets[si].done && (k to si) != nx }.take(4)
        if (rest.isNotEmpty()) {
            box.addView(W.title(ctx, "Después", 13.5f, R.color.text_secondary).apply { setPadding(0, SUi.dp(ctx, 24f), 0, 0) })
            for ((k, si) in rest) {
                val ee = w.exercises[k]; val ss = ee.sets[si]
                box.addView(Ui.listRow(ctx, ee.name, "${ss.reps} × ${SUi.kg(ss.kg)} kg", subtitle = "Serie ${si + 1} de ${ee.sets.size}").apply {
                    layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 8f) }
                })
            }
        }
        box.addView(W.body(ctx, "Cambia repeticiones y peso en la pestaña Ejercicios (también después de cada serie).", 13.5f).apply {
            setPadding(0, SUi.dp(ctx, 18f), 0, 0)
        })
    }

    private fun restText(now: Long): String {
        val lastEnd = w.exercises.flatMap { it.sets }.mapNotNull { it.endMs }.maxOrNull() ?: return "--"
        return SUi.ms((now - lastEnd) / 1000)
    }

    private fun updateClock() {
        if (mode != MODE_LIVE) return
        subtitle?.text = SUi.hms((System.currentTimeMillis() - w.startMs) / 1000)
        liveBox?.let { fillLive(it) }
    }

    private fun renderBottom() {
        val ctx = this
        val b = screen.bottom
        b.removeAllViews()
        when (mode) {
            MODE_LIVE -> {
                val cur = current()
                val nx = next()
                val btn = when {
                    w.exercises.isEmpty() -> SUi.button(ctx, "Comenzar la primera serie", primary = false, enabled = false) {}
                    cur != null -> SUi.button(ctx, "Finalizar serie", accent = Color.parseColor("#2BD4A0")) { endSet(cur) }
                    nx != null -> SUi.button(ctx, if (w.exercises.all { e -> e.sets.none { it.done } }) "Comenzar la primera serie" else "Comenzar serie") { startSet(nx) }
                    else -> SUi.button(ctx, "Finalizar entrenamiento") { finishWorkout() }
                }
                b.addView(btn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            }
            MODE_TEMPLATE -> b.addView(SUi.button(ctx, "Guardar entrenamiento", enabled = w.exercises.isNotEmpty()) {
                if (w.name.isBlank()) w.name = SUi.dateUpper(System.currentTimeMillis())
                w.startMs = System.currentTimeMillis()
                Strength.saveTemplate(w)
                Toast.makeText(ctx, "Guardado en Mis entrenamientos", Toast.LENGTH_SHORT).show()
                finish()
            }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            else -> b.addView(SUi.button(ctx, "Guardar") { saveLog() }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
    }

    private fun startSet(p: Pair<Int, Int>) {
        val s = w.exercises[p.first].sets[p.second]
        s.startMs = System.currentTimeMillis(); s.endMs = null; s.done = false
        screen.root.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        persist(); render()
    }

    private fun endSet(p: Pair<Int, Int>) {
        val s = w.exercises[p.first].sets[p.second]
        s.endMs = System.currentTimeMillis(); s.done = true
        screen.root.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        persist()
        lifecycleScope.launch { loadSetHr(); render() }
    }

    private fun finishWorkout() {
        val cur = current()
        if (cur != null) w.exercises[cur.first].sets[cur.second].apply { endMs = System.currentTimeMillis(); done = true }
        // Las series sin hacer no cuentan
        for (e in w.exercises) e.sets.removeAll { !it.done }
        w.exercises.removeAll { it.sets.isEmpty() }
        val minutes = (System.currentTimeMillis() - w.startMs) / 60000
        val ctx = this
        AlertDialog.Builder(ctx).setTitle("Finalizar entrenamiento")
            .setMessage("${w.exercises.size} ejercicios, ${w.setCount} series, ${SUi.kg(w.volume)} kg en $minutes min.\n\n" +
                "Se guardará como actividad \"Entrenamiento de fuerza\" con el pulso de este rato.")
            .setPositiveButton("Guardar") { _, _ ->
                lifecycleScope.launch {
                    val id = StrengthSave.finishLive(ctx, w, System.currentTimeMillis())
                    if (id == null) {
                        Toast.makeText(ctx, "No hay pulso de este rato: ¿está conectada la pulsera?", Toast.LENGTH_LONG).show()
                        return@launch
                    }
                    Strength.saveLive(null)
                    startActivity(Intent(ctx, ActivityDetailActivity::class.java).putExtra(ActivityDetailActivity.EXTRA_SESSION_ID, id))
                    finish()
                }
            }
            .setNeutralButton("Guardar y añadir a Mis entrenamientos") { _, _ ->
                saveAsTemplate(w, quiet = true)
                lifecycleScope.launch {
                    val id = StrengthSave.finishLive(ctx, w, System.currentTimeMillis())
                    if (id == null) {
                        Toast.makeText(ctx, "No hay pulso de este rato: ¿está conectada la pulsera?", Toast.LENGTH_LONG).show()
                        return@launch
                    }
                    Strength.saveLive(null)
                    startActivity(Intent(ctx, ActivityDetailActivity::class.java).putExtra(ActivityDetailActivity.EXTRA_SESSION_ID, id))
                    finish()
                }
            }
            .setNegativeButton("Seguir", null).show()
    }

    private fun saveAsTemplate(src: Strength.Workout, quiet: Boolean = false) {
        val t = Strength.Workout(System.currentTimeMillis(), System.currentTimeMillis(), 0,
            if (src.name.isNotBlank()) src.name else SUi.dateUpper(src.startMs.takeIf { it > 0 } ?: System.currentTimeMillis()))
        for (e in src.exercises) t.exercises.add(Strength.ExerciseEntry(e.exId, e.name, e.superset, e.sets.map { Strength.SetEntry(it.reps, it.kg) }.toMutableList()))
        Strength.saveTemplate(t)
        if (!quiet) Toast.makeText(this, "Guardado en Mis entrenamientos", Toast.LENGTH_SHORT).show()
    }

    private fun saveLog() {
        val ctx = this
        for (e in w.exercises) for (s in e.sets) s.done = true
        w.exercises.removeAll { it.sets.isEmpty() }
        w.id = sessionId
        Strength.saveLog(w)
        lifecycleScope.launch {
            val db = com.pulseapp.android.data.AppDatabase.getInstance(ctx)
            val s = db.activitySessionDao().getById(sessionId)
            // Una actividad sin deporte pasa a ser "Entrenamiento de fuerza"
            val newType = if (s != null && w.exercises.isNotEmpty() && (s.type == "Sin clasificar" || s.type.isBlank())) StrengthSave.TYPE else null
            StrengthSave.resummarize(ctx, sessionId, newType)
            Toast.makeText(ctx, "Ejercicios guardados", Toast.LENGTH_SHORT).show()
            finish()
        }
    }

    // ---------- Elegir ejercicios ----------
    private fun pick(@Suppress("UNUSED_PARAMETER") superset: Boolean) {
        persist()
        @Suppress("DEPRECATION")
        startActivityForResult(Intent(this, ExercisePickerActivity::class.java), REQ_PICK)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PICK || resultCode != RESULT_OK || data == null) return
        val ids = data.getStringArrayExtra(ExercisePickerActivity.RESULT_IDS) ?: return
        val superset = data.getBooleanExtra(ExercisePickerActivity.RESULT_SUPERSET, false) && ids.size > 1
        if (mode == MODE_LIVE) Strength.live()?.let { w = it }   // por si el servicio guardó algo mientras tanto
        val g = if (superset) (w.exercises.maxOfOrNull { it.superset } ?: 0) + 1 else 0
        for (id in ids) {
            val ex = Strength.exercise(id) ?: continue
            val sets = Strength.lastSetsOf(id)?.takeIf { it.isNotEmpty() }?.toMutableList()
                ?: MutableList(3) { Strength.SetEntry(if (ex.group == "Core") 12 else 10, 0.0) }
            w.exercises.add(Strength.ExerciseEntry(ex.id, ex.name, g, sets))
        }
        tab = if (mode == MODE_LIVE) 1 else tab
        persist(); render()
    }
}

/** FC media de cada serie cronometrada (ejercicio, serie) → lpm; null si la serie no tiene hora o no hay pulso. */
fun setHeartRates(file: File, w: Strength.Workout): Map<Pair<Int, Int>, Int?> {
    val timed = w.exercises.flatMapIndexed { k, e -> e.sets.mapIndexedNotNull { si, s -> if (s.startMs != null && s.endMs != null) Triple(k, si, s) else null } }
    if (timed.isEmpty() || !file.exists()) return emptyMap()
    val samples = StressCalculator().loadSamplesIn(file, timed.map { it.third.startMs!!..it.third.endMs!! })
    return timed.associate { (k, si, s) ->
        val v = samples.filter { it.timeMillis in s.startMs!!..s.endMs!! }.map { it.bpm }
        (k to si) to (if (v.isEmpty()) null else Math.round(v.average()).toInt())
    }
}
