package com.mymg.app

import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Read the installed package, including its actual build version code. */
object MymgAppInfo {
    fun bind(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, "mymg/app_info")
            .setMethodCallHandler { call, result ->
                if (call.method != "getVersion") {
                    result.notImplemented()
                } else {
                    try {
                        @Suppress("DEPRECATION")
                        val info = app.packageManager.getPackageInfo(app.packageName, 0)
                        @Suppress("DEPRECATION")
                        val code = if (Build.VERSION.SDK_INT >= 28) {
                            info.longVersionCode
                        } else {
                            info.versionCode.toLong()
                        }
                        result.success(mapOf(
                            "versionName" to (info.versionName ?: ""),
                            "versionCode" to code,
                        ))
                    } catch (_: Exception) {
                        result.error("APP_INFO", "无法读取应用版本", null)
                    }
                }
            }
    }
}
