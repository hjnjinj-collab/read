package com.legado.legado_flutter

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * OCR 模型下载系统通知。
 * 高版本优先走实况进度（ProgressStyle，反射调用避免编译期 SDK 依赖），
 * 否则回退 NotificationCompat 进度条。
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
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Android 16+ 实况进度（反射，避免 compileSdk 依赖）
        if (Build.VERSION.SDK_INT >= 36 && !done && tryLiveProgress(id, title, text, progress, max, pi)) {
            return
        }

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
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        if (done) {
            b.setProgress(0, 0, false)
        } else {
            b.setProgress(max.coerceAtLeast(1), progress.coerceIn(0, max), indeterminate)
        }
        nm().notify(id, b.build())
    }

    /** 成功则返回 true */
    private fun tryLiveProgress(
        id: Int, title: String, text: String,
        progress: Int, max: Int, pi: PendingIntent
    ): Boolean {
        return try {
            val psCls = Class.forName("android.app.Notification\$ProgressStyle")
            val ps = psCls.getDeclaredConstructor().newInstance()
            psCls.getMethod("setProgressMax", Integer.TYPE)
                .invoke(ps, max.coerceAtLeast(1))
            if (progress >= 0) {
                psCls.getMethod("setProgress", Integer.TYPE)
                    .invoke(ps, progress.coerceIn(0, max))
            }
            val nCls = android.app.Notification::class.java
            val builderCls = Class.forName("android.app.Notification\$Builder")
            val builder = builderCls
                .getDeclaredConstructor(Context::class.java, String::class.java)
                .newInstance(this, channelId)
            builderCls.getMethod("setContentTitle", CharSequence::class.java)
                .invoke(builder, title as CharSequence)
            builderCls.getMethod("setContentText", CharSequence::class.java)
                .invoke(builder, text as CharSequence)
            builderCls.getMethod("setSmallIcon", Integer.TYPE)
                .invoke(builder, android.R.drawable.stat_sys_download)
            builderCls.getMethod("setContentIntent", PendingIntent::class.java)
                .invoke(builder, pi)
            builderCls.getMethod("setOngoing", Boolean::class.javaPrimitiveType)
                .invoke(builder, false)
            builderCls.getMethod("setStyle", Class.forName("android.app.Notification\$Style"))
                .invoke(builder, ps)
            val n = builderCls.getMethod("build").invoke(builder) as android.app.Notification
            nm().notify(id, n)
            true
        } catch (_: Throwable) {
            false
        }
    }
}
