package com.mymg.app

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 后台弹出窗口（悬浮窗）承载快捷控车。
 * 无 Activity 黑底；需 SYSTEM_ALERT_WINDOW（小米：后台弹出界面）。
 */
object ControlOverlay {
    private const val TAG = "MYMG.Overlay"
    private var engine: FlutterEngine? = null
    private var flutterView: FlutterView? = null
    private var shown = false

    fun canDraw(context: Context): Boolean = Settings.canDrawOverlays(context)

    fun permissionIntent(context: Context): Intent =
        Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${context.packageName}"),
        )

    fun show(context: Context): Boolean {
        if (!canDraw(context)) return false
        if (shown) return true
        return try {
            val app = context.applicationContext
            val eng = FlutterEngine(app)
            eng.navigationChannel.setInitialRoute("/quick_control")
            eng.dartExecutor.executeDartEntrypoint(
                io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint(
                    io.flutter.FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                    "main",
                ),
            )
            // 与 MainActivity 相同的 BLE 通道，保证状态互通
            val ble = MethodChannel(eng.dartExecutor.binaryMessenger, "mymg/ble")
            MymgBleScanner.bind(ble, app)
            MymgBleKeyClient.bind(ble, app)
            ble.setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermissions" -> result.success(true)
                    "startScan", "stopScan", "hasScanPermission", "isSupported" ->
                        MymgBleScanner.handle(call, result)
                    "calculateServiceUuid", "formatBookingId", "fixedServiceUuid", "probe", "unlock", "lock", "drive", "trunk", "liftgateOpen", "liftgateClose", "liftgate_open", "liftgate_close", "disconnect", "isConnected", "cachedMaterial", "setAutoDriveAfterUnlock" ->
                        MymgBleKeyClient.handle(call, result)
                    else -> result.notImplemented()
                }
            }
            MethodChannel(eng.dartExecutor.binaryMessenger, "mymg/overlay")
                .setMethodCallHandler { call, result ->
                    if (call.method == "dismiss") {
                        dismiss()
                        result.success(true)
                    } else result.notImplemented()
                }

            val view = FlutterView(app)
            view.attachToFlutterEngine(eng)
            view.setBackgroundColor(Color.TRANSPARENT)

            val wm = app.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val type = if (Build.VERSION.SDK_INT >= 26) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_SYSTEM_ALERT
            }
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                type,
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                android.graphics.PixelFormat.TRANSLUCENT,
            )
            params.gravity = Gravity.TOP or Gravity.START
            wm.addView(view, params)
            engine = eng
            flutterView = view
            shown = true
            true
        } catch (t: Throwable) {
            android.util.Log.e(TAG, "show overlay fail", t)
            false
        }
    }

    fun dismiss() {
        if (!shown) return
        shown = false
        try {
            val wm = flutterView?.context?.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            flutterView?.let { wm?.removeViewImmediate(it) }
            flutterView?.detachFromFlutterEngine()
        } catch (_: Throwable) {}
        flutterView = null
        try {
            engine?.destroy()
        } catch (_: Throwable) {}
        engine = null
    }
}