package com.pulseapp.android

import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.res.ResourcesCompat
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.ActivitySession
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.ui.CircularRingView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Pestaña Esfuerzo (rediseño): esfuerzo del día, calorías, pasos, actividades con zonas y 7 días. */
class ActivitiesListActivity : AppCompatActivity() {

    private val es = Locale("es", "ES")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_activities)
        Ui.setupTabBar(this, Ui.Tab.ACTIVITIES)
        findViewById<TextView>(R.id.dateText).text =
            SimpleDateFormat("EEEE, d 'de' MMMM", es).format(Date()).replaceFirstChar { it.uppercase() }
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun load() {
        lifecycleScope.launch {
            val ctx = this@ActivitiesListActivity
            val db = AppDatabase.getInstance(ctx)
            val profile = db.userProfileDao().getOnce()
            val age = profile?.ageYears() ?: 30
            val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
            val summary = withContext(Dispatchers.IO) { MetricsCalculator(ageYears = age).analyze(file) }
            val sessions = db.activitySessionDao().getAll().sortedByDescending { it.startMillis }
            val today = sessions.filter { it.startMillis >= Ui.todayStartMillis() }

            // Anillo y nivel
            val strain = summary.strain
            findViewById<CircularRingView>(R.id.strainRing).setValue(
                (strain / 21.0).toFloat(), Ui.comma(strain), "de 21", Ui.color(ctx, R.color.strain_blue)
            )
            findViewById<TextView>(R.id.levelText).text = when {
                strain < 10 -> "Ligero"
                strain < 14 -> "Moderado"
                strain < 18 -> "Intenso"
                else -> "Máximo"
            }
            findViewById<TextView>(R.id.avgHrText).text = summary.avgHr?.toString() ?: "--"
            findViewById<TextView>(R.id.maxHrText).text = today.maxOfOrNull { it.maxHr }?.toString() ?: "--"

            // Calorías y pasos
            findViewById<TextView>(R.id.caloriesText).text = profile?.let {
                val now = java.util.Calendar.getInstance()
                val elapsed = now.get(java.util.Calendar.HOUR_OF_DAY) * 60.0 + now.get(java.util.Calendar.MINUTE)
                Ui.thousands(CalorieCalculator().estimateDailyTotal(elapsed, today.sumOf { s -> s.caloriesKcal }, age, it.weightKg, it.heightCm, it.sex).toLong())
            } ?: "--"
            val steps = withContext(Dispatchers.IO) { Ui.stepsToday(ctx) }
            findViewById<TextView>(R.id.stepsText).text = if (steps > 0) Ui.thousands(steps.toLong()) else "--"

            // Actividades
            val list: LinearLayout = findViewById(R.id.activitiesList)
            list.removeAllViews()
            if (sessions.isEmpty()) {
                list.addView(Ui.emptyText(ctx, "Todavía no has guardado ninguna actividad. Pulsa «Iniciar actividad» en Inicio para grabar una.").apply {
                    setBackgroundResource(R.drawable.bg_card)
                })
            } else {
                sessions.take(30).forEachIndexed { i, s ->
                    list.addView(activityCard(s).apply {
                        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                            if (i > 0) topMargin = Ui.dp(ctx, 12f)
                        }
                    })
                }
            }

            // Últimos 7 días
            val days = db.dailyMetricsDao().getLastDays(6).sortedBy { it.date }
            val items = days.map { Triple(Ui.weekdayLetter(it.date), it.strain, R.color.strain_blue) } +
                Triple("Hoy", strain, R.color.strain_blue)
            Ui.fillWeekBars(findViewById(R.id.weekBars), items, 21.0) { Ui.comma(it) }
            val valid = items.mapNotNull { it.second }
            findViewById<TextView>(R.id.weekAverageText).text = if (valid.size > 1) "Media ${Ui.comma(valid.average())}" else ""
        }
    }

    private fun activityCard(s: ActivitySession): LinearLayout {
        val ctx = this
        val time = SimpleDateFormat("HH:mm", es)
        val isToday = s.startMillis >= Ui.todayStartMillis()
        val day = if (isToday) "Hoy" else SimpleDateFormat("d MMM", es).format(Date(s.startMillis))
        val duration = ((s.endMillis - s.startMillis) / 60000).toInt()
        val sub = "$day · ${time.format(Date(s.startMillis))} – ${time.format(Date(s.endMillis))} · ${Ui.hm(duration)}" +
            if (s.autoDetected) " · detectada" else ""
        val condensed = ResourcesCompat.getFont(ctx, R.font.barlow_condensed_semibold)

        return LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundResource(R.drawable.bg_card)
            val p = Ui.dp(ctx, 16f)
            setPadding(Ui.dp(ctx, 18f), p, Ui.dp(ctx, 18f), p)
            isClickable = true
            isFocusable = true
            setOnClickListener {
                startActivity(Intent(ctx, EditSessionActivity::class.java).putExtra(EditSessionActivity.EXTRA_SESSION_ID, s.id))
            }

            // Cabecera: icono, nombre, horario y esfuerzo
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(ImageView(ctx).apply {
                    setImageResource(R.drawable.ic_activity)
                    setBackgroundResource(R.drawable.bg_icon_strain)
                    setColorFilter(Ui.color(ctx, R.color.strain_blue))
                    val ip = Ui.dp(ctx, 10f)
                    setPadding(ip, ip, ip, ip)
                    layoutParams = LinearLayout.LayoutParams(Ui.dp(ctx, 40f), Ui.dp(ctx, 40f))
                })
                addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.VERTICAL
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = Ui.dp(ctx, 12f) }
                    addView(TextView(ctx).apply {
                        text = s.type
                        textSize = 16f
                        typeface = ResourcesCompat.getFont(ctx, R.font.archivo_semibold)
                        setTextColor(Ui.color(ctx, R.color.text_primary))
                    })
                    addView(TextView(ctx).apply {
                        text = sub
                        textSize = 12f
                        setTextColor(Ui.color(ctx, R.color.text_secondary))
                    })
                })
                addView(LinearLayout(ctx).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.END
                    addView(TextView(ctx).apply {
                        text = Ui.comma(s.strain)
                        textSize = 30f
                        typeface = Ui.boldCondensed(ctx)
                        includeFontPadding = false
                        setTextColor(Ui.color(ctx, R.color.strain_blue))
                    })
                    addView(TextView(ctx).apply {
                        text = "ESFUERZO"
                        textSize = 10f
                        letterSpacing = 0.14f
                        typeface = condensed
                        setTextColor(Ui.color(ctx, R.color.text_secondary))
                    })
                })
            })

            // FC media, FC máx, calorías
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(0, Ui.dp(ctx, 14f), 0, 0)
                listOf("FC media" to "${s.avgHr}", "FC máx" to "${s.maxHr}", "Calorías" to "%.0f".format(s.caloriesKcal)).forEach { (l, v) ->
                    addView(LinearLayout(ctx).apply {
                        orientation = LinearLayout.VERTICAL
                        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                        addView(TextView(ctx).apply {
                            text = l.uppercase(); textSize = 10f; letterSpacing = 0.14f; typeface = condensed
                            setTextColor(Ui.color(ctx, R.color.text_secondary))
                        })
                        addView(TextView(ctx).apply {
                            text = v; textSize = 20f; typeface = Ui.boldCondensed(ctx)
                            setTextColor(Ui.color(ctx, R.color.text_primary))
                        })
                    })
                }
            })

            // Zonas: barra apilada + minutos
            val zones = listOf(
                s.minutesZone1 to R.color.zone1, s.minutesZone2 to R.color.zone2, s.minutesZone3 to R.color.zone3,
                s.minutesZone4 to R.color.zone4, s.minutesZone5 to R.color.zone5
            )
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Ui.dp(ctx, 8f)).apply { topMargin = Ui.dp(ctx, 14f) }
                Ui.fillStackedBar(this, zones.map { it.first.toFloat() to it.second })
            })
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(0, Ui.dp(ctx, 10f), 0, 0)
                zones.forEachIndexed { i, (min, colorRes) ->
                    addView(LinearLayout(ctx).apply {
                        orientation = LinearLayout.VERTICAL
                        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                        addView(TextView(ctx).apply {
                            text = "● Z${i + 1}"; textSize = 10f; typeface = condensed
                            setTextColor(Ui.color(ctx, colorRes))
                        })
                        addView(TextView(ctx).apply {
                            text = Ui.hm(min); textSize = 16f; typeface = Ui.boldCondensed(ctx)
                            setTextColor(Ui.color(ctx, R.color.text_primary))
                        })
                    })
                }
            })
            if (s.minutesZone0 > 0) addView(TextView(ctx).apply {
                text = "Además ${Ui.hm(s.minutesZone0)} en zona 0 (por debajo del 50 % de tu FC máx)."
                textSize = 12f
                setTextColor(Ui.color(ctx, R.color.text_secondary))
                setPadding(0, Ui.dp(ctx, 8f), 0, 0)
            })
        }
    }
}
