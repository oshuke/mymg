package com.mymg.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder

/**
 * BLE 数字钥匙前台服务。
 *
 * 为什么必须有它：
 *  - 车端 TBOX 空闲时会主动断链（实测 `status=19`），要靠 App 侧快速重连 + 重新鉴权
 *    才能维持「数字钥匙在场」；进程一旦被系统冻结/回收，重连定时器就停了 → 免钥匙启动失效。
 *  - 只在前台服务运行期间，进程才不会被当作 cached 进程冻结。
 *
 * 只做保活 + 通知，不持有 GATT（GATT 仍在 [MymgBleKeyClient]，同进程）。
 */
class MymgBleService : Service() {

    companion object {
        private const val TAG = "MymgBleService"
        private const val CHANNEL_ID = "mymg_ble_key"
        private const val NOTIF_ID = 4211

        const val ACTION_START = "com.mymg.app.ble.START"
        const val ACTION_UPDATE = "com.mymg.app.ble.UPDATE"
        const val ACTION_DISCONNECT = "com.mymg.app.ble.DISCONNECT"
        const val EXTRA_TEXT = "text"

        /**
         * 常驻通知文案：**中性、不跟随连接状态**。
         * 连接/握手/重连状态只在 App 内显示 —— 通知栏一直闪「正在连接车辆」很打扰。
         */
        const val IDLE_TEXT = "后台保持中 · 无感解锁与启动可用"

        /**
         * 起服务。Android 12+ 在后台调 startForegroundService 会抛
         * ForegroundServiceStartNotAllowedException —— 全部吞掉：
         * 用户在前台操作时本来就会调到这里，后台场景忽略即可（不能崩）。
         */
        fun start(context: Context?, text: String) {
            val ctx = context?.applicationContext ?: return
            try {
                val i = Intent(ctx, MymgBleService::class.java).apply {
                    action = ACTION_START
                    putExtra(EXTRA_TEXT, text)
                }
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (e: Throwable) {
                android.util.Log.w(TAG, "start failed: $e")
            }
        }

        fun update(context: Context?, text: String) {
            val ctx = context?.applicationContext ?: return
            try {
                val i = Intent(ctx, MymgBleService::class.java).apply {
                    action = ACTION_UPDATE
                    putExtra(EXTRA_TEXT, text)
                }
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (_: Throwable) {
            }
        }

        fun stop(context: Context?) {
            val ctx = context?.applicationContext ?: return
            try {
                ctx.stopService(Intent(ctx, MymgBleService::class.java))
            } catch (_: Throwable) {
            }
        }
    }

    private var lastText = "数字钥匙已就绪"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DISCONNECT -> {
                try {
                    MymgBleKeyClient.disconnect()
                } catch (_: Throwable) {
                }
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val text = intent?.getStringExtra(EXTRA_TEXT)?.takeIf { it.isNotBlank() } ?: lastText
                lastText = text
                startForegroundCompat(text)
            }
        }
        // START_STICKY：被系统杀掉后尽量拉回（重连逻辑在 App 侧，重新进前台才有意义）
        return START_STICKY
    }

    private fun startForegroundCompat(text: String) {
        try {
            val n = buildNotification(text)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIF_ID, n)
            }
        } catch (e: Throwable) {
            android.util.Log.w(TAG, "startForeground failed: $e")
        }
    }

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
            else @Suppress("DEPRECATION") stopForeground(true)
        } catch (_: Throwable) {
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(CHANNEL_ID, "蓝牙数字钥匙", NotificationManager.IMPORTANCE_LOW)
        ch.description = "保持蓝牙钥匙链路（无感解锁 / 免钥匙启动），可在通知里断开"
        ch.setShowBadge(false)
        nm.createNotificationChannel(ch)
    }

    private fun buildNotification(text: String): Notification {
        ensureChannel()
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
            flags,
        )
        val disconnect = PendingIntent.getService(
            this,
            1,
            Intent(this, MymgBleService::class.java).setAction(ACTION_DISCONNECT),
            flags,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setContentTitle("MYMG 蓝牙数字钥匙")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_control)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
        if (Build.VERSION.SDK_INT >= 23) {
            builder.addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, R.drawable.ic_control),
                    "断开",
                    disconnect,
                ).build(),
            )
        }
        return builder.build()
    }
}
