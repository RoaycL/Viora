@file:OptIn(UnstableApi::class)

package com.viora.viora.exo

import android.content.Context
import android.hardware.display.DisplayManager
import android.media.MediaCrypto
import android.os.Build
import android.os.Handler
import android.view.Display
import androidx.annotation.OptIn
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.CodecSpecificDataUtil
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener
import android.media.MediaCodecInfo.CodecProfileLevel
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo as ExoCodecInfo

/**
 * 杜比视界 Profile 7（UHD 蓝光原盘 remux 常见，基础层是 HDR10，增强层 / RPU 放在 HEVC 不使用的 NAL 类型里）。
 *
 * Media3 不会把 P7 交给普通 HEVC 解码器（P5 不兼容，P7 被当作「不一定兼容」），于是在没有杜比视界、
 * 或杜比视界解码器不支持 P7 的电视 / 盒子上，这类片子会被判定为不支持，回退到 mpv：
 * mpv 在 Android 上只能输出 SDR，HDR 就没了。
 *
 * 这里在设备不能真正按杜比视界播 P7 时，改用 HEVC 解码器只解基础层，按 HDR10 直通到电视。
 * 解码出错时仍按原来的逻辑回退到 mpv，最差也只是和以前一样。P5 等其他 Profile 不受影响。
 */
class DolbyVisionCompatVideoRenderer(
    builder: MediaCodecVideoRenderer.Builder,
    private val appContext: Context,
    private val onBaseLayerFallback: () -> Unit,
) : MediaCodecVideoRenderer(builder) {

    companion object {
        fun isProfile7(format: Format): Boolean {
            if (format.sampleMimeType != MimeTypes.VIDEO_DOLBY_VISION) return false
            val profile = CodecSpecificDataUtil.getCodecProfileAndLevel(format)?.first ?: return false
            return profile == CodecProfileLevel.DolbyVisionProfileDvheDtb
        }

        /** 只看基础层的格式：HEVC Main10，去掉杜比视界的 codecs 串（不让解码器按杜比视界 Profile 配置） */
        fun baseLayer(format: Format): Format =
            format.buildUpon().setSampleMimeType(MimeTypes.VIDEO_H265).setCodecs(null).build()

        @Suppress("DEPRECATION")
        fun displaySupportsDolbyVision(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
            return try {
                val dm = context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager ?: return false
                val display = dm.getDisplay(Display.DEFAULT_DISPLAY) ?: return false
                display.hdrCapabilities?.supportedHdrTypes?.contains(Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION) == true
            } catch (_: Throwable) {
                false
            }
        }
    }

    /** 这台设备能不能真正按杜比视界播这个 P7 片源（显示支持杜比视界，且有声明支持 P7 的杜比视界解码器） */
    private fun canPlayAsDolbyVision(selector: MediaCodecSelector, format: Format): Boolean {
        if (!displaySupportsDolbyVision(appContext)) return false
        return try {
            selector.getDecoderInfos(MimeTypes.VIDEO_DOLBY_VISION, false, false)
                .any { it.isFormatFunctionallySupported(appContext, format) }
        } catch (_: Throwable) {
            false
        }
    }

    private fun useBaseLayer(selector: MediaCodecSelector, format: Format) =
        isProfile7(format) && !canPlayAsDolbyVision(selector, format)

    override fun supportsFormat(mediaCodecSelector: MediaCodecSelector, format: Format): Int =
        super.supportsFormat(mediaCodecSelector, if (useBaseLayer(mediaCodecSelector, format)) baseLayer(format) else format)

    override fun getDecoderInfos(
        mediaCodecSelector: MediaCodecSelector,
        format: Format,
        requiresSecureDecoder: Boolean,
    ): List<ExoCodecInfo> = super.getDecoderInfos(
        mediaCodecSelector,
        if (useBaseLayer(mediaCodecSelector, format)) baseLayer(format) else format,
        requiresSecureDecoder,
    )

    override fun getMediaCodecConfiguration(
        codecInfo: ExoCodecInfo,
        format: Format,
        crypto: MediaCrypto?,
        codecOperatingRate: Float,
    ): MediaCodecAdapter.Configuration {
        val fallback = isProfile7(format) && codecInfo.codecMimeType == MimeTypes.VIDEO_H265
        if (fallback) onBaseLayerFallback()
        return super.getMediaCodecConfiguration(codecInfo, if (fallback) baseLayer(format) else format, crypto, codecOperatingRate)
    }
}

/** 默认的渲染器，只把视频渲染器换成 [DolbyVisionCompatVideoRenderer]（参数和 Media3 默认的一致） */
class VioraRenderersFactory(
    private val appContext: Context,
    private val onBaseLayerFallback: () -> Unit,
) : DefaultRenderersFactory(appContext) {
    override fun buildVideoRenderers(
        context: Context,
        extensionRendererMode: Int,
        mediaCodecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean,
        eventHandler: Handler,
        eventListener: VideoRendererEventListener,
        allowedVideoJoiningTimeMs: Long,
        out: ArrayList<Renderer>,
    ) {
        val built = ArrayList<Renderer>()
        super.buildVideoRenderers(
            context, extensionRendererMode, mediaCodecSelector, enableDecoderFallback,
            eventHandler, eventListener, allowedVideoJoiningTimeMs, built,
        )
        val index = built.indexOfFirst { it is MediaCodecVideoRenderer }
        if (index >= 0) {
            built[index] = DolbyVisionCompatVideoRenderer(
                MediaCodecVideoRenderer.Builder(context)
                    .setCodecAdapterFactory(codecAdapterFactory)
                    .setMediaCodecSelector(mediaCodecSelector)
                    .setAllowedJoiningTimeMs(allowedVideoJoiningTimeMs)
                    .setEnableDecoderFallback(enableDecoderFallback)
                    .setEventHandler(eventHandler)
                    .setEventListener(eventListener)
                    .setMaxDroppedFramesToNotify(DefaultRenderersFactory.MAX_DROPPED_VIDEO_FRAME_COUNT_TO_NOTIFY),
                appContext,
                onBaseLayerFallback,
            )
        }
        out.addAll(built)
    }
}
