package com.mymg.app

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 基础 BLE 扫描：只扫附近设备并上报 RSSI，不做 GATT 写/解锁。
 * 完整的数字钥匙解锁需要一个厂商私有协议实现，本项目未内置（见 docs/PROTOCOL.md）。
 */
object MymgBleScanner {
    private const val TAG = "MymgBle"
    private var scanning = false
    private val main = Handler(Looper.getMainLooper())
    /** 同 MymgBleKeyClient：MainActivity 与 QuickControlActivity 是两个引擎，事件要广播到全部 */
    private val channels = java.util.Collections.synchronizedList(mutableListOf<MethodChannel>())
    private var appContext: Context? = null
    private val lastSeen = HashMap<String, Long>()

    fun bind(channel: MethodChannel, context: Context) {
        if (!channels.contains(channel)) channels.add(channel)
        this.appContext = context.applicationContext
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null) {
            result.error("CTX", "未初始化", null)
            return
        }
        when (call.method) {
            "startScan" -> startScan(ctx, result)
            "stopScan" -> {
                stopScan()
                result.success(true)
            }
            "isSupported" -> {
                val bm = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
                result.success(bm?.adapter != null)
            }
            "hasScanPermission" -> result.success(hasScanPermission(ctx))
            else -> result.notImplemented()
        }
    }

    private fun hasScanPermission(context: Context): Boolean {
        val hasScan = context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) ==
            PackageManager.PERMISSION_GRANTED
        val hasConnect = context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED
        val hasLoc = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        return if (Build.VERSION.SDK_INT >= 31) {
            hasScan && hasConnect
        } else {
            hasLoc
        }
    }

    @SuppressLint("MissingPermission")
    private fun startScan(context: Context, result: MethodChannel.Result) {
        val bm = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bm?.adapter
        if (adapter == null || !adapter.isEnabled) {
            result.error("BT", "蓝牙未开启", null)
            return
        }
        val hasScan = context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) ==
            PackageManager.PERMISSION_GRANTED
        val hasLoc = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        if (Build.VERSION.SDK_INT >= 31 && !hasScan && !hasLoc) {
            result.error("PERM", "缺少蓝牙扫描权限", null)
            return
        }
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            result.error("BT", "设备不支持 BLE 扫描", null)
            return
        }
        try {
            scanner.startScan(callback)
            scanning = true
            lastSeen.clear()
            Log.i(TAG, "scan started")
            result.success(true)
        } catch (e: Throwable) {
            result.error("SCAN", e.message, null)
        }
    }

    @SuppressLint("MissingPermission")
    fun stopScan() {
        try {
            val ctx = appContext ?: return
            val bm = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            bm?.adapter?.bluetoothLeScanner?.stopScan(callback)
        } catch (_: Throwable) {
        }
        scanning = false
        Log.i(TAG, "scan stopped")
    }

    private val callback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (!scanning) return
            val addr = result.device?.address ?: return
            val now = System.currentTimeMillis()
            val last = lastSeen[addr] ?: 0L
            if (now - last < 1000) return
            lastSeen[addr] = now

            val name = result.device.name
            val rssi = result.rssi
            main.post {
                val payload = mapOf(
                    "address" to addr,
                    "name" to (name ?: ""),
                    "rssi" to rssi,
                )
                val snapshot = try {
                    synchronized(channels) { channels.toList() }
                } catch (_: Throwable) {
                    emptyList()
                }
                for (ch in snapshot) {
                    try {
                        ch.invokeMethod("nearby", payload)
                    } catch (_: Throwable) {
                        channels.remove(ch)
                    }
                }
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.w(TAG, "scan failed code=$errorCode")
            scanning = false
        }
    }
}
