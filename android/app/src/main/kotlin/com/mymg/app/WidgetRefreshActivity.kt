package com.mymg.app

import android.graphics.Color
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 小组件「↻ 刷新」专用透明壳：
 * 不展示主页 / 启动页，Flutter 静默拉一次车况写回小组件后自动 finish。
 *
 * 黑底根因与 QuickControlActivity 相同：必须 texture + transparent。
 */
class WidgetRefreshActivity : FlutterActivity() {

    companion object {
        const val ACTION = "com.mymg.app.WIDGET_REFRESH"

        /** 看门狗：Flutter/网络卡住也不能让透明壳一直挂着 */
        private const val WATCHDOG_MS = 15_000L
    }

    private var channel: MethodChannel? = null
    private var finished = false
    private val watchdog = Runnable { finishQuietly() }

    override fun getInitialRoute(): String = "/widget_refresh"

    override fun getRenderMode(): RenderMode = RenderMode.texture

    override fun getTransparencyMode(): TransparencyMode =
        TransparencyMode.transparent

    override fun onCreate(savedInstanceState: Bundle?) {
        window.setBackgroundDrawableResource(android.R.color.transparent)
        window.decorView.setBackgroundColor(Color.TRANSPARENT)
        super.onCreate(savedInstanceState)
        try {
            window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        } catch (_: Throwable) {
        }
        // 无窗口动画，避免从桌面闪入
        try {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        } catch (_: Throwable) {
        }
        // 桌面小组件立刻给刷新反馈（◌ / 刷新中…）
        try {
            MymgWidgetProvider.setRefreshing(this, true)
        } catch (_: Throwable) {
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 启动看门狗，防 Flutter/网络卡死导致透明壳挂住
        window.decorView.postDelayed(watchdog, WATCHDOG_MS)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mymg/widget_refresh"
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPending" -> result.success(true)
                    "done" -> {
                        result.success(true)
                        // 数据已写回：清掉刷新态并重绘，再关壳
                        try {
                            MymgWidgetProvider.setRefreshing(this, false)
                        } catch (_: Throwable) {
                        }
                        window.decorView.postDelayed({ finishQuietly() }, 250)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun finishQuietly() {
        if (finished) return
        finished = true
        try {
            window.decorView.removeCallbacks(watchdog)
        } catch (_: Throwable) {
        }
        // 兜底：异常退出也要清刷新态，避免按钮卡在 ◌
        try {
            MymgWidgetProvider.setRefreshing(this, false)
        } catch (_: Throwable) {
        }
        try {
            finish()
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        } catch (_: Throwable) {
        }
    }

    override fun onDestroy() {
        finished = true
        try {
            window.decorView.removeCallbacks(watchdog)
        } catch (_: Throwable) {
        }
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }
}
