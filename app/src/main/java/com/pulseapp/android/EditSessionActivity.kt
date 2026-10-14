package com.pulseapp.android

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.os.Bundle
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

class EditSessionActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_SESSION_ID = "session_id"
    }

    private val types = arrayOf("Fútbol", "Pádel", "Entrenamiento funcional", "Entrenamiento de fuerza", "Otro", "Sin clasificar")
    private var selectedType: String = "Sin clasificar"
    private var startCal = Calendar.getInstance()
    private var endCal = Calendar.getInstance()
    private val displayFmt = SimpleDateFormat("dd MMM yyyy · HH:mm", Locale("es"))

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_edit_session)

        val backButton: TextView = findViewById(R.id.backButton)
        val typeButton: Button = findViewById(R.id.typeButton)
        val startTimeButton: Button = findViewById(R.id.startTimeButton)
        val endTimeButton: Button = findViewById(R.id.endTimeButton)
        val saveButton: Button = findViewById(R.id.saveButton)

        backButton.setOnClickListener { finish() }

        val sessionId = intent.getLongExtra(EXTRA_SESSION_ID, -1)
        if (sessionId == -1L) { finish(); return }

        val db = AppDatabase.getInstance(this)

        lifecycleScope.launch {
            val session = db.activitySessionDao().getById(sessionId)
            if (session == null) { finish(); return@launch }

            selectedType = session.type
            startCal.timeInMillis = session.startMillis
            endCal.timeInMillis = session.endMillis

            typeButton.text = selectedType
            startTimeButton.text = displayFmt.format(startCal.time)
            endTimeButton.text = displayFmt.format(endCal.time)

            typeButton.setOnClickListener {
                androidx.appcompat.app.AlertDialog.Builder(this@EditSessionActivity)
                    .setTitle("Tipo de actividad")
                    .setItems(types) { _, index ->
                        selectedType = types[index]
                        typeButton.text = selectedType
                    }
                    .show()
            }

            startTimeButton.setOnClickListener {
                pickDateTime(startCal) { startTimeButton.text = displayFmt.format(startCal.time) }
            }
            endTimeButton.setOnClickListener {
                pickDateTime(endCal) { endTimeButton.text = displayFmt.format(endCal.time) }
            }

            saveButton.setOnClickListener {
                if (endCal.timeInMillis <= startCal.timeInMillis) {
                    Toast.makeText(this@EditSessionActivity, "La hora de fin debe ser posterior al inicio", Toast.LENGTH_SHORT).show()
                    return@setOnClickListener
                }

                lifecycleScope.launch {
                    val profile = db.userProfileDao().getOnce()
                    val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
                    val recalculated = ActivityRecorder().summarize(
                        file, startCal.timeInMillis, endCal.timeInMillis,
                        ageYears = profile?.ageYears() ?: 30,
                        weightKg = profile?.weightKg ?: 75f,
                        sex = profile?.sex ?: "M",
                        type = selectedType,
                        autoDetected = session.autoDetected,
                        restingHr = BaselineProvider().compute(db)?.avgRestingHr?.toInt()
                    )

                    if (recalculated == null) {
                        Toast.makeText(this@EditSessionActivity, "No hay datos de pulso en ese rango horario", Toast.LENGTH_LONG).show()
                        return@launch
                    }

                    Formulas.updateObservedHrMax(this@EditSessionActivity, recalculated.maxHr)
                    db.activitySessionDao().update(recalculated.copy(id = session.id))
                    Toast.makeText(this@EditSessionActivity, "Actividad actualizada", Toast.LENGTH_SHORT).show()
                    finish()
                }
            }
        }
    }

    private fun pickDateTime(calendar: Calendar, onPicked: () -> Unit) {
        DatePickerDialog(
            this,
            { _, year, month, day ->
                calendar.set(Calendar.YEAR, year)
                calendar.set(Calendar.MONTH, month)
                calendar.set(Calendar.DAY_OF_MONTH, day)
                TimePickerDialog(
                    this,
                    { _, hour, minute ->
                        calendar.set(Calendar.HOUR_OF_DAY, hour)
                        calendar.set(Calendar.MINUTE, minute)
                        onPicked()
                    },
                    calendar.get(Calendar.HOUR_OF_DAY),
                    calendar.get(Calendar.MINUTE),
                    true
                ).show()
            },
            calendar.get(Calendar.YEAR),
            calendar.get(Calendar.MONTH),
            calendar.get(Calendar.DAY_OF_MONTH)
        ).show()
    }
}
