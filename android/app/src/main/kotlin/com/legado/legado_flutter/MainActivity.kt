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
 *
 * - 下载中：系统进度条（Compat setProgress）+ 百分比文案
 * - Android 16+：附加 ProgressStyle（实况进度/Live Updates）
 * - 成功 / 失败：标题与图标明确区分，便于一眼识别
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
                    val failed = call.argument<Boolean>("failed") ?: false
                    showNotification(id, title, text, progress, max, indeterminate, done, failed)
                    result.success(true)
                }
                "showDone" -> {
                    val id = call.argument<Int>("id") ?: 1
                    val title = call.argument<String>("title") ?: "完成"
                    val text = call.argument<String>("text") ?: ""
                    val failed = call.argument<Boolean>("failed") ?: false
                    showNotification(id, title, text, 100, 100, false, true, failed)
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
                NotificationManager.IMPORTANCE_DEFAULT
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
        done: Boolean,
        failed: Boolean
    ) {
        if (!ensureNotifyPermission()) return
        ensureChannel()
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val icon = when {
            failed -> android.R.drawable.stat_notify_error
            done -> android.R.drawable.stat_sys_download_done
            else -> android.R.drawable.stat_sys_download
        }

        // Compat：确定型进度条（系统通知栏可见）
        val builder = NotificationCompat.Builder(this, channelId)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(if (failed) text else "$text（$progress%）")
            )
            .setSmallIcon(icon)
            .setContentIntent(pi)
            .setOnlyAlertOnce(true)
            .setOngoing(!done && !failed)
            .setAutoCancel(done || failed)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setColor(if (failed) 0xFFD32F2F.toInt() else 0xFF1976D2.toInt())

        if (done || failed) {
            builder.setProgress(0, 0, false)
        } else {
            builder.setProgress(
                max.coerceAtLeast(1),
                progress.coerceIn(0, max),
                indeterminate
            )
        }

        // Android 16+ 实况进度样式（附加，失败静默）
        if (Build.VERSION.SDK_INT >= 36 && !done && !failed) {
            tryLiveProgressStyle(builder, progress, max)
        }

        // 小米超级岛 / 焦点通知（实况）：miui.focus.param
        attachXiaomiFocus(builder, title, text, progress, max, done, failed)

        nm().notify(id, builder.build())
    }

    /**
     * 小米澎湃 OS 焦点通知 / 超级岛参数（dev.mi.com pId=2131）
     * 支持机型以岛/焦点形态展示下载进度；其它机型忽略该 extras。
     */
    private fun attachXiaomiFocus(
        builder: NotificationCompat.Builder,
        title: String,
        text: String,
        progress: Int,
        max: Int,
        done: Boolean,
        failed: Boolean
    ) {
        try {
            val pct = if (done || failed) 100 else progress.coerceIn(0, 100)
            val ticker = if (failed) "OCR 下载失败" else if (done) "OCR 就绪" else "OCR 下载 $pct%"
            // 进度文案放入岛/焦点，状态栏 ticker 同步
            val island = """
                {
                  "param_v2": {
                    "protocol": 1,
                    "business": "download",
                    "updatable": true,
                    "enableFloat": true,
                    "islandFirstFloat": true,
                    "ticker": ${jsonStr(ticker)},
                    "aodTitle": ${jsonStr(ticker)},
                    "param_island": {
                      "islandProperty": 1,
                      "bigIslandArea": {
                        "imageTextInfoLeft": {
                          "type": 1,
                          "textInfo": {
                            "frontTitle": ${jsonStr(title)},
                            "title": ${jsonStr(if (done || failed) ticker else "$pct%")},
                            "content": ${jsonStr(text)},
                            "useHighLight": true
                          }
                        }
                      },
                      "smallIslandArea": {
                        "picInfo": { "type": 1 }
                      }
                    },
                    "baseInfo": {
                      "title": ${jsonStr(title)},
                      "content": ${jsonStr(if (done || failed) text else "$pct% · $text")},
                      "colorTitle": "${if (failed) "#D32F2F" else "#1976D2"}",
                      "type": 2
                    },
                    "hintInfo": {
                      "type": 1,
                      "title": ${jsonStr(if (done || failed) ticker else "下载中 $pct%")}
                    }
                  }
                }
            """.trimIndent()
            builder.extras.putString("miui.focus.param", island)
        } catch (_: Throwable) {
            // 非小米机型/字段变化：忽略
        }
    }

    private fun jsonStr(s: String): String {
        val escaped = s
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "")
            .replace("\t", " ")
        return "\"$escaped\""
    }

    private fun tryLiveProgressStyle(
        compat: NotificationCompat.Builder,
        progress: Int,
        max: Int
    ) {
        try {
            val psCls = Class.forName("android.app.Notification\$ProgressStyle")
            val ps = psCls.getDeclaredConstructor().newInstance()
            psCls.getMethod("setProgressMax", Integer.TYPE)
                .invoke(ps, max.coerceAtLeast(1))
            psCls.getMethod("setProgress", Integer.TYPE)
                .invoke(ps, progress.coerceIn(0, max))
            // Compat builder 反射挂 Style（有则生效，无则仅进度条）
            compat.javaClass.methods
                .firstOrNull { it.name == "setStyle" && it.parameterTypes.size == 1 }
                ?.invoke(compat, ps)
        } catch (_: Throwable) {
            // 无 ProgressStyle 时仍显示 Compat 进度条
        }
    }
}
