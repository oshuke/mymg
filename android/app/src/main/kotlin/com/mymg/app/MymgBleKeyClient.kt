package com.mymg.app

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Collections

/**
 * 数字钥匙模块（开源版占位实现）。
 *
 * 本仓库不包含任何厂商 BLE 协议实现：不内置 GATT 服务/特征 UUID、
 * 不内置厂商安全芯片的鉴权算法、不附带厂商闭源库。
 *
 * 保留下来的只有 MethodChannel 契约（'mymg/ble'），以便：
 * - 上层 Dart 代码（lib/ble_key_bridge.dart）无需改动即可编译运行；
 * - 想自行接入数字钥匙的开发者按同样契约实现一个真正可用的模块，
 *   直接把本文件替换掉即可（详见 docs/PROTOCOL.md 的「数字钥匙扩展点」）。
 *
 * 所有需要真实链路的调用都会返回 ERR_NOT_INCLUDED，Dart 侧会把它显示为一条
 * 友好的提示，而不是静默失败。
 */
object MymgBleKeyClient {
    private const val TAG = "MymgBleKey"
    const val ERR_NOT_INCLUDED = "NOT_INCLUDED"
    const val MSG_NOT_INCLUDED =
        "数字钥匙模块未内置：开源版不包含厂商 BLE 协议实现。车况与远程控车功能不受影响。"

    /** MainActivity 与快捷控车 Activity 是两个 FlutterEngine，事件要广播到全部实例。 */
    private val channels = Collections.synchronizedList(mutableListOf<MethodChannel>())

    private var appContext: Context? = null

    fun bind(channel: MethodChannel, context: Context) {
        if (!channels.contains(channel)) channels.add(channel)
        appContext = context.applicationContext
    }

    fun disconnect() {
        emit("status", mapOf("stage" to "disconnected", "message" to "已断开"))
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // ── 无副作用的查询类：给空值即可，UI 会显示「未配置/未连接」 ──
            "cachedMaterial" -> result.success(
                mapOf(
                    "tboxMac" to "",
                    "aesKey" to "",
                    "secretKey" to "",
                    "keyReference" to 0,
                    "bookingId" to "",
                    "lastConnectMac" to "",
                    "userId" to "",
                    "authenticated" to false,
                    "autoDriveAfterUnlock" to false,
                )
            )
            "isConnected" -> result.success(false)
            "requestPermissions" -> result.success(true)
            "disconnect" -> {
                disconnect()
                result.success(true)
            }
            "setAutoDriveAfterUnlock" -> result.success(call.argument<Boolean>("enabled") ?: false)
            "fixedServiceUuid", "calculateServiceUuid", "formatBookingId" -> result.success("")

            // ── 需要真实厂商协议的动作：明确拒绝并广播原因 ──
            "probe", "unlock", "lock", "trunk", "liftgateOpen", "liftgateClose", "drive" -> {
                // 先广播一次状态，让 Dart 侧 message 立即变成可读文案
                emit("status", mapOf("stage" to "error", "message" to MSG_NOT_INCLUDED))
                result.error(ERR_NOT_INCLUDED, MSG_NOT_INCLUDED, null)
            }

            else -> result.error(ERR_NOT_INCLUDED, MSG_NOT_INCLUDED, null)
        }
    }

    private fun emit(event: String, args: Map<String, Any?>) {
        val snapshot = try {
            synchronized(channels) { channels.toList() }
        } catch (_: Throwable) {
            emptyList()
        }
        for (ch in snapshot) {
            try {
                ch.invokeMethod(event, args)
            } catch (_: Throwable) {
                // 引擎已销毁（Activity 结束）→ 摘掉，避免后续每次广播都抛
                channels.remove(ch)
            }
        }
    }
}
