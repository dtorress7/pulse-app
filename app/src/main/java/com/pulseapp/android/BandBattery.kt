package com.pulseapp.android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * Batería de la pulsera (31/10, igual que iOS `Core/BandBattery.swift`). La WHOOP 5.0 manda sola el EVENTO 3 (tipo 48, [10] = 3)
 * ~cada 14 min: [12..15] hora unix, [21..22] u16 = nivel en décimas de % (997 = 99,7 %), [25..26] u16 = tensión en mV.
 * Comprobado con el historial crudo del 18–22/10: el nivel solo baja (99,7 → 50,6 % en 4 días) y sigue a la tensión (r 0,999).
 * Carga: eventos 7/8, 5/6 y 21/22 (numeración de WHOOP que cuadra con nuestros datos en 3, 11/12 y 16; aún sin verlos) o si el nivel sube.
 */
object BandBattery {
    private const val PREFS = "pulseapp_band_battery"
    private const val CHANNEL = "pulseapp_avisos"
    @Volatile var onChange: (() -> Unit)? = null

    data class State(val tenths: Int, val mv: Int, val unix: Long, val charging: Boolean)

    fun current(ctx: Context): State? {
        val sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val t = sp.getInt("tenths", -1); if (t < 0) return null
        return State(t, sp.getInt("mv", 0), sp.getLong("unix", 0), sp.getBoolean("charging", false))
    }

    /** Porcentaje entero (null si no hay dato de las últimas 24 h). */
    fun percent(ctx: Context): Int? {
        val s = current(ctx) ?: return null
        if (System.currentTimeMillis() / 1000 - s.unix > 86_400) return null
        return Math.round(s.tenths / 10.0).toInt()
    }
    fun isCharging(ctx: Context): Boolean = percent(ctx) != null && current(ctx)?.charging == true

    private fun save(ctx: Context, s: State) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putInt("tenths", s.tenths).putInt("mv", s.mv).putLong("unix", s.unix).putBoolean("charging", s.charging).apply()
        onChange?.invoke()
    }

    /** Evento de la pulsera (tipo 48). Devuelve un texto para el registro si cambió algo. */
    fun handleEvent(ctx: Context, frame: ByteArray): String? {
        if (frame.size <= 10) return null
        val id = frame[10].toInt() and 0xFF
        val u16 = { o: Int -> (frame[o].toInt() and 0xFF) or ((frame[o + 1].toInt() and 0xFF) shl 8) }
        val prev = current(ctx)
        when (id) {
            3 -> {
                if (frame.size < 27) return null
                val unix = (frame[12].toLong() and 0xFF) or ((frame[13].toLong() and 0xFF) shl 8) or
                    ((frame[14].toLong() and 0xFF) shl 16) or ((frame[15].toLong() and 0xFF) shl 24)
                val tenths = u16(21); val mv = u16(25)
                if (tenths > 1000 || mv < 2500 || mv > 4600) return null
                var charging = prev?.charging ?: false
                if (prev != null && unix > prev.unix && unix - prev.unix < 7200) {
                    if (tenths > prev.tenths + 2 || mv > prev.mv + 20) charging = true
                    else if (tenths < prev.tenths) charging = false
                }
                val s = State(tenths, mv, maxOf(unix, prev?.unix ?: 0), charging)
                save(ctx, s); checkLow(ctx, s)
                return "🔋 Batería de la pulsera: ${"%.1f".format(java.util.Locale.US, tenths / 10.0)} % ($mv mV)" + if (charging) " · cargando" else ""
            }
            5, 7, 21 -> {
                save(ctx, (prev ?: State(-1, 0, 0, false)).copy(charging = true, unix = maxOf(prev?.unix ?: 0, System.currentTimeMillis() / 1000)))
                ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("low_notified", false).apply()
                return "🔌 Evento $id: la pulsera empieza a cargar"
            }
            6, 8, 22 -> {
                if (prev != null) save(ctx, prev.copy(charging = false))
                return "🔌 Evento $id: la pulsera deja de cargar"
            }
        }
        return null
    }

    /** Aviso de batería baja: una vez al bajar del 20 % (se rearma al cargar o al pasar del 25 %). */
    private fun checkLow(ctx: Context, s: State) {
        val sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val notified = sp.getBoolean("low_notified", false)
        if (s.charging || s.tenths >= 250) { if (notified) sp.edit().putBoolean("low_notified", false).apply(); return }
        if (s.tenths < 200 && !notified) {
            sp.edit().putBoolean("low_notified", true).apply()
            notify(ctx, 2001, "Recordatorio de carga de batería",
                "La batería de tu WHOOP está a menos del 20 % (${Math.round(s.tenths / 10.0)} %). Cárgala.")
        }
    }

    /** Notificación normal de PulseApp (canal "Avisos"). */
    fun notify(ctx: Context, id: Int, title: String, body: String) {
        try {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel(CHANNEL, "Avisos", NotificationManager.IMPORTANCE_DEFAULT))
            val n = NotificationCompat.Builder(ctx, CHANNEL).setSmallIcon(R.drawable.ic_band)
                .setContentTitle(title).setContentText(body).setStyle(NotificationCompat.BigTextStyle().bigText(body)).setAutoCancel(true).build()
            nm.notify(id, n)
        } catch (_: SecurityException) { }
    }
}
