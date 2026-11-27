package io.github.beomyo.purer.channel

import java.net.HttpURLConnection
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

// thrown inside a transfer's copy loop when the user pressed cancel
class TransferCancelledException : Exception("transfer cancelled")

// Tracks user-triggered remote transfers (save to phone / share) so the progress
// dialog's cancel button can stop the underlying HTTP download instead of
// leaving it running invisibly in the background.
object CloudTransferRegistry {
    private val cancelled = ConcurrentHashMap<String, AtomicBoolean>()
    private val connections = ConcurrentHashMap<String, HttpURLConnection>()

    // returns the id's flag, preserving a cancellation that arrived before the
    // transfer got as far as registering (e.g. the picker was still open)
    fun register(id: String): AtomicBoolean {
        val existing = cancelled[id]
        if (existing != null) return existing
        val flag = AtomicBoolean(false)
        cancelled[id] = flag
        return flag
    }

    fun attach(id: String?, connection: HttpURLConnection) {
        if (id == null) return
        connections[id] = connection
        // the user may have cancelled while the connection was being opened
        if (cancelled[id]?.get() == true) connection.disconnect()
    }

    fun isCancelled(id: String?): Boolean = id != null && cancelled[id]?.get() == true

    fun cancel(id: String) {
        val existing = cancelled[id]
        val flag = existing ?: AtomicBoolean(false).also { cancelled[id] = it }
        flag.set(true)
        connections[id]?.disconnect()
    }

    fun release(id: String?) {
        if (id == null) return
        cancelled.remove(id)
        connections.remove(id)
    }
}
