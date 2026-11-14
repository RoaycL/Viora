package com.viora.viora

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import com.viora.viora.exo.ExoPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var exo: ExoPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        exo = ExoPlugin(this, flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "viora/diag").setMethodCallHandler { call, result ->
            if (call.method == "lastExits") {
                try {
                    result.success(lastExits())
                } catch (e: Exception) {
                    result.success(listOf("读取失败: ${e.message}"))
                }
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "viora/update").setMethodCallHandler { call, result ->
            when (call.method) {
                // 返回 "installing"：已拉起系统安装界面；
                // 返回 "needs_permission"：已打开"安装未知应用"授权页，用户授权后需再次调用。
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "path is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(installApk(File(path)))
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 上一次进程是怎么结束的（Android 11+）：被系统因内存不足杀掉、Java / 原生崩溃、ANR 等。
     * Dart 端启动时写进日志，闪退后导出日志就能看到真正的原因（Dart 日志记录不到原生崩溃和被杀）
     */
    private fun lastExits(): List<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) exitsSinceR() else emptyList()
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun exitsSinceR(): List<String> {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return emptyList()
        return am.getHistoricalProcessExitReasons(packageName, 0, 3).map { e ->
            val reason = when (e.reason) {
                ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
                ApplicationExitInfo.REASON_CRASH -> "CRASH"
                ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
                ApplicationExitInfo.REASON_ANR -> "ANR"
                ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
                ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
                ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
                ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
                ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
                ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
                ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
                ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
                ApplicationExitInfo.REASON_OTHER -> "OTHER"
                else -> "UNKNOWN(${e.reason})"
            }
            val time = java.text.SimpleDateFormat("MM-dd HH:mm:ss", java.util.Locale.US).format(java.util.Date(e.timestamp))
            val importance = if (e.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND) "前台" else "后台(${e.importance})"
            "$time $reason $importance pss=${e.pss shr 10}MB rss=${e.rss shr 10}MB status=${e.status} ${e.description ?: ""}".trim()
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        exo?.releaseAll()
        exo = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun installApk(file: File): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            val settings = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            // 部分电视系统没有这个设置页，退回到通用安全设置。
            if (settings.resolveActivity(packageManager) != null) {
                startActivity(settings)
            } else {
                startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            return "needs_permission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.update", file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        return "installing"
    }
}
