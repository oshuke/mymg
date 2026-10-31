package com.mymg.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.util.Log
import android.widget.RemoteViews
import org.json.JSONObject
import java.io.File

/**
 * MYMG status widget renderer.
 *
 * Layout: status top-left (lock/windows/AC) · car image · fuel% + range · 4 control buttons.
 * No plate, no refresh button.
 *
 * Data via SharedPreferences JSON (see lib/widget_sync.dart).
 * Optional keys: car_image_path, widget_bg_path, widget_bg_alpha.
 */
class MymgWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            try {
                render(context, appWidgetManager, id)
            } catch (t: Throwable) {
                Log.e(TAG, "widget render failed id=$id", t)
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_REFRESH) {
            try {
                val mgr = AppWidgetManager.getInstance(context) ?: return
                val component = android.content.ComponentName(context, MymgWidgetProvider::class.java)
                val ids = mgr.getAppWidgetIds(component)
                for (id in ids) render(context, mgr, id)
            } catch (t: Throwable) {
                Log.e(TAG, "widget refresh failed", t)
            }
        }
    }

    companion object {
        private const val TAG = "MymgWidget"
        const val ACTION_REFRESH = "com.mymg.app.WIDGET_REFRESH"
        const val ACTION_WIDGET_OPEN = "com.mymg.app.WIDGET_OPEN"
        const val ACTION_WIDGET_CONTROL = "com.mymg.app.WIDGET_CONTROL"
        const val KEY_WIDGET_JSON = "flutter.mymg.widget.json"
        const val KEY_WIDGET_JSON_BARE = "mymg.widget.json"
        const val KEY_CAR_IMAGE = "flutter.mymg.car.image_path"
        const val KEY_CAR_IMAGE_BARE = "mymg.car.image_path"
        const val KEY_WIDGET_CAR_IMAGE = "flutter.mymg.widget.car_image_path"
        const val KEY_WIDGET_CAR_IMAGE_BARE = "mymg.widget.car_image_path"
        const val KEY_WIDGET_BG = "flutter.mymg.widget.bg_path"
        const val KEY_WIDGET_BG_BARE = "mymg.widget.bg_path"
        const val KEY_WIDGET_BG_ALPHA = "flutter.mymg.widget.bg_alpha"
        const val KEY_WIDGET_BG_ALPHA_BARE = "mymg.widget.bg_alpha"

        fun setRefreshing(context: Context, refreshing: Boolean) {
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .edit()
                .putBoolean("mymg.widget.refreshing", refreshing)
                .apply()
        }

        fun refreshAll(context: Context): Boolean {
            val mgr = AppWidgetManager.getInstance(context) ?: return false
            val component = android.content.ComponentName(context, MymgWidgetProvider::class.java)
            val ids = mgr.getAppWidgetIds(component)
            if (ids.isEmpty()) return false
            val intent = Intent(context, MymgWidgetProvider::class.java).apply {
                action = ACTION_REFRESH
            }
            context.sendBroadcast(intent)
            val provider = MymgWidgetProvider()
            provider.onUpdate(context, mgr, ids)
            return true
        }

        private fun roundedBitmap(src: Bitmap, radiusDp: Float = 22f, density: Float = 2f): Bitmap {
            val radius = radiusDp * density
            val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(out)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            val rect = RectF(0f, 0f, src.width.toFloat(), src.height.toFloat())
            val path = Path().apply { addRoundRect(rect, radius, radius, Path.Direction.CW) }
            canvas.drawPath(path, paint)
            paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
            canvas.drawBitmap(src, 0f, 0f, paint)
            return out
        }
        private fun prefs(context: Context) =
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

        private fun readJson(context: Context): JSONObject? {
            val raw = prefs(context).getString(KEY_WIDGET_JSON, null)
                ?: prefs(context).getString(KEY_WIDGET_JSON_BARE, null)
                ?: return null
            return try {
                JSONObject(raw)
            } catch (t: Throwable) {
                Log.e(TAG, "widget json parse failed", t)
                null
            }
        }

        private fun readPath(context: Context, keys: Array<String>): String? {
            for (k in keys) {
                val path = prefs(context).getString(k, null)
                if (!path.isNullOrEmpty() && File(path).exists()) return path
            }
            return null
        }

        private fun readCarImagePath(context: Context): String? =
            readPath(
                context,
                arrayOf(KEY_WIDGET_CAR_IMAGE, KEY_WIDGET_CAR_IMAGE_BARE, KEY_CAR_IMAGE, KEY_CAR_IMAGE_BARE),
            )

        private fun readBgPath(context: Context): String? =
            readPath(context, arrayOf(KEY_WIDGET_BG, KEY_WIDGET_BG_BARE))

        private fun readBgAlpha(context: Context): Int {
            // Flutter shared_preferences 把 Dart int 写成 Long，getInt 会 ClassCastException
            val p = prefs(context)
            fun asInt(v: Any?): Int? = when (v) {
                is Int -> v
                is Long -> v.toInt()
                is Float -> v.toInt()
                is Double -> v.toInt()
                is String -> v.toIntOrNull()
                else -> null
            }
            val raw = asInt(p.all[KEY_WIDGET_BG_ALPHA])?.takeIf { it >= 0 }
                ?: asInt(p.all[KEY_WIDGET_BG_ALPHA_BARE])?.takeIf { it >= 0 }
                ?: 255
            return raw.coerceIn(0, 255)
        }

        private fun render(context: Context, mgr: AppWidgetManager, widgetId: Int) {
            val views = RemoteViews(context.packageName, R.layout.mymg_widget_home)
            val data = readJson(context)

            val bgPath = readBgPath(context)
            val bgAlpha = readBgAlpha(context)
            if (bgPath != null) {
                try {
                    val bmp = BitmapFactory.decodeFile(bgPath)
                    if (bmp != null) {
                        views.setImageViewBitmap(R.id.widget_bg, bmp)
                        views.setInt(R.id.widget_bg, "setAlpha", bgAlpha)
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "bg load failed: $bgPath", t)
                }
            } else {
                views.setInt(R.id.widget_bg, "setAlpha", bgAlpha)
            }

            val carPath = readCarImagePath(context)
            if (carPath != null) {
                try {
                    val bmp = BitmapFactory.decodeFile(carPath)
                    if (bmp != null) {
                        views.setImageViewBitmap(R.id.widget_car, bmp)
                        views.setViewVisibility(R.id.widget_car, android.view.View.VISIBLE)
                    } else {
                        views.setViewVisibility(R.id.widget_car, android.view.View.GONE)
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "car image load failed: $carPath", t)
                    views.setViewVisibility(R.id.widget_car, android.view.View.GONE)
                }
            } else {
                // 未设置车图则不显示
                views.setViewVisibility(R.id.widget_car, android.view.View.GONE)
            }

            if (data == null) {
                views.setTextViewText(R.id.widget_fuel, "--")
                views.setTextViewText(R.id.widget_range, "--")
                views.setTextViewText(R.id.widget_chip_lock_text, "锁 —")
                views.setTextViewText(R.id.widget_chip_door_text, "门 —")
                views.setTextViewText(R.id.widget_chip_window_text, "窗 —")
                views.setTextViewText(R.id.widget_chip_ac_text, "空调 —")
                views.setProgressBar(R.id.widget_fuel_bar, 100, 0, false)
            } else {
                val fuel = optInt(data, "fuel")
                val range = optInt(data, "range")
                views.setTextViewText(R.id.widget_fuel, fuel?.toString() ?: "--")
                views.setTextViewText(R.id.widget_range, range?.toString() ?: "--")
                views.setProgressBar(R.id.widget_fuel_bar, 100, fuel ?: 0, false)

                // 中央：车内（左）/ 车外（右）— 图标+框
                val interior = data.opt("interior")
                val exterior = data.opt("exterior")
                fun fmtTemp(v: Any?): String = when (v) {
                    is Number -> String.format("%.0f°C", v.toDouble())
                    else -> "--°C"
                }
                views.setTextViewText(R.id.widget_temp_in, "车内 ${fmtTemp(interior)}")
                views.setTextViewText(R.id.widget_temp_out, "车外 ${fmtTemp(exterior)}")

                val locked = optBool(data, "locked")
                val doors = optBool(data, "doors")
                val windows = optBool(data, "windows")
                val ac = optBool(data, "ac")

                views.setTextViewText(
                    R.id.widget_chip_lock_text,
                    when (locked) {
                        true -> "已锁"
                        false -> "未锁"
                        else -> "锁 —"
                    },
                )
                views.setTextViewText(
                    R.id.widget_chip_door_text,
                    when (doors) {
                        true -> "关"
                        false -> "开"
                        else -> "门 —"
                    },
                )
                views.setTextViewText(
                    R.id.widget_chip_window_text,
                    when (windows) {
                        true -> "关"
                        false -> "开"
                        else -> "窗 —"
                    },
                )
                views.setTextViewText(
                    R.id.widget_chip_ac_text,
                    when (ac) {
                        true -> "空调 开"
                        false -> "空调 关"
                        else -> "空调 —"
                    },
                )
            }

            val open = Intent(context, MainActivity::class.java).apply {
                action = ACTION_WIDGET_OPEN
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val openPi = PendingIntent.getActivity(
                context,
                widgetId,
                open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            // 根可点进 App；控车钮单独悬浮在右上，不受内容行影响
            views.setOnClickPendingIntent(R.id.widget_root, openPi)

            // 右上角控车按钮 → 打开控车弹窗（quick_control）
            val ctrl = Intent(context, QuickControlActivity::class.java).apply {
                action = MainActivity.ACTION_QS_CONTROL
                // 控制中心式：只弹弹窗，不进 App 前台栈
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION or
                    Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val ctrlPi = PendingIntent.getActivity(
                context,
                widgetId * 10 + 1,
                ctrl,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_btn_control, ctrlPi)

            mgr.updateAppWidget(widgetId, views)
        }

        private fun optInt(o: JSONObject, k: String): Int? =
            if (o.has(k) && !o.isNull(k)) o.optInt(k) else null

        private fun optBool(o: JSONObject, k: String): Boolean? =
            if (o.has(k) && !o.isNull(k)) o.optBoolean(k) else null
    }
}
