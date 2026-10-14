package com.pulseapp.android

import android.app.DatePickerDialog
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.data.UserProfile
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

class ProfileActivity : AppCompatActivity() {

    private lateinit var birthdayButton: Button
    private lateinit var weightInput: EditText
    private lateinit var heightInput: EditText
    private lateinit var sexGroup: RadioGroup
    private lateinit var sexMale: RadioButton
    private lateinit var sexFemale: RadioButton
    private lateinit var saveButton: Button
    private lateinit var ageResultText: TextView

    private var selectedBirthdayMillis: Long? = null
    private val dateFormat = SimpleDateFormat("dd/MM/yyyy", Locale.getDefault())

    private val db by lazy { AppDatabase.getInstance(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_profile)

        birthdayButton = findViewById(R.id.birthdayButton)
        weightInput = findViewById(R.id.weightInput)
        heightInput = findViewById(R.id.heightInput)
        sexGroup = findViewById(R.id.sexGroup)
        sexMale = findViewById(R.id.sexMale)
        sexFemale = findViewById(R.id.sexFemale)
        saveButton = findViewById(R.id.saveProfileButton)
        ageResultText = findViewById(R.id.ageResultText)

        birthdayButton.setOnClickListener { pickBirthday() }
        saveButton.setOnClickListener { saveProfile() }

        loadExistingProfile()
    }

    private fun pickBirthday() {
        val calendar = Calendar.getInstance()
        selectedBirthdayMillis?.let { calendar.timeInMillis = it }
        DatePickerDialog(
            this,
            { _, year, month, day ->
                val cal = Calendar.getInstance()
                cal.set(year, month, day, 0, 0, 0)
                selectedBirthdayMillis = cal.timeInMillis
                birthdayButton.text = dateFormat.format(cal.time)
            },
            calendar.get(Calendar.YEAR) - 25,
            calendar.get(Calendar.MONTH),
            calendar.get(Calendar.DAY_OF_MONTH)
        ).show()
    }

    private fun loadExistingProfile() {
        lifecycleScope.launch {
            val profile = db.userProfileDao().getOnce() ?: return@launch
            selectedBirthdayMillis = profile.birthdayMillis
            birthdayButton.text = dateFormat.format(profile.birthdayMillis)
            weightInput.setText(profile.weightKg.toString())
            heightInput.setText(profile.heightCm.toString())
            if (profile.sex == "M") sexMale.isChecked = true else sexFemale.isChecked = true
            ageResultText.text = "Edad calculada: ${profile.ageYears()} años"
        }
    }

    private fun saveProfile() {
        val birthday = selectedBirthdayMillis
        val weight = weightInput.text.toString().toFloatOrNull()
        val height = heightInput.text.toString().toFloatOrNull()
        val sex = when (sexGroup.checkedRadioButtonId) {
            R.id.sexMale -> "M"
            R.id.sexFemale -> "F"
            else -> null
        }

        if (birthday == null || weight == null || height == null || sex == null) {
            Toast.makeText(this, "Rellena todos los campos", Toast.LENGTH_SHORT).show()
            return
        }

        val profile = UserProfile(
            birthdayMillis = birthday,
            weightKg = weight,
            heightCm = height,
            sex = sex
        )

        lifecycleScope.launch {
            db.userProfileDao().save(profile)
            ageResultText.text = "Edad calculada: ${profile.ageYears()} años"
            Toast.makeText(this@ProfileActivity, "Perfil guardado", Toast.LENGTH_SHORT).show()
        }
    }
}
