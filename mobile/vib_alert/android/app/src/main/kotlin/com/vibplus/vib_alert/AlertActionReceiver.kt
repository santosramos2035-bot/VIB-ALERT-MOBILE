package com.vibplus.vib_alert

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class AlertActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        IncomingAlertService.stop(context)
        val launch = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("vib_alert_open", "1")
            putExtra("vib_alert_action", when (intent.action) {
                IncomingAlertService.ACTION_ACCEPT -> "accept"
                IncomingAlertService.ACTION_REFUSE -> "refuse"
                else -> "open"
            })
            intent.extras?.keySet()?.forEach { key -> putExtra(key, intent.extras?.get(key)?.toString().orEmpty()) }
        }
        context.startActivity(launch)
    }
}
