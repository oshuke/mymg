package com.mymg.app

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * 小组件/磁贴入口闸门。
 * 有悬浮窗权限则无黑底弹层；否则回退 QuickControlActivity（透明）。
 * 绝不拉起 MainActivity 主页。
 */
class OverlayGateActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            val ok = try {
                ControlOverlay.show(this)
            } catch (t: Throwable) {
                android.util.Log.e("MYMG.Gate", "overlay fail", t)
                false
            }
            if (ok) {
                finish()
                return
            }
            // 无悬浮窗权限：跳授权 + 透明弹窗（不进主页）
            try {
                startActivity(ControlOverlay.permissionIntent(this))
            } catch (_: Throwable) {}
            val next = Intent(this, QuickControlActivity::class.java).apply {
                action = MainActivity.ACTION_QS_CONTROL
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
            }
            startActivity(next)
        } catch (t: Throwable) {
            android.util.Log.e("MYMG.Gate", "gate fail", t)
        }
        finish()
    }
}