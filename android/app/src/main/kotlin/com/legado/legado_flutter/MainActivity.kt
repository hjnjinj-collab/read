package com.legado.legado_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * OCR 模型下载系统通知 + 小米超级岛（客户端路径）。
 *
 * 超级岛按 dev.mi.com pId=2131「客户端实现」：
 * - 原生通知 + extras `miui.focus.param`（param_v2 岛 JSON）
 * - 图片经 `miui.focus.pics`（Icon）引用
 * - **必须在 builder.build() 之后**写入 notification.extras
 *
 * 非小米 / 无焦点权限 / 查询失败：静默退回普通通知，不阻断下载链路。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "legado/notify"
    private var channelId = "ocr_download"
    private val keysChannelName = "legado/keys"
    private var keysChannel: MethodChannel? = null
    /** 音量键翻页：仅阅读页且用户开启时拦截 */
    private var volumePageTurnEnabled = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> {
                    ensureNotifyPermission()
                    result.success(true)
                }
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
                    // 完成态 5s 后自动取消（cancel 即收岛，文档第七节）
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        try { nm().cancel(id) } catch (_: Throwable) {}
                    }, 5000)
                    result.success(true)
                }
                "cancel" -> {
                    val id = call.argument<Int>("id") ?: 1
                    nm().cancel(id)
                    result.success(true)
                }
                "islandSupport" -> {
                    result.success(islandSupportJson())
                }
                else -> result.notImplemented()
            }
        }
        // 音量键翻页通道：Dart 下发 enabled，原生按键事件回推
        keysChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            keysChannelName
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setEnabled" -> {
                        volumePageTurnEnabled = call.argument<Boolean>("enabled") ?: false
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** 音量键=翻页（仅 enabled 时拦截，否则走系统音量） */
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        if (volumePageTurnEnabled && event.action == android.view.KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                android.view.KeyEvent.KEYCODE_VOLUME_UP -> {
                    keysChannel?.invokeMethod("volumeUp", null)
                    return true
                }
                android.view.KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    keysChannel?.invokeMethod("volumeDown", null)
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun nm(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                channelId,
                "OCR 模型下载",
                NotificationManager.IMPORTANCE_HIGH
            )
            ch.setSound(null, null)
            ch.enableVibration(false)
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
                // 不 return false：仍尝试 notify（部分 ROM 仍可显示）
            }
        }
        return true
    }

    // ===== 超级岛能力查询（dev.mi.com pId=2131 第五节）=====

    /** persist.sys.feature.island：是否支持岛 */
    private fun isSupportIsland(): Boolean {
        return try {
            val clazz = Class.forName("android.os.SystemProperties")
            val method = clazz.getDeclaredMethod(
                "getBoolean", String::class.java, Boolean::class.javaPrimitiveType
            )
            val v = method.invoke(null, "persist.sys.feature.island", false)
            (v as? Boolean) ?: false
        } catch (_: Throwable) {
            false
        }
    }

    /** notification_focus_protocol：0=无 1=OS1 2=OS2 3=OS3（岛） */
    private fun focusProtocolVersion(): Int {
        return try {
            android.provider.Settings.System.getInt(
                contentResolver, "notification_focus_protocol", 0
            )
        } catch (_: Throwable) {
            0
        }
    }

    /** 焦点通知权限（用户设置里是否打开） */
    private fun hasFocusPermission(): Boolean {
        return try {
            val uri = Uri.parse("content://miui.statusbar.notification.public")
            val extras = Bundle().apply { putString("package", packageName) }
            val bundle = contentResolver.call(uri, "canShowFocus", null, extras)
            bundle?.getBoolean("canShowFocus", false) ?: false
        } catch (_: Throwable) {
            false
        }
    }

    private fun islandSupportJson(): String {
        return try {
            JSONObject()
                .put("island", isSupportIsland())
                .put("protocol", focusProtocolVersion())
                .put("focusPermission", hasFocusPermission())
                .toString()
        } catch (_: Throwable) {
            """{"island":false,"protocol":0,"focusPermission":false}"""
        }
    }

    // ===== 通知构建 =====

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
        ensureNotifyPermission()
        ensureChannel()

        // 能力查询仅用于日志；失败不得挡通知
        try {
            android.util.Log.i(
                "LegadoIsland",
                "support=${islandSupportJson()} title=$title pct=$progress done=$done failed=$failed"
            )
        } catch (_: Throwable) {}

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

        val pct = if (done || failed) 100 else progress.coerceIn(0, 100)
        val progressText = if (done || failed) text else "$text（$pct%）"

        val builder = NotificationCompat.Builder(this, channelId)
            .setContentTitle(title)
            .setContentText(progressText)
            .setStyle(NotificationCompat.BigTextStyle().bigText(progressText))
            .setSmallIcon(icon)
            .setContentIntent(pi)
            .setOnlyAlertOnce(true)
            .setOngoing(!done && !failed)
            .setAutoCancel(done || failed)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
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

        if (Build.VERSION.SDK_INT >= 36 && !done && !failed) {
            tryLiveProgressStyle(builder, progress, max)
        }

        // 关键：先 build，再写 extras（官方示例 notification.extras.putString）
        val notification: Notification = builder.build()
        attachXiaomiIsland(notification, title, text, pct, done, failed)

        nm().notify(id, notification)
    }

    /**
     * 小米超级岛客户端接入（pId=2131 §1.2 / §四 模版接入示例）。
     *
     * - `miui.focus.param`：param_v2 + param_island（大岛 imageTextInfoLeft 的
     *   picInfo+textInfo、小岛 picInfo.pic、baseInfo/hintInfo）
     * - `miui.focus.pics`：Icon 引用（pic 字段写 key）
     * - 非小米机型写入无害，SystemUI 忽略
     */
    private fun attachXiaomiIsland(
        notification: Notification,
        title: String,
        text: String,
        pct: Int,
        done: Boolean,
        failed: Boolean
    ) {
        try {
            val terminal = done || failed
            val statusWord = when {
                failed -> "失败"
                done -> "完成"
                else -> "下载中"
            }
            val bigTitle = if (terminal) statusWord else "$pct%"
            val ticker = if (failed) "OCR 下载失败" else if (done) "OCR 就绪" else "OCR 下载 $pct%"
            val color = if (failed) "#D32F2F" else "#1976D2"

            // 与官方「模版接入示例」同构；textInfo 放 imageTextInfoLeft 内
            val island = JSONObject().apply {
                put("param_v2", JSONObject().apply {
                    put("protocol", 1)
                    put("business", "download")
                    put("islandFirstFloat", true)
                    put("enableFloat", !terminal) // 更新时不再自动展开终态
                    // 持续性：下载中 true；完成/失败 false（S2 终态契约）
                    put("updatable", !terminal)
                    put("timeout", if (terminal) 1 else 720) // 单位 min（官方表）
                    put("ticker", ticker)
                    put("aodTitle", ticker)
                    put("param_island", JSONObject().apply {
                        put("islandProperty", 1)
                        put("islandTimeout", if (terminal) 60 else 3600)
                        put("bigIslandArea", JSONObject().apply {
                            // A 区：图文（进度）
                            put("imageTextInfoLeft", JSONObject().apply {
                                put("type", 1)
                                put("picInfo", JSONObject().apply {
                                    put("type", 1)
                                    put("pic", "miui.focus.pic_main")
                                })
                                put("textInfo", JSONObject().apply {
                                    put("frontTitle", title)
                                    put("title", bigTitle)
                                    put("content", text)
                                    put("useHighLight", !terminal)
                                })
                            })
                            // B 区：图
                            put("picInfo", JSONObject().apply {
                                put("type", 1)
                                put("pic", "miui.focus.pic_main")
                            })
                        })
                        put("smallIslandArea", JSONObject().apply {
                            put("picInfo", JSONObject().apply {
                                put("type", 1)
                                put("pic", "miui.focus.pic_main")
                            })
                        })
                        put("shareData", JSONObject().apply {
                            put("pic", "miui.focus.pic_main")
                            put("title", title)
                            put("content", if (terminal) text else "$pct% · $text")
                        })
                    })
                    put("baseInfo", JSONObject().apply {
                        put("title", title)
                        put("content", if (terminal) text else "$pct% · $text")
                        put("colorTitle", color)
                        put("type", 2)
                    })
                    put("hintInfo", JSONObject().apply {
                        put("type", 1)
                        put("title", if (terminal) ticker else "下载中 $pct%")
                    })
                })
            }

            notification.extras.putString("miui.focus.param", island.toString())

            // 图片：launcher 图标作为岛内 pic
            val pics = Bundle()
            val picIcon = try {
                Icon.createWithResource(this, applicationInfo.icon)
            } catch (_: Throwable) {
                Icon.createWithResource(this, android.R.drawable.stat_sys_download)
            }
            pics.putParcelable("miui.focus.pic_main", picIcon)
            notification.extras.putBundle("miui.focus.pics", pics)
        } catch (e: Throwable) {
            android.util.Log.w("LegadoIsland", "attach island failed: $e")
        }
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
            compat.javaClass.methods
                .firstOrNull { it.name == "setStyle" && it.parameterTypes.size == 1 }
                ?.invoke(compat, ps)
        } catch (_: Throwable) {
            // 无 ProgressStyle 时仍显示 Compat 进度条
        }
    }
}
