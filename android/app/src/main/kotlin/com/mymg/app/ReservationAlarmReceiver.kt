package com.mymg.app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * 预约控车：AlarmManager 精准到点 → 拉起 MainActivity 执行。
 *
 * WorkManager 最小 delay 约 9~15 分钟且可被省电饿死；
 * AlarmManager.setExactAndAllowWhileIdle 在锁屏/Doze 下更可靠。
 */
class ReservationAlarmReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "MymgResAlarm"
        const val ACTION_RUN = "com.mymg.app.RUN_RESERVATION"
        private const val REQ_CODE = 0x72657

        fun pendingIntent(context: Context): PendingIntent {
            val intent = Intent(context, ReservationAlarmReceiver::class.java).apply {
                action = ACTION_RUN
            }
            return PendingIntent.getBroadcast(
                context,
                REQ_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        fun cancel(context: Context) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.cancel(pendingIntent(context))
        }

        /** 设置精确闹钟（到点拉起 App 执行预约） */
        fun schedule(context: Context, triggerAtMs: Long) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pi = pendingIntent(context)
            val trigger = triggerAtMs.coerceAtLeast(System.currentTimeMillis() + 5_000L)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
                } else {
                    am.setExact(AlarmManager.RTC_WAKEUP, trigger, pi)
                }
                Log.i(TAG, "scheduled exact alarm at $trigger")
            } catch (e: SecurityException) {
                // 无 SCHEDULE_EXACT_ALARM 时降级为非精确
                Log.w(TAG, "exact alarm denied, fallback set(): $e")
                am.set(AlarmManager.RTC_WAKEUP, trigger, pi)
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION_RUN) return
        Log.i(TAG, "alarm fired, launching MainActivity for reservation")
        // 把「应执行预约」写进 prefs，Flutter 侧读取后跑 runReservationOnce
        context.getSharedPreferences("mymg_alarm", Context.MODE_PRIVATE)
            .edit()
            .putLong("pending_res_at", System.currentTimeMillis())
            .apply()

        val launch = Intent(context, MainActivity::class.java).apply {
            action = ACTION_RUN
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            )
        }
        try {
            context.startActivity(launch)
        } catch (e: Throwable) {
            Log.e(TAG, "startActivity failed: $e")
        }
    }
}
