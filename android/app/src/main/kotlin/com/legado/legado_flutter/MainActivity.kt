package com.legado.legado_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * OCR 模型下载：系统通知。
 * Android 16+ 使用 [Notification.ProgressStyle]（谷歌实况进度/Live Updates），
 * 低版本回退 NotificationCompat 确定型进度条。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "legado/notify"
    private var channelId = "ocr_download"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "showProgress" -> {
                    val id = call.argument<Int>("id") ?: 1
                    val title = call.argument<String>("title") ?: "下载"
                    val text = call.argument<String>("text") ?: ""
                    val progress = call.argument<Int>("progress") ?: 0
                    val max = call.argument<Int>("max") ?: 100
                    val indeterminate = call.argument<Boolean>("indeterminate") ?: false
                    val done = call.argument<Boolean>("done") ?: false
                    showNotification(id, title, text, progress, max, indeterminate, done)
                    result.success(true)
                }
                "showDone" -> {
                    val id = call.argument<Int>("id") ?: 1
                    val title = call.argument<String>("title") ?: "完成"
                    val text = call.argument<String>("text") ?: ""
                    showNotification(id, title, text, 100, 100, false, true)
                    result.success(true)
                }
                "cancel" -> {
                    val id = call.argument<Int>("id") ?: 1
                    nm().cancel(id)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun nm(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                channelId,
                "OCR 模型下载",
                NotificationManager.IMPORTANCE_LOW
            )
            // 实况进度：允许频繁更新
            ch.setSound(null, null)
            nm().createNotificationChannel(ch)
        }
    }

    private fun ensureNotifyPermission(): Boolean {
        if (Build.VERSION.SDK_INT >= 33) {
            val granted = ContextCompat.checkSelfPermission(
                this, android.Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                    1001
                )
                return false
            }
        }
        return true
    }

    private fun showNotification(
        id: Int,
        title: String,
        text: String,
        progress: Int,
        max: Int,
        indeterminate: Boolean,
        done: Boolean
    ) {
        if (!ensureNotifyPermission()) return
        ensureChannel()
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Android 16+：Notification.ProgressStyle（谷歌实况进度）
        if (Build.VERSION.SDK_INT >= 36) {
            val builder = Notification.Builder(this, channelId)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(
                    if (done) android.R.drawable.stat_sys_download_done
                    else android.R.drawable.stat_sys_download
                )
                .setContentIntent(pi)
                .setOnlyAlertOnce(true)
                .setOngoing(!done)
            if (!done) {
                val ps = Notification.ProgressStyle()
                    .setProgressMax(max.coerceAtLeast(1))
                if (indeterminate) {
                    // 无总长：实况不确定进度
                    builder.setStyle(ps)
                } else {
                    builder.setStyle(ps.setProgress(progress.coerceIn(0, max)))
                }
            }
            nm().notify(id, builder.build())
            return
        }

        // 回退：Compat 进度条
        val b = NotificationCompat.Builder(this, channelId)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(
                if (done) android.R.drawable.stat_sys_download_done
                else android.R.drawable.stat_sys_download
            )
            .setContentIntent(pi)
            .setOnlyAlertOnce(true)
            .setOngoing(!done)
            .setPriority(NotificationCompat.PRIORITY_LOW)
        if (done) {
            b.setProgress(0, 0, false)
        } else {
            b.setProgress(max.coerceAtLeast(1), progress.coerceIn(0, max), indeterminate)
        }
        NotificationManagerCompat.from(this).notify(id, b.build())
    }
}
