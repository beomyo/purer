package io.github.beomyo.purer.channel.calls

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import io.github.beomyo.purer.channel.CloudTransferRegistry
import io.github.beomyo.purer.channel.TransferCancelledException
import io.github.beomyo.purer.channel.calls.Coresult.Companion.safe
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

// Shares a remote file (WebDAV over HTTP) through
// the system chooser. The file is streamed into the app cache, then handed to
// the chooser as a FileProvider URI, so a large video never has to be held in
// memory.
class ShareHandler(private val context: Context) : MethodCallHandler {
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "shareUrl" -> ioScope.launch { safe(call, result, ::shareUrl) }
            "cancelShare" -> ioScope.launch {
                val id = call.argument<String>("id")
                if (id == null) {
                    result.error("cancelShare-args", "missing arguments", null)
                } else {
                    CloudTransferRegistry.cancel(id)
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun shareUrl(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val name = call.argument<String>("name")
        val mimeType = call.argument<String>("mimeType") ?: "*/*"
        val headers = call.argument<Map<String, String>>("headers")
        val transferId = call.argument<String>("transferId")
        if (url == null || name == null) {
            result.error("shareUrl-args", "missing arguments", null)
            return
        }
        var connection: HttpURLConnection? = null
        var file: File? = null
        val cancelFlag = transferId?.let { CloudTransferRegistry.register(it) }
        try {
            val dir = File(context.cacheDir, "share")
            if (!dir.exists() && !dir.mkdirs()) throw IOException("failed to create share dir")
            // do not let copies of shared files pile up in the cache forever
            val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
            dir.listFiles()?.forEach { entry ->
                if (entry.isFile && entry.lastModified() < cutoff) entry.delete()
            }
            val target = File(dir, sanitize(name))
            file = target
            val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 30000
                readTimeout = 120000
                requestMethod = "GET"
                headers?.forEach { (key, value) -> setRequestProperty(key, value) }
            }
            connection = conn
            CloudTransferRegistry.attach(transferId, conn)
            val code = conn.responseCode
            if (code >= 400) throw IOException("HTTP $code")
            conn.inputStream.use { input ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        if (cancelFlag?.get() == true) throw TransferCancelledException()
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                    }
                }
            }
            if (cancelFlag?.get() == true) throw TransferCancelledException()
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", target)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(intent, null).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(chooser)
            result.success(true)
        } catch (_: TransferCancelledException) {
            file?.delete()
            result.success(null)
        } catch (e: Exception) {
            if (cancelFlag?.get() == true) {
                file?.delete()
                result.success(null)
            } else {
                result.error("shareUrl-failed", e.message, null)
            }
        } finally {
            connection?.disconnect()
            CloudTransferRegistry.release(transferId)
        }
    }

    private fun sanitize(name: String): String {
        val cleaned = name.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]"), "_").trim()
        return if (cleaned.isEmpty()) "shared" else cleaned.take(200)
    }

    companion object {
        const val CHANNEL = "io.github.beomyo/purer/share"
    }
}
