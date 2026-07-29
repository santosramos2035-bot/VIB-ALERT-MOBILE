package com.vibplus.vib_alert

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "vib_alert/full_screen"
    private var pendingAlertData: HashMap<String, String>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureAlertIntent(intent)
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
    }

    private fun captureAlertIntent(intent: Intent?) {
        if (intent?.getStringExtra("vib_alert_open") != "1") return
        val data = hashMapOf<String, String>()
        intent.extras?.keySet()?.forEach { key ->
            data[key] = intent.extras?.get(key)?.toString().orEmpty()
        }
        pendingAlertData = data
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureAlertIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
            when (call.method) {
                "openFullScreenPermission" -> {
                    if (Build.VERSION.SDK_INT >= 34) {
                        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        if (!manager.canUseFullScreenIntent()) {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                    Uri.parse("package:$packageName")
                                )
                            )
                        }
                    }
                    result.success(true)
                }
                "getInitialAlert" -> {
                    val data = pendingAlertData
                    pendingAlertData = null
                    result.success(data)
                }
                "startIncomingAlert" -> {
                    IncomingAlertService.start(
                        applicationContext,
                        mapOf("title" to "VIB Alert", "body" to "Alerte urgente")
                    )
                    result.success(true)
                }
                "stopIncomingAlert" -> {
                    IncomingAlertService.stop(applicationContext)
                    result.success(true)
                }
                "openPwa" -> {
                    val url = call.argument<String>("url").orEmpty()
                    if (url.startsWith("https://send.vibplus.com/")) {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                        result.success(true)
                    } else {
                        result.error("INVALID_URL", "Adresse PWA non autorisée.", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
