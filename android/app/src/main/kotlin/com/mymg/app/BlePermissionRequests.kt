package com.mymg.app

/** Main-thread request lifecycle, shared across Activity/FlutterEngine owners. */
class BlePermissionRequests<Owner : Any> {
    private var owner: Owner? = null
    private var code: Int? = null
    private var serial = 4320
    private val waiters = mutableListOf<Pair<Owner, (Boolean) -> Unit>>()

    fun request(
        requester: Owner,
        hasPermissions: () -> Boolean,
        launch: (Int) -> Unit,
        reply: (Boolean) -> Unit,
    ) {
        if (code != null) {
            waiters.add(requester to reply)
            return
        }
        if (hasPermissions()) {
            reply(true)
            return
        }
        owner = requester
        serial = if (serial >= 65000) 4321 else serial + 1
        code = serial
        waiters.add(requester to reply)
        try {
            launch(serial)
        } catch (_: Exception) {
            finish(false)
        }
    }

    fun onResult(requester: Owner, requestCode: Int, granted: Boolean): Boolean {
        if (owner !== requester || code != requestCode) return false
        finish(granted)
        return true
    }

    fun detach(requester: Owner) {
        if (owner === requester) {
            finish(false)
            return
        }
        val removed = waiters.filter { it.first === requester }
        waiters.removeAll(removed.toSet())
        removed.forEach { safelyReply(it.second, false) }
    }

    private fun finish(granted: Boolean) {
        val completed = waiters.toList()
        waiters.clear()
        owner = null
        code = null
        completed.forEach { safelyReply(it.second, granted) }
    }

    private fun safelyReply(reply: (Boolean) -> Unit, granted: Boolean) {
        try {
            reply(granted)
        } catch (_: Exception) {
            // A destroyed engine must not strand the remaining engines.
        }
    }
}
