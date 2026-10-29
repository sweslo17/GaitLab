package dev.gaitlab.gaitlab

import android.Manifest
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private val pendingStarts = mutableListOf<MethodChannel.Result>()
    private var channel: MethodChannel? = null
    private var visible = false
    private var destroyed = false
    private var permissionPending = false
    private val startupTimeout = Runnable {
        finishStarts("recording_start_timeout", "錄製服務啟動逾時，請重新開始。")
        GaitRecordingService.stop(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gaitlab/recording").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> startRecording(result)
                    "stop" -> {
                        finishStarts("recording_start_cancelled", "錄製啟動已取消。")
                        GaitRecordingService.stop(this)
                        result.success(null)
                    }
                    "isActive" -> result.success(GaitRecordingService.isActive)
                    else -> result.notImplemented()
                }
            }
        }
        GaitRecordingService.onStopRequested = {
            channel?.invokeMethod("stopRequested", null)
        }
    }

    override fun onStart() {
        super.onStart()
        visible = true
    }

    override fun onStop() {
        visible = false
        // Screen off and app backgrounding do not stop an established recording.
        super.onStop()
    }

    private fun startRecording(result: MethodChannel.Result) {
        if (destroyed || !visible) {
            result.error("recording_not_visible", "請先開啟 GaitLab，再開始錄製。", null)
            return
        }
        if (GaitRecordingService.isActive) {
            result.success(startState())
            return
        }
        pendingStarts.add(result)
        if (pendingStarts.size > 1) return
        handler.postDelayed(startupTimeout, 60_000)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            !permissionPending
        ) {
            permissionPending = true
            try {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_REQUEST)
            } catch (error: Exception) {
                permissionPending = false
                finishStarts("recording_permission_failed", error.message ?: "無法要求通知權限。")
            }
        } else if (!permissionPending) {
            startServiceForRecording()
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_REQUEST) return
        permissionPending = false
        if (pendingStarts.isNotEmpty() && !destroyed) startServiceForRecording()
    }

    private fun startServiceForRecording() {
        if (!visible || destroyed) {
            finishStarts("recording_not_visible", "請先開啟 GaitLab，再開始錄製。")
            return
        }
        // Allow the permission dialog more time, but bound service startup itself.
        handler.removeCallbacks(startupTimeout)
        handler.postDelayed(startupTimeout, 8_000)
        try {
            GaitRecordingService.start(this) { error ->
                if (error == null && GaitRecordingService.isActive) {
                    finishStarts()
                } else {
                    finishStarts("recording_start_failed", error?.message ?: "錄製服務未啟動。")
                }
            }
        } catch (error: Exception) {
            GaitRecordingService.stop(this)
            finishStarts("recording_start_failed", error.message ?: "錄製服務未啟動。")
        }
    }

    private fun startState(): Map<String, Boolean> {
        val allowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).areNotificationsEnabled()
        } else {
            true
        }
        return mapOf("active" to GaitRecordingService.isActive, "notifications_allowed" to allowed)
    }

    private fun finishStarts(code: String? = null, message: String? = null) {
        handler.removeCallbacks(startupTimeout)
        val results = pendingStarts.toList()
        pendingStarts.clear()
        for (result in results) {
            if (code == null) result.success(startState()) else result.error(code, message, null)
        }
    }

    override fun onDestroy() {
        destroyed = true
        visible = false
        GaitRecordingService.onStopRequested = null
        finishStarts("recording_activity_destroyed", "GaitLab 已關閉，錄製服務已停止。")
        GaitRecordingService.stop(this)
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }

    companion object {
        private const val NOTIFICATION_REQUEST = 1042
    }
}
