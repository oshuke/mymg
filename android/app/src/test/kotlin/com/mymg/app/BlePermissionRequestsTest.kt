package com.mymg.app

// Standalone JVM regression runner: no Android/device, keys or new test dependency.
fun main() {
    var passed = 0
    fun test(name: String, body: () -> Unit) {
        body()
        passed++
        println("PASS $name")
    }

    test("both engines wait for one real result") {
        val queue = BlePermissionRequests<Any>()
        val main = Any()
        val quick = Any()
        val replies = mutableListOf<Boolean>()
        val launches = mutableListOf<Int>()
        queue.request(main, { false }, { launches.add(it) }, { replies.add(it) })
        queue.request(quick, { false }, { error("duplicate dialog") }, { replies.add(it) })
        check(replies.isEmpty()) { "must not report success before callback" }
        check(launches.size == 1)
        check(!queue.onResult(quick, launches.single(), true))
        check(!queue.onResult(main, 1, true))
        check(replies.isEmpty())
        check(queue.onResult(main, launches.single(), true))
        check(replies == listOf(true, true))
        check(!queue.onResult(main, launches.single(), true))
    }

    test("denial and retry start a fresh request") {
        val queue = BlePermissionRequests<Any>()
        val owner = Any()
        val replies = mutableListOf<Boolean>()
        var code = 0
        queue.request(owner, { false }, { code = it }, { replies.add(it) })
        val deniedCode = code
        queue.onResult(owner, code, false)
        check(replies == listOf(false))
        queue.request(owner, { false }, { code = it }, { replies.add(it) })
        check(code != deniedCode)
        check(!queue.onResult(owner, deniedCode, true))
        check(replies == listOf(false))
        queue.onResult(owner, code, true)
        check(replies == listOf(false, true))
    }

    test("already granted never opens a dialog") {
        val queue = BlePermissionRequests<Any>()
        var granted = false
        queue.request(Any(), { true }, { error("unnecessary dialog") }, { granted = it })
        check(granted)
    }

    test("owner destruction releases both engine waiters and allows retry") {
        val queue = BlePermissionRequests<Any>()
        val owner = Any()
        val other = Any()
        val replies = mutableListOf<Boolean>()
        var code = 0
        queue.request(owner, { false }, { code = it }, { replies.add(it) })
        queue.request(other, { false }, { error("duplicate dialog") }, { replies.add(it) })
        val stale = code
        queue.detach(owner)
        check(replies == listOf(false, false))
        queue.request(other, { false }, { code = it }, { replies.add(it) })
        check(!queue.onResult(owner, stale, true))
        check(queue.onResult(other, code, true))
        check(replies == listOf(false, false, true))
    }

    test("destroying a waiting engine leaves the owner request intact") {
        val queue = BlePermissionRequests<Any>()
        val owner = Any()
        val waiter = Any()
        val replies = mutableListOf<String>()
        var code = 0
        queue.request(owner, { false }, { code = it }, { replies.add("owner:$it") })
        queue.request(waiter, { false }, { error("duplicate dialog") }, { replies.add("waiter:$it") })
        queue.detach(waiter)
        check(replies == listOf("waiter:false"))
        queue.onResult(owner, code, true)
        check(replies == listOf("waiter:false", "owner:true"))
    }

    test("launch exception releases pending state") {
        val queue = BlePermissionRequests<Any>()
        val replies = mutableListOf<Boolean>()
        queue.request(Any(), { false }, { throw IllegalStateException() }, { replies.add(it) })
        queue.request(Any(), { true }, { error("unexpected dialog") }, { replies.add(it) })
        check(replies == listOf(false, true))
    }

    test("one disconnected engine cannot prevent other replies") {
        val queue = BlePermissionRequests<Any>()
        val owner = Any()
        var code = 0
        var replied = false
        queue.request(owner, { false }, { code = it }, { throw IllegalStateException() })
        queue.request(Any(), { false }, { error("duplicate dialog") }, { replied = it })
        queue.onResult(owner, code, true)
        check(replied)
    }

    println("$passed native permission regressions passed")
}
