package com.vibplus.vib_alert

import android.app.*
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.*
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

class IncomingAlertService : Service() {
    companion object {
        const val CHANNEL_ID = "vib_urgent_opportunities_v2"
        const val ACTION_START = "com.vibplus.vib_alert.START_ALERT"
        const val ACTION_STOP = "com.vibplus.vib_alert.STOP_ALERT"
        const val ACTION_ACCEPT = "com.vibplus.vib_alert.ACCEPT_ALERT"
        const val ACTION_REFUSE = "com.vibplus.vib_alert.REFUSE_ALERT"
        private const val NOTIFICATION_ID = 9401

        fun start(context: Context, data: Map<String, String>) {
            val intent = Intent(context, IncomingAlertService::class.java).apply {
                action = ACTION_START
                data.forEach { (key, value) -> putExtra(key, value) }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, IncomingAlertService::class.java))
        }
    }

    private var mediaPlayer: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private val handler = Handler(Looper.getMainLooper())
    private val timeoutRunnable = Runnable { stopSelf() }

    override fun onCreate() {
        super.onCreate()
        createUrgentChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        val data = mutableMapOf<String, String>()
        intent?.extras?.keySet()?.forEach { key ->
            data[key] = intent.extras?.get(key)?.toString().orEmpty()
        }

        startForeground(NOTIFICATION_ID, buildNotification(data))
        startSoundAndVibration()
        handler.removeCallbacks(timeoutRunnable)
        handler.postDelayed(timeoutRunnable, 120_000L)
        return START_NOT_STICKY
    }

    private fun createUrgentChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Alertes VIB type appel",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Alertes critiques VIB avec sonnerie et vibration continues."
            enableLights(true)
            lightColor = Color.RED
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 700, 350, 700, 350)
            setSound(ringtoneUri, attributes)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setBypassDnd(true)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    private fun buildNotification(data: Map<String, String>): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("vib_alert_open", "1")
            data.forEach { (key, value) -> putExtra(key, value) }
        }
        val fullScreenPendingIntent = PendingIntent.getActivity(
            this,
            9401,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        fun actionPendingIntent(action: String, requestCode: Int): PendingIntent {
            val actionIntent = Intent(this, AlertActionReceiver::class.java).apply {
                this.action = action
                data.forEach { (key, value) -> putExtra(key, value) }
            }
            return PendingIntent.getBroadcast(
                this,
                requestCode,
                actionIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        val title = data["title"].takeUnless { it.isNullOrBlank() } ?: "VIB Alert — Opportunité"
        val body = data["body"].takeUnless { it.isNullOrBlank() }
            ?: "Une opportunité urgente est disponible."

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setTimeoutAfter(120_000L)
            .setContentIntent(fullScreenPendingIntent)
            .setFullScreenIntent(fullScreenPendingIntent, true)
            .addAction(0, "REFUSER", actionPendingIntent(ACTION_REFUSE, 9402))
            .addAction(0, "ACCEPTER", actionPendingIntent(ACTION_ACCEPT, 9403))
            .build()
    }

    private fun startSoundAndVibration() {
        if (mediaPlayer?.isPlaying != true) {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            mediaPlayer = MediaPlayer().apply {
                setDataSource(applicationContext, uri)
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                isLooping = true
                prepare()
                start()
            }
        }

        vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        val pattern = longArrayOf(0, 700, 350, 700, 350)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))
        } else {
            @Suppress("DEPRECATION")
            vibrator?.vibrate(pattern, 0)
        }
    }

    private fun stopSoundAndVibration() {
        try { mediaPlayer?.stop() } catch (_: Exception) {}
        try { mediaPlayer?.release() } catch (_: Exception) {}
        mediaPlayer = null
        try { vibrator?.cancel() } catch (_: Exception) {}
        vibrator = null
    }

    override fun onDestroy() {
        handler.removeCallbacks(timeoutRunnable)
        stopSoundAndVibration()
        NotificationManagerCompat.from(this).cancel(NOTIFICATION_ID)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
