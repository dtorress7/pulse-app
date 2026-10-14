package com.pulseapp.android

import android.os.Bundle
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.ActivitySession
import com.pulseapp.android.data.AppDatabase
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Locale

class ActivitiesListActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_activities)

        val backButton: TextView = findViewById(R.id.backButton)
        val activitiesList: LinearLayout = findViewById(R.id.activitiesList)

        backButton.setOnClickListener { finish() }

        lifecycleScope.launch {
            val db = AppDatabase.getInstance(this@ActivitiesListActivity)
            val sessions = db.activitySessionDao().getAll()

            if (sessions.isEmpty()) {
                val emptyText = TextView(this@ActivitiesListActivity).apply {
                    text = "Todavía no has guardado ninguna actividad.\nUsa el botón + de la barra inferior para empezar a grabar."
                    setTextColor(ContextCompat.getColor(this@ActivitiesListActivity, R.color.text_secondary))
                    textSize = 14f
                    setPadding(16, 48, 16, 16)
                }
                activitiesList.addView(emptyText)
                return@launch
            }

            val dateFmt = SimpleDateFormat("dd MMM · HH:mm", Locale("es"))

            sessions.forEach { session ->
                activitiesList.addView(buildActivityCard(session, dateFmt))
            }
        }
    }

    private fun buildActivityCard(session: ActivitySession, dateFmt: SimpleDateFormat): LinearLayout {
        val durationMinutes = ((session.endMillis - session.startMillis) / 60000).toInt()

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundResource(R.drawable.bg_card)
            setPadding(32, 32, 32, 32)
            val params = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            params.bottomMargin = 24
            layoutParams = params
            isClickable = true
            isFocusable = true
            setOnClickListener {
                val intent = android.content.Intent(this@ActivitiesListActivity, EditSessionActivity::class.java)
                intent.putExtra(EditSessionActivity.EXTRA_SESSION_ID, session.id)
                startActivity(intent)
            }
        }

        val dateText = TextView(this).apply {
            text = "${dateFmt.format(session.startMillis)} · ${session.type}"
            setTextColor(ContextCompat.getColor(this@ActivitiesListActivity, R.color.text_secondary))
            textSize = 12f
        }

        val durationText = TextView(this).apply {
            text = "$durationMinutes min"
            setTextColor(ContextCompat.getColor(this@ActivitiesListActivity, R.color.text_primary))
            textSize = 28f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }

        val statsRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            val params = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            params.topMargin = 16
            layoutParams = params
        }

                statsRow.addView(buildStatColumn("FC MEDIA", "${session.avgHr} bpm", R.color.text_primary))
        statsRow.addView(buildStatColumn("FC MÁX", "${session.maxHr} bpm", R.color.alert_amber))
        statsRow.addView(buildStatColumn("STRAIN", "%.1f".format(session.strain), R.color.strain_blue))
        statsRow.addView(buildStatColumn("KCAL", "%.0f".format(session.caloriesKcal), R.color.recovery_green))

        val zonesRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            val params = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            params.topMargin = 12
            layoutParams = params
        }
        zonesRow.addView(buildStatColumn("Z0", "${session.minutesZone0}m", R.color.text_secondary))
        zonesRow.addView(buildStatColumn("Z1", "${session.minutesZone1}m", R.color.sleep_blue))
        zonesRow.addView(buildStatColumn("Z2", "${session.minutesZone2}m", R.color.recovery_green))
        zonesRow.addView(buildStatColumn("Z3", "${session.minutesZone3}m", R.color.strain_blue))
        zonesRow.addView(buildStatColumn("Z4", "${session.minutesZone4}m", R.color.alert_amber))
        zonesRow.addView(buildStatColumn("Z5", "${session.minutesZone5}m", R.color.alert_red))

        card.addView(dateText)
        card.addView(durationText)
        card.addView(statsRow)
        card.addView(zonesRow)
        return card
    }

    private fun buildStatColumn(label: String, value: String, colorRes: Int): LinearLayout {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val labelText = TextView(this).apply {
            text = label
            setTextColor(ContextCompat.getColor(this@ActivitiesListActivity, R.color.text_secondary))
            textSize = 10f
        }
        val valueText = TextView(this).apply {
            text = value
            setTextColor(ContextCompat.getColor(this@ActivitiesListActivity, colorRes))
            textSize = 15f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }
        column.addView(labelText)
        column.addView(valueText)
        return column
    }
}
