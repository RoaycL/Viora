@file:OptIn(UnstableApi::class)

package com.viora.viora.exo

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.os.Build
import android.view.Display
import android.view.View
import android.view.ViewGroup
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Dart ↔ ExoPlayer 桥接：
 * - MethodChannel `viora/exo`：create / open / play / pause / seek / setRate / selectTrack / addSubtitle / dispose
 * - EventChannel `viora/exo/events`：所有播放器的事件，带 id
 * - PlatformView `viora/exo-view`：PlayerView（SurfaceView，支持 HDR 直通），参数 { id }
 */
class ExoPlugin(private val activity: Activity, engine: FlutterEngine) {
    private val players = mutableMapOf<Int, ExoController>()
    private var nextId = 1
    private var sink: EventChannel.EventSink? = null
    private var frameRateSwitch = false
    private var originalModeId: Int? = null

    init {
        val messenger = engine.dartExecutor.binaryMessenger
        EventChannel(messenger, "viora/exo/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
        MethodChannel(messenger, "viora/exo").setMethodCallHandler { call, result ->
            try {
                val id = call.argument<Int>("id")
                val p = id?.let { players[it] }
                when (call.method) {
                    "create" -> {
                        val newId = nextId++
                        players[newId] = ExoController(
                            activity,
                            newId,
                            emit = { e -> sink?.success(e + ("id" to newId)) },
                            onVideoFrameRate = { fps -> if (frameRateSwitch) switchDisplayMode(fps) },
                        )
                        result.success(newId)
                    }
                    "open" -> {
                        frameRateSwitch = call.argument<Boolean>("frameRateSwitch") ?: false
                        p?.open(
                            url = call.argument<String>("url")!!,
                            headers = call.argument<Map<String, String>>("headers") ?: emptyMap(),
                            userAgent = call.argument<String>("userAgent") ?: "Viora",
                            startMs = (call.argument<Number>("startMs") ?: 0).toLong(),
                            tunneling = call.argument<Boolean>("tunneling") ?: false,
                            frameRateSwitch = frameRateSwitch,
                        )
                        result.success(null)
                    }
                    "play" -> { p?.play(); result.success(null) }
                    "pause" -> { p?.pause(); result.success(null) }
                    "seek" -> { p?.seek((call.argument<Number>("ms") ?: 0).toLong()); result.success(null) }
                    "setRate" -> { p?.setRate((call.argument<Number>("rate") ?: 1.0).toFloat()); result.success(null) }
                    "selectTrack" -> {
                        val type = if (call.argument<String>("type") == "audio") C.TRACK_TYPE_AUDIO else C.TRACK_TYPE_TEXT
                        p?.selectTrack(type, call.argument<String>("track"))
                        result.success(null)
                    }
                    "addSubtitle" -> {
                        p?.addSubtitle(call.argument<String>("url")!!, call.argument("title"), call.argument("language"))
                        result.success(null)
                    }
                    "dispose" -> {
                        p?.release()
                        players.remove(id)
                        if (players.isEmpty()) restoreDisplayMode()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("exo", e.message, null)
            }
        }
        engine.platformViewsController.registry.registerViewFactory("viora/exo-view", ViewFactory())
    }

    fun releaseAll() {
        players.values.forEach { it.release() }
        players.clear()
        restoreDisplayMode()
    }

    // ───────────────────────── 自动帧率（切换显示模式） ─────────────────────────

    @Suppress("DEPRECATION")
    private fun display(): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) activity.display else activity.windowManager.defaultDisplay

    /** 选同分辨率下刷新率等于帧率（或其整数倍）的显示模式，例如 23.976 → 23.976Hz，25 → 50Hz */
    private fun switchDisplayMode(fps: Float) {
        val display = display() ?: return
        val current = display.mode
        val candidates = display.supportedModes.filter {
            it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight
        }
        val best = candidates.filter { abs(it.refreshRate - fps) < 0.05f }.minByOrNull { abs(it.refreshRate - fps) }
            ?: candidates.filter {
                val ratio = it.refreshRate / fps
                ratio > 1.5f && abs(ratio - ratio.roundToInt()) < 0.01f
            }.minByOrNull { it.refreshRate }
            ?: return
        if (best.modeId == current.modeId) return
        if (originalModeId == null) originalModeId = current.modeId
        activity.runOnUiThread {
            val attrs = activity.window.attributes
            attrs.preferredDisplayModeId = best.modeId
            activity.window.attributes = attrs
        }
    }

    private fun restoreDisplayMode() {
        if (originalModeId == null) return
        originalModeId = null
        activity.runOnUiThread {
            val attrs = activity.window.attributes
            attrs.preferredDisplayModeId = 0
            activity.window.attributes = attrs
        }
    }

    // ───────────────────────── 视图 ─────────────────────────

    private inner class ViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
            val id = ((args as? Map<*, *>)?.get("id") as? Number)?.toInt()
            val view = PlayerView(context).apply {
                useController = false
                setShutterBackgroundColor(Color.BLACK)
                setKeepContentOnPlayerReset(true)
                resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                // 不抢焦点：遥控器按键始终交给 Flutter 处理
                isFocusable = false
                isFocusableInTouchMode = false
                descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
                subtitleView?.setApplyEmbeddedStyles(true)
                player = id?.let { players[it]?.player }
            }
            return object : PlatformView {
                override fun getView(): View = view

                override fun dispose() {
                    view.player = null
                }
            }
        }
    }
}
