package com.mymg.app

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import org.json.JSONObject

/**
 * 控制中心「智能控车」磁贴。
 *
 * Android 14+ 必须用 startActivityAndCollapse(PendingIntent)，
 * 旧的 Intent 重载在部分 ROM（含 MIUI）上会静默失败。
 */
class MymgControlTileService : TileService() {

    companion object {
        private const val TAG = "MYMG.Tile"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val KEY_WIDGET_JSON = "flutter.mymg.widget.json"
        private const val KEY_WIDGET_JSON_BARE = "mymg.widget.json"
        private const val REQ_QS = 0x4D594D47 // 'MYMG'

        /** 与 MainActivity / Flutter 约定：打开快捷控车面板 */
        const val EXTRA_OPEN_QUICK_CONTROL = "open_quick_control"
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        try {
            launchQuickControl()
            qsTile?.let {
                it.state = Tile.STATE_ACTIVE
                it.updateTile()
            }
            Log.i(TAG, "tile clicked → launching quick control")
        } catch (t: Throwable) {
            Log.e(TAG, "tile open failed", t)
        }
    }

    private fun launchQuickControl() {
        // 优先悬浮窗（后台弹出，无黑底）；无权限则回退透明 Activity
        val intent = Intent(this, QuickControlActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            action = MainActivity.ACTION_QS_CONTROL
            putExtra(EXTRA_OPEN_QUICK_CONTROL, true)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            )
        }
        collapseAndStart(intent, REQ_QS)
    }

    private fun collapseAndStart(intent: Intent, requestCode: Int) {
        val pi = PendingIntent.getActivity(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(pi)
        } else {
            // 旧 API：先折叠面板再启动，部分 ROM 需要
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        try {
            val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            val raw = prefs.getString(KEY_WIDGET_JSON, null)
                ?: prefs.getString(KEY_WIDGET_JSON_BARE, null)
            if (raw.isNullOrBlank()) {
                tile.label = "智能控车"
                tile.subtitle = "点按打开控车"
                tile.state = Tile.STATE_INACTIVE
            } else {
                val data = JSONObject(raw)
                val fuel = if (data.isNull("fuel")) null else data.optInt("fuel")
                val locked = if (data.isNull("locked")) null else data.optBoolean("locked")
                val lockText = when (locked) {
                    true -> "已锁"
                    false -> "未锁"
                    null -> "?"
                }
                tile.label = "智能控车"
                tile.subtitle = (fuel?.let { "油 $it% · " } ?: "") + lockText
                tile.state = Tile.STATE_ACTIVE
            }
            tile.updateTile()
        } catch (t: Throwable) {
            Log.e(TAG, "updateTile failed", t)
            tile.label = "智能控车"
            tile.state = Tile.STATE_INACTIVE
            tile.updateTile()
        }
    }
}
