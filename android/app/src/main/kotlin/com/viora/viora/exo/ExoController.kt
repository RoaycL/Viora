@file:OptIn(UnstableApi::class)

package com.viora.viora.exo

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector

/**
 * 一个 ExoPlayer 实例：负责打开媒体、轨道选择，并把状态以事件推给 Dart（docs/08-player.md）。
 */
class ExoController(
    private val context: Context,
    val id: Int,
    bufferBytes: Long,
    private val emit: (Map<String, Any?>) -> Unit,
    private val onVideoFrameRate: (Float) -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val trackSelector = DefaultTrackSelector(context)
    private var mediaItem: MediaItem? = null
    private val subtitleConfigs = mutableListOf<MediaItem.SubtitleConfiguration>()
    private var decoderName: String? = null
    private var reportedUnsupported = false

    val player: ExoPlayer

    init {
        val renderers = DefaultRenderersFactory(context)
            .setEnableDecoderFallback(true)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER)
        trackSelector.parameters = trackSelector.buildUponParameters()
            .setPreferredAudioLanguages("zh", "chi", "zho", "cmn", "yue")
            .setPreferredTextLanguages("zh", "chi", "zho", "chs", "cht")
            .setSelectUndeterminedTextLanguage(true)
            .build()
        // 起播只需缓冲 1 秒（默认 2.5 秒），卡顿后重新缓冲 2.5 秒（默认 5 秒），加快起播与拖动后的恢复。
        // 预读上限按设置的字节数（ExoPlayer 缓冲在内存里，最多用可用内存的 40%，避免电视盒子内存不足）
        val target = bufferBytes
            .coerceAtMost((Runtime.getRuntime().maxMemory() * 0.4).toLong())
            .coerceIn(32L * 1024 * 1024, Int.MAX_VALUE.toLong())
            .toInt()
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(15_000, 60 * 60_000, 1_000, 2_500)
            .setTargetBufferBytes(target)
            .setPrioritizeTimeOverSizeThresholds(false)
            .build()
        player = ExoPlayer.Builder(context, renderers)
            .setTrackSelector(trackSelector)
            .setLoadControl(loadControl)
            .build()
    }

    private val ticker = object : Runnable {
        override fun run() {
            sendProgress()
            handler.postDelayed(this, 250)
        }
    }

    // ───────────────────────── 控制 ─────────────────────────

    fun open(
        url: String,
        headers: Map<String, String>,
        userAgent: String,
        startMs: Long,
        tunneling: Boolean,
        frameRateSwitch: Boolean,
    ) {
        val http = DefaultHttpDataSource.Factory()
            .setUserAgent(userAgent)
            .setDefaultRequestProperties(headers)
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(20_000)
            .setReadTimeoutMs(30_000)
        val sources = DefaultMediaSourceFactory(DefaultDataSource.Factory(context, http))
        player.setMediaSources(emptyList())
        trackSelector.parameters = trackSelector.buildUponParameters().setTunnelingEnabled(tunneling).build()
        // 自己按片源帧率切换显示模式时，关掉 ExoPlayer 自带的 Surface.setFrameRate 以免冲突
        player.videoChangeFrameRateStrategy =
            if (frameRateSwitch) C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF
            else C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS

        val item = MediaItem.Builder().setUri(Uri.parse(url)).build()
        mediaItem = item
        subtitleConfigs.clear()
        reportedUnsupported = false
        player.setMediaSource(sources.createMediaSource(item), startMs.coerceAtLeast(0))
        sourcesFactory = sources
        player.prepare()
        player.playWhenReady = true
        handler.removeCallbacks(ticker)
        handler.post(ticker)
    }

    private var sourcesFactory: DefaultMediaSourceFactory? = null

    fun play() = player.play()

    fun pause() = player.pause()

    fun seek(ms: Long) = player.seekTo(ms.coerceAtLeast(0))

    fun setRate(rate: Float) {
        player.playbackParameters = PlaybackParameters(rate)
    }

    /** trackId 形如 "组序号:轨道序号" */
    fun selectTrack(type: Int, trackId: String?) {
        val builder = trackSelector.buildUponParameters()
        if (trackId == null) {
            builder.setTrackTypeDisabled(type, true)
        } else {
            val (g, t) = trackId.split(":").map { it.toInt() }
            val group = player.currentTracks.groups.getOrNull(g) ?: return
            builder.setTrackTypeDisabled(type, false)
                .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, t))
        }
        trackSelector.parameters = builder.build()
    }

    /** 外挂字幕：加入 SubtitleConfiguration 后在当前位置重新准备 */
    fun addSubtitle(url: String, title: String?, language: String?) {
        val item = mediaItem ?: return
        val lower = url.lowercase()
        val mime = when {
            lower.contains(".ass") || lower.contains(".ssa") -> MimeTypes.TEXT_SSA
            lower.contains(".vtt") -> MimeTypes.TEXT_VTT
            lower.contains(".ttml") || lower.contains(".xml") -> MimeTypes.APPLICATION_TTML
            else -> MimeTypes.APPLICATION_SUBRIP
        }
        subtitleConfigs.add(
            MediaItem.SubtitleConfiguration.Builder(Uri.parse(url))
                .setMimeType(mime)
                .setLabel(title)
                .setLanguage(language)
                .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
                .build()
        )
        val next = item.buildUpon().setSubtitleConfigurations(subtitleConfigs.toList()).build()
        mediaItem = next
        val pos = player.currentPosition
        val sources = sourcesFactory ?: return
        player.setMediaSource(sources.createMediaSource(next), pos)
        player.prepare()
        trackSelector.parameters = trackSelector.buildUponParameters()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            .clearOverridesOfType(C.TRACK_TYPE_TEXT)
            .build()
    }

    fun release() {
        handler.removeCallbacks(ticker)
        player.removeListener(listener)
        player.release()
    }

    // ───────────────────────── 事件 ─────────────────────────

    private fun sendProgress() {
        emit(
            mapOf(
                "event" to "progress",
                "position" to player.currentPosition,
                "duration" to player.duration.takeIf { it != C.TIME_UNSET },
                "buffered" to player.bufferedPosition,
            )
        )
    }

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(state: Int) {
            emit(mapOf("event" to "state", "buffering" to (state == Player.STATE_BUFFERING)))
            if (state == Player.STATE_ENDED) emit(mapOf("event" to "completed"))
            sendProgress()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            emit(mapOf("event" to "playing", "playing" to isPlaying))
        }

        override fun onPlaybackParametersChanged(params: PlaybackParameters) {
            emit(mapOf("event" to "rate", "rate" to params.speed.toDouble()))
        }

        override fun onPlayerError(error: PlaybackException) {
            val code = error.errorCode
            // 解析 / 解码 / 音频输出类错误换 mpv 可能解决；网络类错误不换
            val fallback = code in 3000..3999 || code in 4000..4999 || code in 5000..5999
            emit(
                mapOf(
                    "event" to "error",
                    "message" to "${error.errorCodeName}${error.message?.let { ": $it" } ?: ""}",
                    "fallback" to fallback,
                )
            )
        }

        override fun onTracksChanged(tracks: Tracks) {
            val audio = mutableListOf<Map<String, Any?>>()
            val text = mutableListOf<Map<String, Any?>>()
            var hasAudio = false
            var audioSupported = false
            var hasVideo = false
            var videoSupported = false
            tracks.groups.forEachIndexed { g, group ->
                for (t in 0 until group.length) {
                    val f = group.getTrackFormat(t)
                    val supported = group.isTrackSupported(t)
                    when (group.type) {
                        C.TRACK_TYPE_AUDIO -> {
                            hasAudio = true
                            if (supported) audioSupported = true
                            audio.add(trackMap("$g:$t", f, group.isTrackSelected(t), supported))
                        }
                        C.TRACK_TYPE_TEXT -> text.add(trackMap("$g:$t", f, group.isTrackSelected(t), supported))
                        C.TRACK_TYPE_VIDEO -> {
                            hasVideo = true
                            if (supported) videoSupported = true
                        }
                    }
                }
            }
            emit(mapOf("event" to "tracks", "audio" to audio, "subtitle" to text))
            // 有音轨 / 视频轨但设备都不支持时，ExoPlayer 会静音或黑屏继续播 —— 主动报错以便回退到 mpv
            if (!reportedUnsupported && ((hasAudio && !audioSupported) || (hasVideo && !videoSupported))) {
                reportedUnsupported = true
                emit(
                    mapOf(
                        "event" to "error",
                        "message" to if (hasVideo && !videoSupported) "设备不支持该视频编码" else "设备不支持该音频格式（如 DTS / TrueHD）",
                        "fallback" to true,
                    )
                )
            }
        }

        override fun onVideoSizeChanged(size: VideoSize) = sendVideo()
    }

    private val analytics = object : AnalyticsListener {
        override fun onVideoDecoderInitialized(
            eventTime: AnalyticsListener.EventTime,
            decoderName: String,
            initializedTimestampMs: Long,
            initializationDurationMs: Long,
        ) {
            this@ExoController.decoderName = decoderName
            sendVideo()
        }

        override fun onVideoInputFormatChanged(
            eventTime: AnalyticsListener.EventTime,
            format: Format,
            decoderReuseEvaluation: DecoderReuseEvaluation?,
        ) {
            if (format.frameRate > 0) onVideoFrameRate(format.frameRate)
            sendVideo()
        }
    }

    // 放在 listener / analytics 声明之后：Kotlin 按声明顺序初始化属性
    init {
        player.addListener(listener)
        player.addAnalyticsListener(analytics)
    }

    private fun sendVideo() {
        val f = player.videoFormat ?: return
        val hdr = when {
            f.sampleMimeType == MimeTypes.VIDEO_DOLBY_VISION -> "Dolby Vision"
            f.colorInfo?.colorTransfer == C.COLOR_TRANSFER_ST2084 -> "HDR10"
            f.colorInfo?.colorTransfer == C.COLOR_TRANSFER_HLG -> "HLG"
            else -> null
        }
        emit(
            mapOf(
                "event" to "video",
                "width" to f.width,
                "height" to f.height,
                "frameRate" to f.frameRate.takeIf { it > 0 }?.toDouble(),
                "codec" to (f.codecs ?: f.sampleMimeType),
                "hdr" to hdr,
                "decoder" to decoderName,
            )
        )
    }

    private fun trackMap(id: String, f: Format, selected: Boolean, supported: Boolean) = mapOf(
        "id" to id,
        "title" to f.label,
        "language" to f.language,
        "codec" to (f.codecs ?: f.sampleMimeType?.substringAfter('/')),
        "channels" to f.channelCount.takeIf { it != Format.NO_VALUE },
        "selected" to selected,
        "supported" to supported,
    )
}
