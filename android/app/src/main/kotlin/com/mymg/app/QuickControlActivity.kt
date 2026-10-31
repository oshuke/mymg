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
 * 控制中心磁贴 / 桌面小组件共用：透明快捷控车窗口。
 * 必须与 MainActivity 一样绑定 mymg/ble，否则独立弹窗收不到 GATT 状态。
 */
class QuickControlActivity : FlutterActivity() {

    override fun getInitialRoute(): String = "/quick_control"

    override fun getRenderMode(): RenderMode = RenderMode.texture

    override fun getTransparencyMode(): TransparencyMode =
        TransparencyMode.transparent

    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(R.style.QuickControlTheme)
        window.setBackgroundDrawableResource(android.R.color.transparent)
        window.decorView.setBackgroundColor(Color.TRANSPARENT)
        super.onCreate(savedInstanceState)
        try {
            window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        } catch (_: Throwable) {
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bleChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mymg/ble"
        )
        MymgBleScanner.bind(bleChannel, applicationContext)
        MymgBleKeyClient.bind(bleChannel, applicationContext)
        bleChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermissions" -> {
                    if (android.os.Build.VERSION.SDK_INT >= 31) {
                        requestPermissions(
                            arrayOf(
                                "android.permission.BLUETOOTH_SCAN",
                                "android.permission.BLUETOOTH_CONNECT",
                                "android.permission.ACCESS_FINE_LOCATION",
                            ),
                            4321,
                        )
                    } else {
                        requestPermissions(
                            arrayOf(
                                "android.permission.ACCESS_FINE_LOCATION",
                                "android.permission.ACCESS_COARSE_LOCATION",
                            ),
                            4321,
                        )
                    }
                    result.success(true)
                }
                "startScan", "stopScan", "hasScanPermission", "isSupported" ->
                    MymgBleScanner.handle(call, result)
                "calculateServiceUuid", "formatBookingId", "fixedServiceUuid", "probe", "unlock", "lock", "drive", "trunk", "liftgateOpen", "liftgateClose", "liftgate_open", "liftgate_close", "disconnect", "isConnected", "cachedMaterial", "setAutoDriveAfterUnlock" ->
                    MymgBleKeyClient.handle(call, result)
                else -> result.notImplemented()
            }
        }
    }
}