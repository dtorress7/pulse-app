package com.pulseapp.android

import android.app.DatePickerDialog
import android.content.Intent
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.res.ResourcesCompat
import androidx.lifecycle.lifecycleScope
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.data.UserProfile
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/**
 * "Sobre mí" (rediseño): lista agrupada estilo iOS. Cada fila se edita al tocarla y el perfil
 * se guarda solo en cuanto los 4 datos están completos (conserva el VO2 máx ya calculado).
 */
class ProfileActivity : AppCompatActivity() {

    private val db by lazy { AppDatabase.getInstance(this) }
    private val es = Locale("es", "ES")
    private val dateFormat = SimpleDateFormat("d MMM yyyy", es)

    private var existing: UserProfile? = null
    private var birthday: Long? = null
    private var weight: Float? = null
    private var height: Float? = null
    private var sex: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_profile)
        window.statusBarColor = Ui.color(this, R.color.w_bg_top)
        Ui.setupDetailHeader(this, "Sobre mí")

        findViewById<View>(R.id.rowBirthday).setOnClickListener { pickBirthday() }
        findViewById<View>(R.id.rowWeight).setOnClickListener {
            askNumber("Peso (kg)", weight) { weight = it; onChanged() }
        }
        findViewById<View>(R.id.rowHeight).setOnClickListener {
            askNumber("Altura (cm)", height) { height = it; onChanged() }
        }
        findViewById<View>(R.id.rowSex).setOnClickListener {
            AlertDialog.Builder(this)
                .setTitle("Sexo")
                .setItems(arrayOf("Hombre", "Mujer")) { _, i -> sex = if (i == 0) "M" else "F"; onChanged() }
                .show()
        }
        findViewById<View>(R.id.rowHrMax).setOnClickListener {
            AlertDialog.Builder(this)
                .setTitle("FC máxima")
                .setMessage("Pon la más alta que hayas visto en WHOOP o en un partido (la tuya en WHOOP: 199). " +
                    "Se usa para las zonas y el esfuerzo. Si en una actividad superas esta cifra, se actualiza sola.")
                .setPositiveButton("Escribir") { _, _ ->
                    askNumber("FC máxima (lpm)", Formulas.observedHrMax(this)?.toFloat()) {
                        val bpm = it.toInt()
                        if (bpm in 150..220) { Formulas.setObservedHrMax(this, bpm); render() }
                        else Toast.makeText(this, "Debe estar entre 150 y 220", Toast.LENGTH_SHORT).show()
                    }
                }
                .setNeutralButton("Usar la de mi edad") { _, _ -> Formulas.setObservedHrMax(this, 0); render() }
                .setNegativeButton("Cancelar", null)
                .show()
        }
        findViewById<View>(R.id.rowZoneRhr).setOnClickListener {
            AlertDialog.Builder(this)
                .setTitle("FC en reposo para zonas")
                .setMessage("Pon la misma que WHOOP en Ajustes de FC (\"FC en reposo\" de referencia; la tuya: 59). Con ella las zonas " +
                    "salen igual que en WHOOP. Vacía = automática (la media de tus noches).")
                .setPositiveButton("Escribir") { _, _ ->
                    askNumber("FC en reposo (lpm)", Formulas.manualZoneRestingHr(this)?.toFloat()) {
                        val bpm = it.toInt()
                        if (bpm in 35..100) { Formulas.setManualZoneRestingHr(this, bpm); render() }
                        else Toast.makeText(this, "Debe estar entre 35 y 100", Toast.LENGTH_SHORT).show()
                    }
                }
                .setNeutralButton("Automática") { _, _ -> Formulas.setManualZoneRestingHr(this, 0); render() }
                .setNegativeButton("Cancelar", null)
                .show()
        }
        findViewById<View>(R.id.rowAdvanced).setOnClickListener {
            startActivity(Intent(this, WhoopExperimentalActivity::class.java))
        }
        findViewById<View>(R.id.rowExportData).setOnClickListener { exportCsv() }

        lifecycleScope.launch {
            existing = db.userProfileDao().getOnce()
            existing?.let {
                birthday = it.birthdayMillis; weight = it.weightKg; height = it.heightCm; sex = it.sex
            }
            render()
        }
    }

    private fun pickBirthday() {
        val cal = Calendar.getInstance()
        birthday?.let { cal.timeInMillis = it } ?: cal.add(Calendar.YEAR, -30)
        DatePickerDialog(this, { _, y, m, d ->
            birthday = Calendar.getInstance().apply { set(y, m, d, 0, 0, 0); set(Calendar.MILLISECOND, 0) }.timeInMillis
            onChanged()
        }, cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH)).show()
    }

    private fun askNumber(title: String, current: Float?, onValue: (Float) -> Unit) {
        val input = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            setText(current?.let { if (it % 1f == 0f) it.toInt().toString() else it.toString() } ?: "")
            setSelection(text.length)
        }
        val box = FrameLayout(this).apply {
            val p = Ui.dp(this@ProfileActivity, 20f)
            setPadding(p, Ui.dp(this@ProfileActivity, 8f), p, 0)
            addView(input)
        }
        AlertDialog.Builder(this)
            .setTitle(title)
            .setView(box)
            .setPositiveButton("Guardar") { _, _ ->
                val v = input.text.toString().replace(',', '.').toFloatOrNull()
                if (v != null && v > 0f) onValue(v) else Toast.makeText(this, "Número no válido", Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton("Cancelar", null)
            .show()
    }

    private fun onChanged() {
        render()
        val b = birthday; val w = weight; val h = height; val s = sex
        if (b == null || w == null || h == null || s == null) return
        val profile = existing?.copy(birthdayMillis = b, weightKg = w, heightCm = h, sex = s)
            ?: UserProfile(birthdayMillis = b, weightKg = w, heightCm = h, sex = s)
        lifecycleScope.launch {
            db.userProfileDao().save(profile)
            existing = profile
            render()
            Toast.makeText(this@ProfileActivity, "Perfil guardado", Toast.LENGTH_SHORT).show()
        }
    }

    private fun render() {
        fun setRow(id: Int, value: String?) {
            findViewById<TextView>(id).apply {
                text = value ?: "Añadir"
                setTextColor(Ui.color(this@ProfileActivity, if (value == null) R.color.strain_blue else R.color.text_secondary))
            }
        }
        setRow(R.id.birthdayValue, birthday?.let { dateFormat.format(it) })
        setRow(R.id.weightValue, weight?.let { Ui.comma(it.toDouble(), if (it % 1f == 0f) 0 else 1) + " kg" })
        setRow(R.id.heightValue, height?.let { "%.0f cm".format(it) })
        setRow(R.id.sexValue, sex?.let { if (it == "M") "Hombre" else "Mujer" })
        setRow(R.id.hrMaxValue, Formulas.observedHrMax(this)?.let { "$it lpm" })
        findViewById<TextView>(R.id.zoneRhrValue).text = Formulas.manualZoneRestingHr(this)?.let { "$it lpm" } ?: "Automática (${Formulas.zoneRestingHr()})"

        val age: Int? = birthday?.let { ((System.currentTimeMillis() - it) / (365.25 * 24 * 3600 * 1000)).toInt() }
        findViewById<TextView>(R.id.ageValue).text = age?.toString() ?: "--"
        val w = weight; val h = height
        findViewById<TextView>(R.id.bmiValue).text =
            if (w != null && h != null && h > 0) Ui.comma(w / ((h / 100.0) * (h / 100.0))) else "--"
        findViewById<TextView>(R.id.vo2Value).text = existing?.vo2Max?.let { "%.0f".format(it) } ?: "--"

        val missing = listOf(birthday, weight, height, sex).count { it == null }
        findViewById<TextView>(R.id.profileHint).text = if (missing > 0) {
            "Completa los 4 datos para calcular calorías, zonas y VO₂ máx con precisión."
        } else "Se guarda automáticamente."

        // Zonas de FC: la FC máx real registrada o, si no hay, la de tu edad (Tanaka: 208 − 0,7 × edad)
        val zones: LinearLayout = findViewById(R.id.zonesList)
        zones.removeAllViews()
        val hrMax = Formulas.hrMax(this, age ?: 30)
        findViewById<TextView>(R.id.hrMaxText).text = "Máx. %.0f · reposo %d".format(hrMax, Formulas.zoneRestingHr()) +
            if (Formulas.observedHrMax(this) != null) "" else if (age == null) " (edad estimada)" else " (por edad)"
        // 29/10: zonas por reserva de FC, como WHOOP ("fórmula de FC de reserva"): las mismas que en las actividades
        val bounds = Formulas.zoneBounds(hrMax)
        val zoneDefs = listOf(
            Triple("Zona 5", "${bounds[4]}+", R.color.w_zone5),
            Triple("Zona 4", "${bounds[3]}–${bounds[4] - 1}", R.color.w_zone4),
            Triple("Zona 3", "${bounds[2]}–${bounds[3] - 1}", R.color.w_zone3),
            Triple("Zona 2", "${bounds[1]}–${bounds[2] - 1}", R.color.w_zone2),
            Triple("Zona 1", "${bounds[0]}–${bounds[1] - 1}", R.color.w_zone1)
        )
        zoneDefs.forEachIndexed { i, (name, range, colorRes) ->
            zones.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, Ui.dp(this@ProfileActivity, 9f), 0, Ui.dp(this@ProfileActivity, 9f))
                addView(W.title(this@ProfileActivity, name, 13.5f).apply {
                    layoutParams = LinearLayout.LayoutParams(Ui.dp(this@ProfileActivity, 64f), LinearLayout.LayoutParams.WRAP_CONTENT)
                })
                addView(Ui.progressBar(this@ProfileActivity, 1f - 0.12f * i, colorRes).apply {
                    layoutParams = LinearLayout.LayoutParams(0, Ui.dp(this@ProfileActivity, 8f), 1f)
                })
                addView(W.number(this@ProfileActivity, "$range lpm", 17f).apply {
                    gravity = Gravity.END
                    layoutParams = LinearLayout.LayoutParams(Ui.dp(this@ProfileActivity, 96f), LinearLayout.LayoutParams.WRAP_CONTENT)
                })
            })
        }
    }

    private fun exportCsv() {
        val file = java.io.File(getExternalFilesDir(null), "hr_log.csv")
        if (!file.exists()) {
            Toast.makeText(this, "Aún no hay datos guardados", Toast.LENGTH_SHORT).show()
            return
        }
        val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/csv"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, "Compartir hr_log.csv"))
    }
}
