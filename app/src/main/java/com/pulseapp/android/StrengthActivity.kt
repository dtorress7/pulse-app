package com.pulseapp.android

import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import kotlinx.coroutines.launch

/** Entrenador de fuerza (5/11): PROGRESO · MIS ENTRENAMIENTOS · ENTRENAMIENTOS, como WHOOP. */
class StrengthActivity : AppCompatActivity() {
    private lateinit var screen: SUi.Screen
    private var tab = 1

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Formulas.init(this)
        screen = SUi.screen(this)
    }

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun render() {
        val ctx = this
        screen.top.removeAllViews()
        screen.top.addView(SUi.header(ctx, R.drawable.ic_close, { finish() }, "Entrenador de fuerza", null, R.drawable.ic_info) { info() })
        screen.top.addView(SUi.tabs(ctx, listOf("Progreso", "Mis entrenamientos", "Entrenamientos"), tab) { tab = it; render() })
        val c = screen.content
        c.removeAllViews()
        Strength.live()?.let { live ->
            c.addView(W.card(ctx, 18f).apply {
                background = SUi.rounded(ctx, Ui.color(ctx, R.color.w_card), 14f, Color.parseColor("#2BD4A0"))
                addView(W.title(ctx, "Entrenamiento en curso", 15f, R.color.w_mint))
                addView(W.body(ctx, "Empezó a las ${java.text.SimpleDateFormat("HH:mm", java.util.Locale.US).format(java.util.Date(live.startMs))} · " +
                    "${live.exercises.size} ejercicios", 14.5f).apply { setPadding(0, SUi.dp(ctx, 6f), 0, SUi.dp(ctx, 12f)) })
                addView(SUi.button(ctx, "Continuar") { StrengthSessionActivity.startLive(ctx, null) })
            })
        }
        when (tab) {
            0 -> progress(c)
            1 -> mine(c)
            else -> presets(c)
        }
    }

    private fun info() {
        AlertDialog.Builder(this).setTitle("Entrenador de fuerza")
            .setMessage("Registra tus ejercicios, series, repeticiones y peso. Si pulsas \"Comenzar serie\" y \"Finalizar serie\" se guarda " +
                "el pulso de cada serie.\n\nEl esfuerzo de la actividad suma tu pulso (cardio) y la carga muscular de tus series: " +
                "repeticiones × (peso + la parte de tu peso corporal que mueve el ejercicio). Sin series registradas se estima por minutos.\n\n" +
                "Calibrado con tu entreno del 4/11 (WHOOP 8,1). Cuantos más entrenos registres, mejor se podrá ajustar.")
            .setPositiveButton("OK", null).show()
    }

    // ---------- Mis entrenamientos ----------
    private fun mine(c: LinearLayout) {
        val ctx = this
        c.addView(W.body(ctx, "Iniciar un entrenamiento", 21f, R.color.text_primary).apply { setPadding(0, SUi.dp(ctx, 24f), 0, 0) })
        c.addView(W.body(ctx, "Empieza directamente con un entrenamiento y registra los ejercicios mientras avanzas.", 15f).apply {
            setPadding(0, SUi.dp(ctx, 6f), 0, SUi.dp(ctx, 18f))
        })
        c.addView(SUi.button(ctx, "Inicio rápido") { StrengthSessionActivity.startLive(ctx, null) })
        c.addView(View(ctx).apply { setBackgroundColor(Color.parseColor("#22FFFFFF")) }, SUi.mp(SUi.dp(ctx, 1f)).apply { topMargin = SUi.dp(ctx, 26f) })
        c.addView(W.body(ctx, "Mis entrenamientos", 21f, R.color.text_primary).apply { setPadding(0, SUi.dp(ctx, 24f), 0, SUi.dp(ctx, 14f)) })
        // "Genera con IA" de WHOOP → aquí, desde un texto (sin conexión no hay IA)
        c.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable(GradientDrawable.Orientation.TL_BR, intArrayOf(Color.parseColor("#2A2550"), Color.parseColor("#1B3A4A"))).apply {
                cornerRadius = SUi.dp(ctx, 14f).toFloat(); setStroke(SUi.dp(ctx, 1.4f), Color.parseColor("#7FA7FF"))
            }
            setPadding(SUi.dp(ctx, 16f), SUi.dp(ctx, 18f), SUi.dp(ctx, 16f), SUi.dp(ctx, 18f))
            addView(W.body(ctx, "Genera a partir de un texto", 17f, R.color.text_primary))
            addView(W.body(ctx, "Escribe o pega tu entrenamiento (\"press banca 4x8 40 kg, dominadas 4x8…\") y PulseApp lo creará.", 15f, R.color.text_primary).apply {
                alpha = 0.85f; setPadding(0, SUi.dp(ctx, 8f), 0, SUi.dp(ctx, 12f))
            })
            addView(W.title(ctx, "Empezar  →", 14f, R.color.w_insight_border))
            isClickable = true
            setOnClickListener { generate() }
        })
        c.addView(SUi.button(ctx, "Crear un entrenamiento", primary = false) {
            startActivity(Intent(ctx, StrengthSessionActivity::class.java).putExtra(StrengthSessionActivity.EXTRA_MODE, StrengthSessionActivity.MODE_TEMPLATE))
        }.apply { layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 16f) } })
        c.addView(View(ctx).apply { setBackgroundColor(Color.parseColor("#22FFFFFF")) }, SUi.mp(SUi.dp(ctx, 1f)).apply { topMargin = SUi.dp(ctx, 22f) })
        val list = Strength.templates()
        if (list.isEmpty()) c.addView(W.body(ctx, "Aún no tienes entrenamientos guardados. Al finalizar uno puedes añadirlo aquí.", 14.5f).apply {
            setPadding(0, SUi.dp(ctx, 16f), 0, 0)
        })
        for (t in list) c.addView(templateRow(t))
    }

    private fun templateRow(t: Strength.Workout): LinearLayout {
        val ctx = this
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setBackgroundResource(R.drawable.bg_card_w)
            setPadding(SUi.dp(ctx, 16f), SUi.dp(ctx, 12f), SUi.dp(ctx, 6f), SUi.dp(ctx, 12f))
            layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 12f) }
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                addView(W.title(ctx, t.name.ifBlank { SUi.dateUpper(t.startMs) }, 16f))
                addView(W.body(ctx, "${t.exercises.size} ejercicios · ${t.setCount} series", 13.5f).apply { setPadding(0, SUi.dp(ctx, 4f), 0, 0) })
            }, W.weight())
            addView(SUi.iconButton(ctx, R.drawable.ic_more) { templateMenu(t) })
            isClickable = true
            setOnClickListener { preview(t, saved = true) }
        }
    }

    private fun templateMenu(t: Strength.Workout) {
        val ctx = this
        AlertDialog.Builder(ctx).setTitle(t.name).setItems(arrayOf("Empezar", "Editar", "Eliminar")) { _, i ->
            when (i) {
                0 -> StrengthSessionActivity.startLive(ctx, t)
                1 -> startActivity(Intent(ctx, StrengthSessionActivity::class.java)
                    .putExtra(StrengthSessionActivity.EXTRA_MODE, StrengthSessionActivity.MODE_TEMPLATE)
                    .putExtra(StrengthSessionActivity.EXTRA_TEMPLATE_ID, t.id))
                else -> AlertDialog.Builder(ctx).setTitle("¿Eliminar \"${t.name}\"?").setPositiveButton("Eliminar") { _, _ ->
                    Strength.deleteTemplate(t.id); render()
                }.setNegativeButton("Cancelar", null).show()
            }
        }.show()
    }

    /** Vista previa de un entrenamiento: lista de ejercicios con series, y empezar / guardar. */
    private fun preview(t: Strength.Workout, saved: Boolean) {
        val ctx = this
        val text = t.exercises.joinToString("\n") { e ->
            val s = e.sets.firstOrNull()
            (if (e.superset != 0) "⟳ " else "• ") + e.name + "  ${e.sets.size}×${s?.reps ?: 0}" + (if ((s?.kg ?: 0.0) > 0) " · ${SUi.kg(s!!.kg)} kg" else "")
        }
        val b = AlertDialog.Builder(ctx).setTitle(t.name.ifBlank { "Entrenamiento" }).setMessage(text.ifBlank { "Sin ejercicios" })
            .setPositiveButton("Empezar") { _, _ -> StrengthSessionActivity.startLive(ctx, t) }
            .setNegativeButton("Cerrar", null)
        if (!saved) b.setNeutralButton("Editar y guardar") { _, _ ->
            StrengthSessionActivity.pending = t.copy().also { it.id = System.currentTimeMillis() }
            startActivity(Intent(ctx, StrengthSessionActivity::class.java).putExtra(StrengthSessionActivity.EXTRA_MODE, StrengthSessionActivity.MODE_TEMPLATE))
        }
        b.show()
    }

    private fun generate() {
        val ctx = this
        val field = SUi.textField(ctx, "Ej.: press de banca mancuerna 4x8 40 kg\ndominadas 4x8\nremo con polea 3x10 35 kg\n+ remo inclinado 3x10 35 kg (superserie)", multiLine = true).apply {
            setTextColor(Color.BLACK); setHintTextColor(Color.GRAY); background = null
        }
        val box = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; setPadding(SUi.dp(ctx, 18f), SUi.dp(ctx, 8f), SUi.dp(ctx, 18f), 0); addView(field) }
        AlertDialog.Builder(ctx).setTitle("Describe tu entrenamiento").setView(box)
            .setPositiveButton("Crear") { _, _ ->
                val w = Strength.parse(field.text.toString())
                if (w.exercises.isEmpty()) {
                    AlertDialog.Builder(ctx).setMessage("No he encontrado ningún ejercicio. Escribe uno por línea con series × repeticiones y el peso.")
                        .setPositiveButton("OK", null).show()
                } else {
                    w.name = "Generado " + SUi.dateUpper(System.currentTimeMillis())
                    preview(w, saved = false)
                }
            }
            .setNegativeButton("Cancelar", null).show()
    }

    // ---------- Entrenamientos de ejemplo ----------
    private fun presets(c: LinearLayout) {
        val ctx = this
        c.addView(W.body(ctx, "Entrenamientos de ejemplo para empezar. Al terminarlos se guardan tus pesos y la próxima vez se rellenan solos.", 14.5f).apply {
            setPadding(0, SUi.dp(ctx, 20f), 0, SUi.dp(ctx, 4f))
        })
        for (p in Strength.presets()) {
            c.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                setBackgroundResource(R.drawable.bg_card_w)
                setPadding(SUi.dp(ctx, 10f), SUi.dp(ctx, 10f), SUi.dp(ctx, 16f), SUi.dp(ctx, 10f))
                layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 12f) }
                addView(SUi.thumb(ctx, Strength.exercise(p.exercises.first().exId)?.group, 50f))
                addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(W.title(ctx, p.name, 16f))
                    addView(W.body(ctx, p.exercises.joinToString(" · ") { it.name.substringBefore(" - ") }, 13f).apply {
                        maxLines = 2; setPadding(0, SUi.dp(ctx, 4f), 0, 0)
                    })
                }, W.weight().apply { marginStart = SUi.dp(ctx, 14f) })
                isClickable = true
                setOnClickListener { preview(p, saved = false) }
            })
        }
    }

    // ---------- Progreso ----------
    private fun progress(c: LinearLayout) {
        val ctx = this
        val logs = Strength.logs().filter { it.id > 0 && it.setCount > 0 }
        lifecycleScope.launch {
            // Solo los registros cuya actividad sigue existiendo
            val ids = AppDatabase.getInstance(ctx).activitySessionDao().getAll().map { it.id }.toSet()
            val valid = logs.filter { it.id in ids }
            if (tab != 0) return@launch
            c.addView(milestoneCard(ctx, valid.size).apply { layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 20f) } })
            if (valid.isEmpty()) {
                c.addView(W.body(ctx, "Cuando registres entrenamientos aquí verás tu volumen por semana y tus mejores marcas.", 14.5f).apply {
                    setPadding(0, SUi.dp(ctx, 18f), 0, 0)
                })
                return@launch
            }
            // Volumen por semana (últimas 8)
            c.addView(W.title(ctx, "Volumen de carga por semana", 15f).apply { setPadding(0, SUi.dp(ctx, 28f), 0, SUi.dp(ctx, 12f)) })
            val zone = java.time.ZoneId.systemDefault()
            val monday = java.time.LocalDate.now(zone).with(java.time.DayOfWeek.MONDAY)
            val weeks = (7 downTo 0).map { monday.minusWeeks(it.toLong()) }
            val vols = weeks.map { wk ->
                val a = wk.atStartOfDay(zone).toInstant().toEpochMilli(); val b = wk.plusWeeks(1).atStartOfDay(zone).toInstant().toEpochMilli()
                valid.filter { it.startMs in a until b }.sumOf { it.volume }
            }
            val maxV = vols.maxOrNull()?.takeIf { it > 0 } ?: 1.0
            c.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.BOTTOM
                layoutParams = SUi.mp(SUi.dp(ctx, 150f))
                weeks.forEachIndexed { i, wk ->
                    addView(LinearLayout(ctx).apply {
                        orientation = LinearLayout.VERTICAL; gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                        if (vols[i] > 0) addView(W.number(ctx, "%.1f".format(vols[i] / 1000).replace('.', ','), 11f, R.color.text_secondary).apply { gravity = Gravity.CENTER })
                        addView(View(ctx).apply {
                            background = SUi.rounded(ctx, Ui.color(ctx, R.color.strain_blue), 3f)
                            alpha = if (i == weeks.size - 1) 1f else 0.7f
                        }, LinearLayout.LayoutParams(SUi.dp(ctx, 18f), (SUi.dp(ctx, 100f) * (vols[i] / maxV)).toInt().coerceAtLeast(SUi.dp(ctx, 2f))).apply {
                            topMargin = SUi.dp(ctx, 4f)
                        })
                        addView(W.number(ctx, "${wk.dayOfMonth}/${wk.monthValue}", 11f, R.color.text_secondary).apply { setPadding(0, SUi.dp(ctx, 6f), 0, 0) })
                    }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f))
                }
            })
            c.addView(W.body(ctx, "Toneladas (kg × repeticiones) por semana, de lunes a domingo.", 13f).apply { setPadding(0, SUi.dp(ctx, 8f), 0, 0) })
            // Tus ejercicios: mejor serie y última vez
            c.addView(W.title(ctx, "Tus ejercicios", 15f).apply { setPadding(0, SUi.dp(ctx, 28f), 0, SUi.dp(ctx, 4f)) })
            val byEx = valid.flatMap { w -> w.exercises.map { it to w } }.groupBy { it.first.exId }
            for ((exId, entries) in byEx.entries.sortedByDescending { e -> e.value.maxOf { it.second.startMs } }) {
                val name = Strength.exercise(exId)?.name ?: entries.first().first.name
                val best = entries.flatMap { it.first.sets }.maxByOrNull { Strength.setScore(it) } ?: continue
                val last = entries.maxByOrNull { it.second.startMs }!!
                c.addView(Ui.listRow(ctx, name, "${best.reps} × ${SUi.kg(best.kg)} kg",
                    subtitle = "${entries.size} ${if (entries.size == 1) "vez" else "veces"} · última ${SUi.dateLower(last.second.startMs)}").apply {
                    layoutParams = SUi.mp().apply { topMargin = SUi.dp(ctx, 8f) }
                })
            }
            c.addView(W.body(ctx, "A la derecha, tu mejor serie: la de más peso (o más repeticiones si es sin peso).", 13f).apply { setPadding(0, SUi.dp(ctx, 10f), 0, 0) })
        }
    }
}

/** Tarjeta de hito: "9/10 · 1 más hasta tu próximo hito". */
fun milestoneCard(ctx: android.content.Context, count: Int): LinearLayout {
    val (done, next) = Strength.milestone(count)
    return LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        background = SUi.rounded(ctx, Color.TRANSPARENT, 16f, Color.parseColor("#33FFFFFF"))
        setPadding(SUi.dp(ctx, 16f), SUi.dp(ctx, 16f), SUi.dp(ctx, 16f), SUi.dp(ctx, 16f))
        addView(android.widget.FrameLayout(ctx).apply {
            background = SUi.rounded(ctx, Color.parseColor("#1E2A4A"), 40f, Color.parseColor("#7FA7FF"), dashed = true)
            layoutParams = LinearLayout.LayoutParams(SUi.dp(ctx, 64f), SUi.dp(ctx, 64f))
            addView(android.widget.ImageView(ctx).apply {
                setImageResource(R.drawable.ic_dumbbell); setColorFilter(Color.WHITE)
                layoutParams = android.widget.FrameLayout.LayoutParams(SUi.dp(ctx, 30f), SUi.dp(ctx, 30f), Gravity.CENTER)
            })
        })
        addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(W.number(ctx, "$done", 22f, R.color.w_insight_border))
                addView(W.number(ctx, "/$next", 22f))
            })
            val left = next - done
            addView(W.body(ctx, "$left más hasta tu próximo hito", 14.5f, R.color.text_primary).apply { setPadding(0, SUi.dp(ctx, 4f), 0, SUi.dp(ctx, 8f)) })
            addView(Ui.progressBar(ctx, done.toFloat() / next, R.color.w_insight_border))
        }, W.weight().apply { marginStart = SUi.dp(ctx, 16f) })
    }
}
