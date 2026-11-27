package io.github.beomyo.purer.channel.calls

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.bumptech.glide.Glide
import io.github.beomyo.purer.channel.calls.Coresult.Companion.safe
import io.github.beomyo.purer.decoding.RegionFetcher
import io.github.beomyo.purer.glide.VideoThumbnailInfo
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class MediaFetchObjectHandler(private val context: Context) : MethodCallHandler {
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getVideoDuration" -> ioScope.launch { safe(call, result, ::getVideoDuration) }
            "clearDecoders" -> ioScope.launch { safe(call, result, ::clearDecoders) }
            "clearImageDiskCache" -> ioScope.launch { safe(call, result, ::clearImageDiskCache) }
            "clearImageMemoryCache" -> ioScope.launch { safe(call, result, ::clearImageMemoryCache) }
            else -> result.notImplemented()
        }
    }

    // duration of a video the platform already probed while extracting its
    // thumbnail, or null when it has not been probed yet
    private fun getVideoDuration(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")
        if (uri == null) {
            result.error("getVideoDuration-args", "missing arguments", null)
            return
        }
        result.success(VideoThumbnailInfo.duration(uri)?.toInt())
    }

    private fun clearDecoders(@Suppress("unused_parameter") call: MethodCall, result: MethodChannel.Result) {
        RegionFetcher.clearDecoders()
        result.success(null)
    }

    private fun clearImageDiskCache(@Suppress("unused_parameter") call: MethodCall, result: MethodChannel.Result) {
        Glide.get(context).clearDiskCache()
        result.success(null)
    }

    private fun clearImageMemoryCache(@Suppress("unused_parameter") call: MethodCall, result: MethodChannel.Result) {
        Handler(Looper.getMainLooper()).post {
            Glide.get(context).clearMemory()
        }
        result.success(null)
    }

    companion object {
        const val CHANNEL = "io.github.beomyo/purer/media_fetch_object"
    }
}