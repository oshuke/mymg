package com.mymg.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel

object BlePermissionController {
    private val requests = BlePermissionRequests<Activity>()

    private fun requiredPermissions(): List<String> = buildList {
        if (Build.VERSION.SDK_INT >= 31) {
            add(Manifest.permission.BLUETOOTH_SCAN)
            add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        // The existing manifest does not assert neverForLocation for BLE scans.
        if (Build.VERSION.SDK_INT >= 23) add(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    fun hasPermissions(context: Context): Boolean = requiredPermissions().all {
        context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    fun request(activity: Activity, result: MethodChannel.Result) {
        if (activity.isFinishing || activity.isDestroyed) {
            result.success(false)
            return
        }
        requests.request(
            activity,
            { hasPermissions(activity) },
            { code ->
                val permissions = requiredPermissions().toMutableList()
                // Android 12+ requires coarse and fine to be requested together.
                permissions.add(Manifest.permission.ACCESS_COARSE_LOCATION)
                activity.requestPermissions(permissions.toTypedArray(), code)
            },
            { granted -> result.success(granted) },
        )
    }

    fun onResult(
        activity: Activity,
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean = requests.onResult(
        activity,
        requestCode,
        grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED } &&
            hasPermissions(activity),
    )

    fun detach(activity: Activity) = requests.detach(activity)

    fun openAppSettings(activity: Activity, result: MethodChannel.Result) {
        try {
            activity.startActivity(Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", activity.packageName, null),
            ))
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }
}
