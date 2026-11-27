package io.github.beomyo.purer.channel.streams.darttoplatform

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.github.beomyo.purer.MainActivity
import io.github.beomyo.purer.PendingStorageAccessResultHandler
import io.github.beomyo.purer.channel.CloudTransferRegistry
import io.github.beomyo.purer.channel.TransferCancelledException
import io.github.beomyo.purer.channel.streams.BaseStreamHandler
import io.github.beomyo.purer.storage.StorageUtils
import io.github.beomyo.purer.storage.StorageUtils.ensureTrailingSeparator
import io.github.beomyo.purer.utils.LogUtils
import io.github.beomyo.purer.utils.MimeTypes
import kotlinx.coroutines.launch
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

// starting an activity to get a result (e.g. the system file picker for
// exporting/importing browsing progress) breaks the regular `MethodChannel`,
// so a stream channel is used instead
class ActivityResultStreamHandler(private val activity: Activity, arguments: Any?) : BaseStreamHandler() {
    private var op: String? = null
    private lateinit var args: Map<*, *>

    init {
        if (arguments is Map<*, *>) {
            op = arguments["op"] as String?
            args = arguments
        }
    }

    override val logTag = LOG_TAG

    override fun onCall(args: Any?) {
        // do not automatically close the stream when launching the activity,
        // as it will be closed when the result comes back
        val closeStream = false
        when (op) {
            "createFile" -> ioScope.launch { safe(::createFile, closeStream) }
            "openFile" -> ioScope.launch { safe(::openFile, closeStream) }
            "downloadUrl" -> ioScope.launch { safe(::downloadUrl, closeStream) }
            else -> endOfStream()
        }
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        super.error(errorCode, errorMessage, errorDetails)
        endOfStream()
    }

    private fun safeStartActivityForStorageAccessResult(intent: Intent, requestCode: Int, onGranted: (uri: Uri) -> Unit, onDenied: () -> Unit) {
        if (intent.resolveActivity(activity.packageManager) != null) {
            MainActivity.pendingStorageAccessResultHandlers[requestCode] = PendingStorageAccessResultHandler(null, onGranted, onDenied)
            try {
                activity.startActivityForResult(intent, requestCode)
            } catch (_: SecurityException) {
                MainActivity.notifyError("failed to start activity for intent=$intent extras=${intent.extras}")
                onDenied()
            }
        } else {
            MainActivity.notifyError("failed to resolve activity for intent=$intent extras=${intent.extras}")
            onDenied()
        }
    }

    private fun createFile() {
        val dirPath = args["dirPath"] as String?
        val name = args["name"] as String?
        val mimeType = args["mimeType"] as String?
        val bytes = args["bytes"] as ByteArray?
        if (name == null || mimeType == null || bytes == null) {
            error("createFile-args", "missing arguments", null)
            return
        }

        fun onGranted(uri: Uri) {
            ioScope.launch {
                try {
                    // truncate is necessary when overwriting a longer file
                    activity.contentResolver.openOutputStream(uri, "wt")?.use { output ->
                        output.write(bytes)
                    }
                    success(true)
                    endOfStream()
                } catch (ex: Exception) {
                    error("createFile-write", "failed to write file at uri=$uri", ex.message)
                }
            }
        }

        fun onDenied() {
            success(null)
            endOfStream()
        }

        if (dirPath != null) {
            // save to provided directory
            val filePath = ensureTrailingSeparator(dirPath) + name
            val docFile = StorageUtils.getDocumentFileForNewFile(activity, filePath = filePath, mimeType = mimeType)
            if (docFile != null) {
                onGranted(docFile.uri)
            } else {
                onDenied()
            }
        } else {
            // save to user selected directory
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mimeType
                putExtra(Intent.EXTRA_TITLE, name)
            }
            safeStartActivityForStorageAccessResult(intent, MainActivity.CREATE_FILE_REQUEST, ::onGranted, ::onDenied)
        }
    }

    // streams a remote file (WebDAV over HTTP) to
    // the user selected document. Downloading on the platform side keeps a
    // large video out of the Dart heap.
    private fun downloadUrl() {
        val url = args["url"] as String?
        val name = args["name"] as String?
        val mimeType = args["mimeType"] as String?
        val transferId = args["transferId"] as String?
        @Suppress("UNCHECKED_CAST")
        val headers = args["headers"] as? Map<*, *>
        if (url == null || name == null || mimeType == null) {
            error("downloadUrl-args", "missing arguments", null)
            return
        }

        fun onGranted(uri: Uri) {
            ioScope.launch {
                var connection: HttpURLConnection? = null
                val cancelFlag = transferId?.let { CloudTransferRegistry.register(it) }
                try {
                    val output = activity.contentResolver.openOutputStream(uri, "wt")
                        ?: throw IOException("failed to open output stream")
                    output.use { sink ->
                        connection = (URL(url).openConnection() as HttpURLConnection).apply {
                            connectTimeout = 30000
                            readTimeout = 120000
                            requestMethod = "GET"
                            headers?.forEach { (key, value) ->
                                if (key is String && value is String) setRequestProperty(key, value)
                            }
                        }
                        val conn = connection!!
                        CloudTransferRegistry.attach(transferId, conn)
                        val code = conn.responseCode
                        if (code >= 400) throw IOException("HTTP $code")
                        val total = conn.contentLengthLong
                        var copied = 0L
                        var reportedAt = 0L
                        conn.inputStream.use { input ->
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                if (cancelFlag?.get() == true) throw TransferCancelledException()
                                val read = input.read(buffer)
                                if (read < 0) break
                                sink.write(buffer, 0, read)
                                copied += read
                                // feed the progress dialog, but keep the event flood
                                // bounded on slow links
                                val now = System.currentTimeMillis()
                                if (now - reportedAt >= 200) {
                                    reportedAt = now
                                    success(mapOf("progress" to copied, "total" to total))
                                }
                            }
                        }
                        if (cancelFlag?.get() == true) throw TransferCancelledException()
                    }
                    success(true)
                    endOfStream()
                } catch (_: TransferCancelledException) {
                    deletePartialDocument(uri)
                    success(null)
                    endOfStream()
                } catch (ex: Exception) {
                    if (cancelFlag?.get() == true) {
                        deletePartialDocument(uri)
                        success(null)
                        endOfStream()
                    } else {
                        error("downloadUrl-write", "failed to download $url", ex.message)
                    }
                } finally {
                    connection?.disconnect()
                    CloudTransferRegistry.release(transferId)
                }
            }
        }

        fun onDenied() {
            success(null)
            endOfStream()
        }

        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, name)
        }
        safeStartActivityForStorageAccessResult(intent, MainActivity.DOWNLOAD_FILE_REQUEST, ::onGranted, ::onDenied)
    }

    // a cancelled transfer must not leave a truncated file behind in the folder
    // the user picked
    private fun deletePartialDocument(uri: Uri) {
        try {
            activity.contentResolver.delete(uri, null, null)
        } catch (_: Exception) {
            // best effort: the platform may not allow deleting the document
        }
    }

    private fun openFile() {
        val mimeType = args["mimeType"] as String? // optional

        fun onGranted(uri: Uri) {
            ioScope.launch {
                try {
                    activity.contentResolver.openInputStream(uri)?.use(::streamBytes)
                    endOfStream()
                } catch (ex: Exception) {
                    error("openFile-read", "failed to read file at uri=$uri", ex.message)
                }
            }
        }

        fun onDenied() {
            success(ByteArray(0))
            endOfStream()
        }

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            setTypeAndNormalize(mimeType ?: MimeTypes.ANY)
        }
        safeStartActivityForStorageAccessResult(intent, MainActivity.OPEN_FILE_REQUEST, ::onGranted, ::onDenied)
    }

    companion object {
        private val LOG_TAG = LogUtils.createTag<ActivityResultStreamHandler>()
        const val CHANNEL = "io.github.beomyo/purer/activity_result_stream"
    }
}
