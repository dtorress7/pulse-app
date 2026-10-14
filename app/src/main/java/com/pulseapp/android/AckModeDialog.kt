package com.pulseapp.android

import android.app.Activity
import androidx.appcompat.app.AlertDialog

/**
 * La pulsera guarda ~14 días. Para entregar TODO el historial hay que confirmarle cada bloque, y lo confirmado
 * lo da por entregado: la app de WHOOP ya no podrá descargar ese trozo. Por eso lo decide el usuario.
 */
object AckModeDialog {
    fun label(mode: Int) = when (mode) {
        1 -> "Historial: PulseApp descarga todo"
        0 -> "Historial: WHOOP conserva los datos"
        else -> "Historial: elegir quién se queda los datos"
    }

    fun show(activity: Activity, onDone: (() -> Unit)? = null) {
        AlertDialog.Builder(activity)
            .setTitle("¿Quién se queda el historial de la pulsera?")
            .setMessage(
                "Cuando dejas el móvil en el vestuario, la pulsera guarda el entreno y luego lo entrega por bloques.\n\n" +
                "• PulseApp descarga todo: recuperas el entreno completo (esfuerzo, zonas, pulso). La pulsera da por " +
                "entregados esos bloques, así que la app de WHOOP NO los tendrá.\n\n" +
                "• WHOOP conserva los datos: PulseApp solo recibe el primer bloque de cada descarga y la app de WHOOP " +
                "lo sigue teniendo todo para comparar.\n\n" +
                "Puedes cambiarlo cuando quieras en Mi WHOOP."
            )
            .setPositiveButton("PulseApp descarga todo") { _, _ ->
                WhoopBackgroundService.setAckMode(activity, 1)
                WhoopBackgroundService.log("⚙️ Modo historial: PulseApp descarga todo")
                if (WhoopBackgroundService.isRunning) WhoopBackgroundService.start(activity, WhoopBackgroundService.ACTION_HISTORY)
                onDone?.invoke()
            }
            .setNegativeButton("WHOOP conserva los datos") { _, _ ->
                WhoopBackgroundService.setAckMode(activity, 0)
                WhoopBackgroundService.log("⚙️ Modo historial: WHOOP conserva los datos")
                onDone?.invoke()
            }
            .setCancelable(true)
            .show()
    }
}
