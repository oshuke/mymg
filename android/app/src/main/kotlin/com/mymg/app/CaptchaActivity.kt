package com.mymg.app

import android.annotation.SuppressLint
import android.app.Dialog
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.Toast

/**
 * 易盾滑块：透明全屏 Activity 承载居中悬浮卡片（不是单独全屏页）。
 * 成功 → 立刻 finish + pendingValidate；取消/失败 → pendingError。
 */
class CaptchaActivity : android.app.Activity() {
    companion object {
        const val EXTRA_CAPTCHA_ID = "captcha_id"
        @Volatile var pendingValidate: String? = null
        @Volatile var pendingError: String? = null
        @Volatile var resultReady: Boolean = false
    }

    private var finished = false
    private var root: FrameLayout? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 半透明背景 + 居中卡片，视觉上是悬浮弹窗
        val container = FrameLayout(this).apply {
            setBackgroundColor(Color.parseColor("#66000000"))
        }
        root = container
        setContentView(container)

        val captchaId = intent.getStringExtra(EXTRA_CAPTCHA_ID).orEmpty()
        if (captchaId.isEmpty()) {
            finishWith("已取消：未提供 captchaId")
            return
        }

        pendingValidate = null
        pendingError = null
        resultReady = false

        val wv = WebView(this)
        // 真正垂直+水平居中
        val lp = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            android.view.Gravity.CENTER,
        )
        lp.width = (resources.displayMetrics.widthPixels * 0.96).toInt()
            .coerceAtMost(560)
            .coerceAtLeast(340)
        container.addView(wv, lp)

        wv.settings.javaScriptEnabled = true
        wv.settings.domStorageEnabled = true
        wv.settings.mediaPlaybackRequiresUserGesture = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            wv.settings.safeBrowsingEnabled = true
        }
        wv.setBackgroundColor(Color.TRANSPARENT)
        wv.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?,
            ): Boolean = false
        }
        wv.addJavascriptInterface(Bridge(), "CaptchaBridge")

        // 点遮罩关闭
        container.setOnClickListener { finishWith("已取消") }

        try {
            val html = assets.open("captcha.html").bufferedReader().use { it.readText() }
            val safeId = captchaId.replace("\"", "").replace("'", "")
            val page = html.replace(
                "<script src=",
                "<script>window.__pendingCaptchaId=\"$safeId\";</script><script src=",
            )
            wv.loadDataWithBaseURL(
                "https://cstaticdun.126.net/",
                page,
                "text/html",
                "utf-8",
                null,
            )
        } catch (e: Throwable) {
            finishWith("滑块初始化失败：${e.message}")
        }
    }

    override fun onBackPressed() {
        if (!finished) finishWith("已取消")
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    private fun finishWith(msg: String) {
        if (finished) return
        finished = true
        pendingValidate = null
        pendingError = msg
        resultReady = true
        runOnUiThread {
            Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
            finish()
        }
    }

    private fun finishOk(validate: String) {
        if (finished) return
        finished = true
        pendingValidate = validate
        pendingError = null
        resultReady = true
        runOnUiThread {
            Toast.makeText(this, "验证成功", Toast.LENGTH_SHORT).show()
            // 稍等再关，让用户看到成功提示，然后回到登录页继续发码
            root?.postDelayed({ finish() }, 400)
        }
    }

    private inner class Bridge {
        @JavascriptInterface
        fun onReady() {
            // no-op：状态文案已在 HTML 里
        }

        @JavascriptInterface
        fun onResult(validate: String) {
            val v = validate.trim()
            if (v.isEmpty()) {
                finishWith("滑块未返回 validate")
                return
            }
            finishOk(v)
        }

        @JavascriptInterface
        fun onCancel(msg: String?) {
            val m = msg?.takeIf { it.isNotBlank() && it != "null" }
            finishWith(if (m != null) "已取消（$m）" else "已取消")
        }

        @JavascriptInterface
        fun onError(msg: String) {
            finishWith("滑块异常：$msg")
        }
    }
}
