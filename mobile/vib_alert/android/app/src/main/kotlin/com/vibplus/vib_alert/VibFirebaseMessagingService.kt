package com.vibplus.vib_alert

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class VibFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data.toMutableMap()
        message.notification?.title?.let { data["title"] = it }
        message.notification?.body?.let { data["body"] = it }
        IncomingAlertService.start(applicationContext, data)
    }
}
