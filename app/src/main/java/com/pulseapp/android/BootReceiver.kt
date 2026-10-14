package com.pulseapp.android

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Al encender el móvil (o actualizar la app) vuelve a conectar con la WHOOP, como hace la app de WHOOP. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (!WhoopBackgroundService.autoConnectEnabled(context)) return
        if (WhoopBackgroundService.findBondedWhoop(context) == null) return
        WhoopBackgroundService.start(context)
    }
}
