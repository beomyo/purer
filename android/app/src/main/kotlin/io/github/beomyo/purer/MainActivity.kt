package io.github.beomyo.purer

import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import app.loup.streams_channel.StreamsChannel
import io.github.beomyo.purer.channel.calls.AccessibilityHandler
import io.github.beomyo.purer.channel.calls.DeviceHandler
import io.github.beomyo.purer.channel.calls.MediaFetchObjectHandler
import io.github.beomyo.purer.channel.calls.ShareHandler
import io.github.beomyo.purer.channel.calls.StorageHandler
import io.github.beomyo.purer.channel.calls.window.ActivityWindowHandler
import io.github.beomyo.purer.channel.calls.window.WindowHandler
import io.github.beomyo.purer.channel.streams.darttoplatform.ActivityResultStreamHandler
import io.github.beomyo.purer.channel.streams.darttoplatform.ImageByteStreamHandler
import io.github.beomyo.purer.channel.streams.platformtodart.MessageStreamHandler
import io.github.beomyo.purer.channel.streams.platformtodart.WindowChangeStreamHandler
import io.github.beomyo.purer.storage.apis.SafPermissions
import io.github.beomyo.purer.utils.LogUtils
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap

// The cloud-only app has no local media library: the activity only hosts the
// Flutter UI and the platform channels the remote browsing path uses (remote
// thumbnails/decoding, file pickers for progress import/export, window helpers).
open class MainActivity : FlutterFragmentActivity() {
    private lateinit var windowChangeStreamHandler: WindowChangeStreamHandler

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        ViewCompat.setOnApplyWindowInsetsListener(window.decorView) { view, windowInsets ->
            val insets = ViewCompat.onApplyWindowInsets(view, windowInsets)
            onWindowInsetsChanged(windowInsets)
            insets
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor

        // notification: platform -> dart
        messageStreamHandler = MessageStreamHandler().apply {
            EventChannel(messenger, MessageStreamHandler.CHANNEL).setStreamHandler(this)
        }
        windowChangeStreamHandler = WindowChangeStreamHandler().apply {
            EventChannel(messenger, WindowChangeStreamHandler.CHANNEL).setStreamHandler(this)
        }

        // dart -> platform
        MethodChannel(messenger, AccessibilityHandler.CHANNEL).setMethodCallHandler(AccessibilityHandler(this))
        MethodChannel(messenger, DeviceHandler.CHANNEL).setMethodCallHandler(DeviceHandler(this))
        MethodChannel(messenger, MediaFetchObjectHandler.CHANNEL).setMethodCallHandler(MediaFetchObjectHandler(this))
        MethodChannel(messenger, ShareHandler.CHANNEL).setMethodCallHandler(ShareHandler(this))
        MethodChannel(messenger, StorageHandler.CHANNEL).setMethodCallHandler(StorageHandler(this))
        // - need Activity
        MethodChannel(messenger, WindowHandler.CHANNEL).setMethodCallHandler(ActivityWindowHandler(this))

        // result streaming: dart -> platform ->->-> dart
        // - need Context
        StreamsChannel(messenger, ImageByteStreamHandler.CHANNEL).setStreamHandlerFactory { args -> ImageByteStreamHandler(this, args) }
        // - need Activity
        StreamsChannel(messenger, ActivityResultStreamHandler.CHANNEL).setStreamHandlerFactory { args -> ActivityResultStreamHandler(this, args) }
    }

    override fun onStart() {
        Log.i(LOG_TAG, "onStart")
        super.onStart()

        // as of Flutter v3.0.1, the window `viewInsets` and `viewPadding`
        // are incorrect on startup in some environments (e.g. API 29 emulator),
        // so we manually request to apply the insets to update the window metrics
        Handler(Looper.getMainLooper()).postDelayed({
            window.decorView.requestApplyInsets()
        }, 100)
    }

    override fun onDestroy() {
        Log.i(LOG_TAG, "onDestroy")
        try {
            super.onDestroy()
        } catch (e: Exception) {
            // on Android 11, the app may crash while destroying the activity
            // cf https://issuetracker.google.com/issues/175055271
            Log.e(LOG_TAG, "failed while destroying activity", e)
        }
    }

    @Deprecated("Deprecated in android.app.Activity")
    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean) {
        @Suppress("DEPRECATION")
        super.onMultiWindowModeChanged(isInMultiWindowMode)
        notifyWindowModeChange()
    }

    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean, newConfig: Configuration) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)
        notifyWindowModeChange()
    }

    @Deprecated("Deprecated in android.app.Activity")
    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean) {
        @Suppress("DEPRECATION")
        super.onPictureInPictureModeChanged(isInPictureInPictureMode)
        notifyWindowModeChange()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        notifyWindowModeChange()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        Log.i(LOG_TAG, "onActivityResult requestCode=$requestCode resultCode=$resultCode")
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            DOCUMENT_TREE_ACCESS_REQUEST -> onDocumentTreeAccessResult(requestCode, resultCode, data)
            SCOPED_STORAGE_PERMISSION_REQUEST -> onScopedStoragePermissionResult(resultCode)

            CREATE_FILE_REQUEST,
            OPEN_FILE_REQUEST,
            DOWNLOAD_FILE_REQUEST -> onStorageAccessResult(requestCode, data?.data)
        }
    }

    private fun onDocumentTreeAccessResult(requestCode: Int, resultCode: Int, intent: Intent?) {
        val treeUri = intent?.data
        if (resultCode != RESULT_OK || treeUri == null) {
            onStorageAccessResult(requestCode, null)
            return
        }

        SafPermissions.takePersistableUriPermission(this, intent.flags, treeUri)

        // resume pending action
        onStorageAccessResult(requestCode, treeUri)
    }

    private fun onScopedStoragePermissionResult(resultCode: Int) {
        pendingPermissionCompleter?.complete(resultCode == RESULT_OK)
    }

    private var lastStatusBarVisible = false
    private var lastNavBarVisible = false

    private fun onWindowInsetsChanged(windowInsets: WindowInsetsCompat) {
        val statusBarVisible = windowInsets.isVisible(WindowInsetsCompat.Type.statusBars())
        val navBarVisible = windowInsets.isVisible(WindowInsetsCompat.Type.navigationBars())
        if (lastStatusBarVisible != statusBarVisible || lastNavBarVisible != navBarVisible) {
            lastStatusBarVisible = statusBarVisible
            lastNavBarVisible = navBarVisible
            notifySystemBarVisibilityChange(
                statusBarVisible = statusBarVisible,
                navBarVisible = navBarVisible,
            )
        }
    }

    // window mode monitoring: PiP, multi-window
    private fun notifyWindowModeChange() = windowChangeStreamHandler.notifyWindowModeChange()

    private fun notifySystemBarVisibilityChange(statusBarVisible: Boolean, navBarVisible: Boolean) {
        windowChangeStreamHandler.notifySystemBarVisibilityChange(statusBarVisible, navBarVisible)
    }

    companion object {
        private val LOG_TAG = LogUtils.createTag<MainActivity>()

        const val DOCUMENT_TREE_ACCESS_REQUEST = 1
        const val CREATE_FILE_REQUEST = 3
        const val OPEN_FILE_REQUEST = 4
        const val SCOPED_STORAGE_PERMISSION_REQUEST = 5
        const val DOWNLOAD_FILE_REQUEST = 6

        // request code to pending runnable
        val pendingStorageAccessResultHandlers = ConcurrentHashMap<Int, PendingStorageAccessResultHandler>()

        var pendingPermissionCompleter: CompletableFuture<Boolean>? = null

        private fun onStorageAccessResult(requestCode: Int, uri: Uri?) {
            Log.i(LOG_TAG, "onStorageAccessResult with requestCode=$requestCode, uri=$uri")
            val handler = pendingStorageAccessResultHandlers.remove(requestCode) ?: return
            if (uri != null) {
                handler.onGranted(uri)
            } else {
                handler.onDenied()
            }
        }

        private var messageStreamHandler: MessageStreamHandler? = null

        fun notifyDebug(message: String) {
            Log.d(LOG_TAG, "notifyDebug message=$message")
            messageStreamHandler?.notifyDebug(message)
        }

        fun notifyError(message: String) {
            Log.e(LOG_TAG, "notifyError message=$message")
            messageStreamHandler?.notifyError(message)
        }
    }
}

// onGranted: user selected a directory/file (with no guarantee that it matches the requested `path`)
// onDenied: user cancelled
data class PendingStorageAccessResultHandler(val path: String?, val onGranted: (uri: Uri) -> Unit, val onDenied: () -> Unit)
