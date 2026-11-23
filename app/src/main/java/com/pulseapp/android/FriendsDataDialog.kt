package com.pulseapp.android

import android.content.Intent
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Más → "Datos de amigos" (solo el administrador) y "Enviar mis datos para calibrar" (23/11, ver DataShare). */
object FriendsDataDialog {

    fun shareSettings(a: AppCompatActivity) {
        val on = DataShare.enabled(a)
        val last = DataShare.lastUpload(a)
        val lastTxt = if (last > 0) SimpleDateFormat("dd/MM HH:mm", Locale.getDefault()).format(Date(last)) else "nunca"
        AlertDialog.Builder(a)
            .setTitle("Enviar mis datos para calibrar")
            .setMessage("Tu pulso, movimiento y pasos de la pulsera se envían a una carpeta privada que solo puede ver quien " +
                "administra PulseApp, para ajustar los cálculos a tu WHOOP. Se manda solo lo nuevo, como mucho cada 3 horas.\n\n" +
                "Estado: ${if (on) "activado" else "desactivado"} · último envío: $lastTxt")
            .setPositiveButton(if (on) "Desactivar" else "Activar") { _, _ ->
                DataShare.setEnabled(a, !on)
                if (!on) DataShare.maybeUpload(a, force = true)
            }
            .setNeutralButton("Enviar ahora") { _, _ ->
                DataShare.setEnabled(a, true); DataShare.maybeUpload(a, force = true)
                Toast.makeText(a, "Enviando en segundo plano…", Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton("Cerrar", null)
            .show()
    }

    fun open(a: AppCompatActivity) {
        val wait = AlertDialog.Builder(a).setTitle("Datos de amigos").setMessage("Conectando…").setCancelable(false).show()
        a.lifecycleScope.launch {
            try {
                if (!DataShare.isAdmin(a)) {
                    wait.dismiss()
                    AlertDialog.Builder(a).setTitle("Datos de amigos")
                        .setMessage("Solo el administrador puede ver los datos de los demás. Si eres tú y aún no hay administrador, pulsa «Hacerme administrador» (solo funciona la primera vez).")
                        .setPositiveButton("Hacerme administrador") { _, _ ->
                            a.lifecycleScope.launch {
                                val ok = runCatching { DataShare.claimAdmin(a) }.getOrElse { false }
                                Toast.makeText(a, if (ok) "Ya eres el administrador" else "Ya hay otro administrador", Toast.LENGTH_LONG).show()
                                if (ok) open(a)
                            }
                        }
                        .setNegativeButton("Cerrar", null).show()
                    return@launch
                }
                val people = DataShare.people(a)
                wait.dismiss()
                if (people.isEmpty()) {
                    AlertDialog.Builder(a).setTitle("Datos de amigos").setMessage("Todavía nadie ha enviado datos.")
                        .setPositiveButton("Cerrar", null).show()
                    return@launch
                }
                val fmt = SimpleDateFormat("dd/MM HH:mm", Locale.getDefault())
                val labels = people.map { p ->
                    "${p.name}${if (p.platform.isNotEmpty()) " (${p.platform})" else ""} · ${if (p.updated > 0) fmt.format(Date(p.updated)) else "–"}"
                }.toTypedArray()
                AlertDialog.Builder(a).setTitle("¿De quién?")
                    .setItems(labels) { _, i -> download(a, people[i]) }
                    .setNegativeButton("Cerrar", null).show()
            } catch (e: Exception) {
                wait.dismiss()
                Toast.makeText(a, e.message ?: "No se pudo conectar", Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun download(a: AppCompatActivity, p: DataShare.Person) {
        val dlg = AlertDialog.Builder(a).setTitle(p.name).setMessage("Descargando…").setCancelable(false).show()
        a.lifecycleScope.launch {
            try {
                val files = withContext(Dispatchers.IO) {
                    DataShare.download(a, p) { msg -> a.runOnUiThread { dlg.setMessage("Descargando $msg") } }
                }
                dlg.dismiss()
                if (files.isEmpty()) { Toast.makeText(a, "No hay archivos de ${p.name}", Toast.LENGTH_LONG).show(); return@launch }
                val uris = ArrayList(files.map { FileProvider.getUriForFile(a, "${a.packageName}.fileprovider", it) })
                val intent = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                    type = "text/csv"
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                a.startActivity(Intent.createChooser(intent, "Archivos de ${p.name}"))
            } catch (e: Exception) {
                dlg.dismiss()
                Toast.makeText(a, e.message ?: "No se pudo descargar", Toast.LENGTH_LONG).show()
            }
        }
    }
}
