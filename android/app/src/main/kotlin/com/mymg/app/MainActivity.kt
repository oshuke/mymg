package com.mymg.app

import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// local_auth 依赖 FlutterFragmentActivity 才能拿到 Activity 结果回调；
// Impeller 开关在 AndroidManifest 的 meta-data 里覆盖 shell args。
class MainActivity : FlutterFragmentActivity() {

// 同进程多次加载 packages 时，先手动 System.loadLibrary("mymg_core") 保证 so 已就位，
// 避免 Flutter 侧 native assets 懒加载顺序带来的符号缺失。
// 符号名与 Rust 侧导出的 JNI 函数一致。
    companion object {
        init {
// 把 Rust 侧 log 输出桥接进 Android logcat（tag 前缀 "mymg_core"），
// 便于 adb logcat 观察请求体与错误；初始化失败不影响主流程。
            try {
                System.loadLibrary("mymg_core")
                android_main_log_init()
            } catch (_: Throwable) {
// 原生库不可用时忽略：车况/远程控车走网络，仍可正常使用。
            }
        }

        @JvmStatic
        external fun android_main_log_init()

// 长按图标快捷方式定义见 res/xml/shortcuts.xml。
        const val SHORTCUT_HISTORY = "com.mymg.app.SHORTCUT_HISTORY"
        const val SHORTCUT_MAP = "com.mymg.app.SHORTCUT_MAP"
        const val SHORTCUT_CONTROL = "com.mymg.app.SHORTCUT_CONTROL"

/** 快捷指令 action（图标长按 / 磁贴复用） */
        const val ACTION_QS_CONTROL = "com.mymg.app.QS_CONTROL"

/** 桌面小组件刷新 action（点击刷新时用透明 Activity 承接，避免闪屏） */
        const val ACTION_WIDGET_REFRESH = "com.mymg.app.WIDGET_REFRESH"

/** 快捷方式 action → Flutter 路由名映射 */
        private fun shortcutName(action: String?): String? = when (action) {
            SHORTCUT_HISTORY -> "history"
            SHORTCUT_MAP -> "map"
            SHORTCUT_CONTROL -> "control"
            ACTION_QS_CONTROL -> "quick_control"
            MymgWidgetProvider.ACTION_WIDGET_CONTROL -> null // routed via getInitialRoute
            else -> null
        }
    }

/** 启动参数里的快捷方式路由，等 Flutter 首帧后取走 */
    private var pendingShortcut: String? = null
    private var shortcutChannel: MethodChannel? = null
    private var pendingResAlarm: Boolean = false
    private var alarmChannel: MethodChannel? = null

/** 小组件刷新待处理标记（Activity 可能被立即 finish） */
    private var pendingWidgetRefresh: Boolean = false
    private var widgetRefreshChannel: MethodChannel? = null

/**
 * 首帧路由：把启动 action 映射成 Flutter 路由。
 * 桌面小组件/磁贴走透明样式 Activity，直接进 /quick_control 或 /widget_control。
 *
 * 注意返回类型必须是 String?：
 * FlutterFragmentActivity.getInitialRoute() 在无 EXTRA_INITIAL_ROUTE / meta-data 时返回 null；
 * 若返回非空 String，Kotlin 侧把 null 强转成 String 会抛 NPE。
     */
    override fun getInitialRoute(): String? {
        val action = intent?.action
        if (action == ACTION_WIDGET_REFRESH) return "/widget_refresh"
        if (action == ACTION_QS_CONTROL) return "/quick_control"
        if (action == MymgWidgetProvider.ACTION_WIDGET_CONTROL) {
            val code = intent?.getIntExtra("control", 0) ?: 0
            return "/widget_control/$code"
        }
        return super.getInitialRoute()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
// 快捷控车/小组件刷新：用透明主题，避免白底闪一下。
        if (intent?.action == ACTION_WIDGET_REFRESH ||
            intent?.action == ACTION_QS_CONTROL ||
            intent?.action == MymgWidgetProvider.ACTION_WIDGET_CONTROL) {
            try {
                setTheme(R.style.QuickControlTheme)
                window.setBackgroundDrawableResource(android.R.color.transparent)
                window.decorView.setBackgroundColor(android.graphics.Color.TRANSPARENT)
            } catch (_: Throwable) {
            }
        }
        super.onCreate(savedInstanceState)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        BlePermissionController.onResult(this, requestCode, grantResults)
    }

    override fun onDestroy() {
        BlePermissionController.detach(this)
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MymgAppInfo.bind(flutterEngine, applicationContext)

        // Background the task without finishing the activity or BLE service.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mymg/navigation")
            .setMethodCallHandler { call, result ->
                if (call.method == "moveToBackground") {
                    result.success(moveTaskToBack(true))
                } else {
                    result.notImplemented()
                }
            }

// 调试通道：Android ID / 机型信息 / 启动官方 App
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mymg/debug"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAndroidId" -> result.success(
                    Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
                )
                "getBuildInfo" -> {
                    val info = mapOf(
                        "brand" to android.os.Build.BRAND,
                        "model" to android.os.Build.MODEL,
                        "device" to android.os.Build.DEVICE,
                        "manufacturer" to android.os.Build.MANUFACTURER,
                        "release" to android.os.Build.VERSION.RELEASE,
                        "sdk" to android.os.Build.VERSION.SDK_INT.toString(),
                        "serial" to (try { android.os.Build.getSerial() } catch (_: Throwable) { "unknown" }),
                    )
                    result.success(info)
                }
// 启动第三方 App（按包名）：用 launcher 入口；
// 返回 false 表示未安装或不可见。
// 返回 true 表示已拉起。
                "openApp" -> {
                    val pkg = call.argument<String>("package")
                    if (pkg.isNullOrEmpty()) {
                        result.error("ARG", "package is required", null)
                    } else {
                        try {
                            val intent = packageManager.getLaunchIntentForPackage(pkg)
                            if (intent == null) {
result.success(false) // 未安装 / 不可见
                            } else {
                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(intent)
                                result.success(true)
                            }
                        } catch (e: Throwable) {
                            result.error("LAUNCH_FAILED", e.message, null)
                        }
                    }
                }
// 打开官方 App 并尽量落到车辆页（仅 launcher 可用）：
// 车辆页 Activity 在 manifest 里 exported=false，外部无法直接 startActivity；
// 只能按 launcher intent 启动，由官方 App 自己决定落哪个页面。
// 历史尝试（已放弃）：
//   - 直接用 setComponent 拉起车辆页组件：目标 exported=false，外部调用被拒；
//   - 组件名随版本变化，硬编码不可维护。
//
// 现在的策略：
//   - 只按 launcher 入口拉起，由官方 App 自己决定落哪个页面；
//   - 返回 "launcher"：已交给 launcher；
//   - 返回 false：未安装 / 不可见。
//
// 包名由调用方通过 package 参数传入（构建期配置），未传则直接返回 false。
//
// 返回值：
//   "launcher" — 已通过 launcher 拉起；
//   false      — 未安装或不可见。
//
                "openControl" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    if (pkg.isBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        val launcher = packageManager.getLaunchIntentForPackage(pkg)
                        if (launcher == null) {
result.success(false) // 未安装 / 不可见
                            return@setMethodCallHandler
                        }
                        launcher.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(launcher)
                        result.success("launcher")
                    } catch (e: Throwable) {
                        result.error(
                            "LAUNCH_FAILED",
"$pkg launcher 启动失败：${e.message}",
                            null,
                        )
                    }
                }
// ────────── 滑块验证码（CaptchaActivity）──────────
                "openCaptcha" -> {
                    val captchaId = call.argument<String>("captchaId") ?: ""
                    try {
                        CaptchaActivity.pendingValidate = null
                        CaptchaActivity.pendingError = null
                        val i = Intent(this, CaptchaActivity::class.java)
                            .putExtra(CaptchaActivity.EXTRA_CAPTCHA_ID, captchaId)
                        startActivity(i)
                        result.success(true)
                    } catch (e: Throwable) {
                        result.error("CAPTCHA", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

// ────────── 小组件通道：手动刷新 ──────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mymg/widget"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "refresh" -> result.success(MymgWidgetProvider.refreshAll(applicationContext))
                else -> result.notImplemented()
            }
        }

// ────────── 快捷方式 / 闹钟待处理动作 ──────────
// Flutter 侧可能在 Activity 创建之后才注册通道，
// 所以启动参数先缓存，等 Flutter 主动 getPending* 取走。
        shortcutChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mymg/shortcut"
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPendingAction" -> {
                        val a = pendingShortcut
                        pendingShortcut = null
                        result.success(a)
                    }
                    "getPendingResAlarm" -> {
                        val v = pendingResAlarm
                        pendingResAlarm = false
                        result.success(v)
                    }
                    else -> result.notImplemented()
                }
            }
        }

// ────────── 预约闹钟（AlarmManager scheduleAt / cancel）──────────
        alarmChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mymg/reservation_alarm"
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "scheduleAt" -> {
                        val atMs = call.argument<Number>("atMs")?.toLong()
                        if (atMs == null) {
                            result.error("ARG", "atMs required", null)
                        } else {
                            try {
                                ReservationAlarmReceiver.schedule(applicationContext, atMs)
                                result.success(true)
                            } catch (e: Throwable) {
                                result.error("ALARM", e.message, null)
                            }
                        }
                    }
                    "cancel" -> {
                        ReservationAlarmReceiver.cancel(applicationContext)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }

// ────────── 蓝牙扫描 + GATT 控车 ──────────
        val bleChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mymg/ble"
        )
        MymgBleScanner.bind(bleChannel, applicationContext)
        MymgBleKeyClient.bind(bleChannel, applicationContext)
        bleChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermissions" -> BlePermissionController.request(this, result)
                "openAppSettings" -> BlePermissionController.openAppSettings(this, result)
                "startScan", "stopScan", "hasScanPermission", "isSupported" ->
                    MymgBleScanner.handle(call, result)
                "calculateServiceUuid", "formatBookingId", "fixedServiceUuid", "probe", "unlock", "lock", "drive", "trunk", "liftgateOpen", "liftgateClose", "liftgate_open", "liftgate_close", "disconnect", "isConnected", "cachedMaterial", "setAutoDriveAfterUnlock" ->
                    if (call.method in setOf(
                            "probe", "unlock", "lock", "drive", "trunk",
                            "liftgateOpen", "liftgateClose", "liftgate_open", "liftgate_close",
                        ) && !BlePermissionController.hasPermissions(this)) {
                        result.error("PERM", "蓝牙权限未授予，请打开应用设置授权后重试", null)
                    } else {
                        MymgBleKeyClient.handle(call, result)
                    }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mymg/overlay"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "request" -> {
                    try {
                        startActivity(ControlOverlay.permissionIntent(this))
                    } catch (_: Throwable) {}
                    result.success(true)
                }
                "dismiss" -> {
                    ControlOverlay.dismiss()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

// 启动参数里的快捷方式 action 先缓存，等 Flutter 取走
        shortcutName(intent?.action)?.let { pendingShortcut = it }
        // 小组件点击：先静默刷新小组件数据
        if (intent?.action == MymgWidgetProvider.ACTION_WIDGET_OPEN) {
            try {
                sendBroadcast(Intent(this, WidgetSilentRefreshReceiver::class.java).apply {
                    action = WidgetSilentRefreshReceiver.ACTION
                })
            } catch (_: Throwable) {}
        }
// 预约闹钟触发：标记待处理，等 Flutter 取走
        if (intent?.action == ReservationAlarmReceiver.ACTION_RUN) {
            pendingResAlarm = true
        }
// 小组件刷新：标记 pending，Flutter 处理完再关闭页面
        if (intent?.action == ACTION_WIDGET_REFRESH ||
            intent?.action == MymgWidgetProvider.ACTION_WIDGET_CONTROL) {
            pendingWidgetRefresh = true
        }

        widgetRefreshChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mymg/widget_refresh"
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPending" -> {
                        val v = pendingWidgetRefresh
                        pendingWidgetRefresh = false
                        result.success(v)
                    }
                    "done" -> {
                        result.success(true)
// 刷新完成后稍等再关掉透明 Activity
                        window.decorView.postDelayed({
                            try {
                                finish()
                            } catch (_: Throwable) {
                            }
                        }, 600)
                    }
                    else -> result.notImplemented()
                }
            }
        }

// 滑块验证码结果通道
                // 小组件直接控车：toast / finish / controlCode
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mymg/widget_control"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "controlCode" -> result.success(intent?.getIntExtra("control", 0) ?: 0)
                "toast" -> {
                    val msg = call.arguments as? String ?: ""
                    android.widget.Toast.makeText(applicationContext, msg, android.widget.Toast.LENGTH_SHORT).show()
                    result.success(true)
                }
                "finish" -> {
                    result.success(true)
                    window.decorView.postDelayed({
                        try { finish() } catch (_: Throwable) {}
                    }, 400)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mymg/captcha"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getResult" -> {
                    result.success(
                        mapOf(
                            "validate" to CaptchaActivity.pendingValidate,
                            "error" to CaptchaActivity.pendingError,
                            "ready" to CaptchaActivity.resultReady,
                        ),
                    )
                }
                "clear" -> {
                    CaptchaActivity.pendingValidate = null
                    CaptchaActivity.pendingError = null
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

    }

    override fun onNewIntent(intent: Intent) {
        if (intent.action == MymgWidgetProvider.ACTION_WIDGET_OPEN) {
            try {
                sendBroadcast(Intent(this, WidgetSilentRefreshReceiver::class.java).apply {
                    action = WidgetSilentRefreshReceiver.ACTION
                })
            } catch (_: Throwable) {}
        }
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == ACTION_WIDGET_REFRESH) {
// 磁贴/小组件刷新：起透明 Activity 承接，避免 Flutter 页面闪一下
            pendingWidgetRefresh = true
            try {
                val refresh = Intent(this, WidgetRefreshActivity::class.java).apply {
                    action = WidgetRefreshActivity.ACTION
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_NO_ANIMATION
                }
                startActivity(refresh)
                @Suppress("DEPRECATION")
                overridePendingTransition(0, 0)
            } catch (t: Throwable) {
                android.util.Log.e("MYMG.Main", "WidgetRefresh start failed", t)
// 兜底：直接通知通道，让已存在的 Flutter 引擎执行刷新
                widgetRefreshChannel?.invokeMethod("run", null)
            }
            return
        }
        if (intent.action == ReservationAlarmReceiver.ACTION_RUN) {
            pendingResAlarm = true
            alarmChannel?.let {
                pendingResAlarm = false
                it.invokeMethod("runReservation", null)
            }
            return
        }
        val name = shortcutName(intent.action) ?: return
// 已在运行：直接把 action 派发给 Flutter 路由
        pendingShortcut = name
        shortcutChannel?.let { ch ->
            pendingShortcut = null
            ch.invokeMethod("shortcut", name)
        }
    }
}
