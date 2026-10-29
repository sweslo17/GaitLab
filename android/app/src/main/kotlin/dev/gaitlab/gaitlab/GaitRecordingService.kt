package dev.gaitlab.gaitlab

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** Keeps the existing Flutter sensor stream alive. This service does not read sensors. */
class GaitRecordingService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var foreground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_REQUEST_STOP) {
            if (!isActive) {
                // A stale action must not start a new recording or leave an idle service.
                stop(this)
                return START_NOT_STICKY
            }
            val callback = onStopRequested
            if (callback != null) {
                // Dart saves the session before it calls the normal stop method.
                callback()
            } else {
                // No Flutter engine remains to save or stop this recording.
                stop(this)
            }
            return START_NOT_STICKY
        }
        val token = intent?.getLongExtra(EXTRA_TOKEN, -1L)
        if (token != requestedToken || pendingStart == null) {
            if (!isActive && pendingStart == null) stopSelf(startId)
            return START_NOT_STICKY
        }
        try {
            val notification = createNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            foreground = true
            wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GaitLab:Recording")
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
            check(isActive) { "The recording CPU lock is not active" }
            completeStart(null)
        } catch (error: Exception) {
            releaseResources()
            completeStart(error)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun createNotification(): Notification {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "動作感測錄製", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val openApp = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val requestStop = PendingIntent.getService(
            this, 1,
            Intent(this, GaitRecordingService::class.java).setAction(ACTION_REQUEST_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_recording)
            .setContentTitle("GaitLab 正在錄製")
            .setContentText("點此開啟 GaitLab，按「停止並儲存」結束。")
            .setContentIntent(openApp)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(Notification.PRIORITY_LOW)
            .addAction(Notification.Action.Builder(R.drawable.ic_recording, "停止並儲存", requestStop).build())
            .build()
    }

    private fun releaseResources() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        foreground = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stop(this)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseResources()
        if (instance === this) {
            instance = null
            completeStart(IllegalStateException("The recording service stopped during startup"))
        }
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "gaitlab_recording"
        private const val NOTIFICATION_ID = 1042
        private const val EXTRA_TOKEN = "recording_start_token"
        private const val ACTION_REQUEST_STOP = "dev.gaitlab.gaitlab.REQUEST_RECORDING_STOP"
        private var instance: GaitRecordingService? = null
        private var requestedToken = 0L
        private var pendingStart: ((Throwable?) -> Unit)? = null
        var onStopRequested: (() -> Unit)? = null

        // All calls and service lifecycle callbacks run on Android's main thread.
        val isActive: Boolean
            get() = instance?.let { it.foreground && it.wakeLock?.isHeld == true } == true

        fun start(context: Context, callback: (Throwable?) -> Unit) {
            if (isActive) {
                callback(null)
                return
            }
            check(pendingStart == null) { "A recording service start is already pending" }
            pendingStart = callback
            requestedToken++
            try {
                val intent = Intent(context, GaitRecordingService::class.java)
                    .putExtra(EXTRA_TOKEN, requestedToken)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                instance?.releaseResources()
                context.stopService(Intent(context, GaitRecordingService::class.java))
                completeStart(error)
            }
        }

        fun stop(context: Context) {
            // Invalidate queued start intents before Android delivers them.
            requestedToken++
            instance?.releaseResources()
            context.stopService(Intent(context, GaitRecordingService::class.java))
            completeStart(IllegalStateException("The recording service start was cancelled"))
        }

        private fun completeStart(error: Throwable?) {
            val callback = pendingStart
            pendingStart = null
            callback?.invoke(error)
        }
    }
}
