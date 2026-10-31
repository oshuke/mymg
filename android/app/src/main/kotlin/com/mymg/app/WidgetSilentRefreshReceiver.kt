package com.mymg.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.BackgroundWorker
import java.util.concurrent.TimeUnit

/**
 * 小组件「↻」真静默刷新：
 * 点桌面按钮只发广播 → 不启动 Activity/主页。
 * 立即标记刷新中，再把 WorkManager 一次性任务排到 Flutter 侧
 * （callbackDispatcher 已处理 mymg.fetch：拉车况 + 写小组件数据槽）。
 * 任务结束后清刷新态并重绘小组件。
 */
class WidgetSilentRefreshReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION = "com.mymg.app.WIDGET_SILENT_REFRESH"
        private const val TAG = "MYMG.WidgetRefresh"
        private const val UNIQUE = "mymg.bg.fetch.once"
        private const val DART_TASK_FETCH = "mymg.fetch"
        private const val TIMEOUT_MS = 70_000L
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION) return
        Log.i(TAG, "silent refresh requested")

        try {
            MymgWidgetProvider.setRefreshing(context, true)
        } catch (t: Throwable) {
            Log.e(TAG, "setRefreshing(true) failed", t)
        }

        val pending = goAsync()
        Thread {
            var launched = false
            try {
                val wm = WorkManager.getInstance(context)
                val data = Data.Builder()
                    .putString(BackgroundWorker.DART_TASK_KEY, DART_TASK_FETCH)
                    .build()
                val constraints = Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build()
                val req = OneTimeWorkRequestBuilder<BackgroundWorker>()
                    .setInputData(data)
                    .setConstraints(constraints)
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .build()
                wm.enqueueUniqueWork(UNIQUE, ExistingWorkPolicy.REPLACE, req)
                launched = true
                Log.i(TAG, "enqueued work id=${req.id}")

                val deadline = System.currentTimeMillis() + TIMEOUT_MS
                var info = wm.getWorkInfoById(req.id).get(10, TimeUnit.SECONDS)
                while (info != null &&
                    !info.state.isFinished &&
                    System.currentTimeMillis() < deadline
                ) {
                    Thread.sleep(400)
                    info = wm.getWorkInfoById(req.id).get()
                }
                Log.i(TAG, "work done state=${info?.state}")
            } catch (t: Throwable) {
                Log.e(TAG, "WorkManager silent refresh failed", t)
                // 回退：WorkManager 不可用时才拉透明壳，保证刷新仍可用
                if (!launched) {
                    try {
                        val fallback = Intent(context, WidgetRefreshActivity::class.java).apply {
                            action = WidgetRefreshActivity.ACTION
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                Intent.FLAG_ACTIVITY_NO_ANIMATION
                        }
                        context.startActivity(fallback)
                    } catch (_: Throwable) {
                    }
                }
            } finally {
                try {
                    MymgWidgetProvider.setRefreshing(context, false)
                } catch (_: Throwable) {
                }
                pending.finish()
            }
        }.start()
    }
}
