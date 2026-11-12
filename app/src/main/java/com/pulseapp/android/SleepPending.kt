package com.pulseapp.android

import android.content.Context

/**
 * 11/11: "Sueño detectado" como WHOOP. Al despertar, WHOOP no enseña sueño/recuperación/esfuerzo hasta que procesas el sueño
 * ("FIN DEL SUEÑO" o "PROCESO") o lo procesa sola más tarde. PulseApp igual: tras despertar (≥ 5 min sin dormir) los anillos
 * quedan en "--" hasta que pulsas, o solos a las 2 h (PROVISIONAL: WHOOP seguía pendiente 1 h después de despertar el 11/11;
 * falta saber cuándo lo hace sola). Procesar no cambia las cuentas: solo enseña lo que ya está calculado.
 * iOS: Core/SleepPending.swift (mismas reglas).
 */
object SleepPending {
    private const val PREFS = "pulseapp_sleep_processed"
    /** 12/11: 5 min → 0. Al abrir la app nada más despertar (fin de la noche hace < 5 min) salían los números y luego la tarjeta. */
    const val MIN_AWAKE_MS = 0L
    const val AUTO_MS = 120 * 60_000L

    private fun p(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    fun processed(ctx: Context, date: String) = p(ctx).getBoolean(date, false)
    fun markProcessed(ctx: Context, date: String) = p(ctx).edit().putBoolean(date, true).apply()

    /** [date] = día en que acaba la noche (yyyy-MM-dd); [sleepEnd] = fin de la noche (ms). */
    fun isPending(ctx: Context, date: String, sleepEnd: Long?, now: Long = System.currentTimeMillis()): Boolean =
        sleepEnd != null && !processed(ctx, date) && now - sleepEnd in MIN_AWAKE_MS until AUTO_MS
}
