package com.vibplus.vib_alert

import android.util.Log
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class VibFirebaseMessagingService : FirebaseMessagingService() {

    companion object {
        private const val TAG = "VIB_ALERT"
    }

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "FirebaseMessagingService démarré")
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)

        Log.i(TAG, "Nouveau token Firebase reçu")

        try {
            FirebaseMessaging.getInstance().token
        } catch (_: Exception) {
        }
    }

    override fun onDeletedMessages() {
        super.onDeletedMessages()

        Log.w(
            TAG,
            "Firebase indique que des messages ont été supprimés."
        )
    }

    override fun onMessageReceived(message: RemoteMessage) {

        Log.i(
            TAG,
            "Notification Firebase reçue"
        )

        val data = message.data.toMutableMap()

        message.notification?.title?.let {
            data["title"] = it
        }

        message.notification?.body?.let {
            data["body"] = it
        }

        if (!data.containsKey("received_at")) {
            data["received_at"] =
                System.currentTimeMillis().toString()
        }

        try {

            IncomingAlertService.start(
                applicationContext,
                data
            )

            Log.i(
                TAG,
                "IncomingAlertService démarré"
            )

        } catch (e: Exception) {

            Log.e(
                TAG,
                "Erreur démarrage IncomingAlertService",
                e
            )

        }

    }
}
