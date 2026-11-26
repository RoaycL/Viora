package com.viora.viora.exo

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.CaptioningManager
import androidx.media3.common.Player
import androidx.media3.common.text.CueGroup
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.CaptionStyleCompat.EDGE_TYPE_DROP_SHADOW
import androidx.media3.ui.CaptionStyleCompat.EDGE_TYPE_OUTLINE
import androidx.media3.ui.SubtitleView
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * 字幕亮度（HDR 片源上白色字幕常常刺眼）：给字幕视图加一层颜色滤镜，把所有颜色的 RGB 乘以 [brightness]。
 * 对字幕自带的颜色（ASS / SSA、WebVTT 的颜色标记）也有效；黑色描边、透明度不变。brightness = 1 时去掉滤镜。
 */
fun SubtitleView.applyBrightness(brightness: Float) {
    if (brightness >= 0.999f) {
        setLayerType(View.LAYER_TYPE_NONE, null)
        return
    }
    val b = brightness.coerceIn(0.2f, 1f)
    val paint = Paint().apply {
        colorFilter = ColorMatrixColorFilter(ColorMatrix().apply { setScale(b, b, b, 1f) })
    }
    setLayerType(View.LAYER_TYPE_HARDWARE, paint)
}

/** 字幕外观（Flutter 的 SubtitleLook）：文字颜色、边框（auto / outline / shadow / box）、描边粗细倍数 */
data class SubtitleLook(val color: Int, val edge: String, val outline: Float) {
    val isDefault get() = color == Color.WHITE && edge == "auto" && abs(outline - 1f) < 0.01f

    companion object {
        val DEFAULT = SubtitleLook(Color.WHITE, "auto", 1f)

        fun from(args: Map<*, *>?) = SubtitleLook(
            color = (args?.get("color") as? Number)?.toLong()?.toInt() ?: Color.WHITE,
            edge = args?.get("edge") as? String ?: "auto",
            outline = (args?.get("outline") as? Number)?.toFloat()?.coerceIn(0.3f, 3f) ?: 1f,
        )
    }

    /** 用这个外观时要不要换掉描边 / 阴影的粗细（Media3 的描边固定 2dp，只能靠改字幕视图的像素密度） */
    fun needsOverlay(context: Context): Boolean =
        abs(outline - 1f) >= 0.01f && edgeType(context) in setOf(EDGE_TYPE_OUTLINE, EDGE_TYPE_DROP_SHADOW)

    private fun userStyle(context: Context): CaptionStyleCompat {
        val cm = context.getSystemService(Context.CAPTIONING_SERVICE) as? CaptioningManager
        return if (cm?.isEnabled == true) CaptionStyleCompat.createFromCaptionStyle(cm.userStyle) else CaptionStyleCompat.DEFAULT
    }

    private fun edgeType(context: Context) = when (edge) {
        "outline" -> EDGE_TYPE_OUTLINE
        "shadow" -> EDGE_TYPE_DROP_SHADOW
        "box" -> CaptionStyleCompat.EDGE_TYPE_NONE
        else -> userStyle(context).edgeType
    }

    fun applyTo(view: SubtitleView) {
        if (isDefault) {
            view.setUserDefaultStyle()
            return
        }
        val clear = Color.TRANSPARENT
        val black = 0xE6000000.toInt()
        view.setStyle(
            when (edge) {
                "outline" -> CaptionStyleCompat(color, clear, clear, EDGE_TYPE_OUTLINE, black, null)
                "shadow" -> CaptionStyleCompat(color, clear, clear, EDGE_TYPE_DROP_SHADOW, black, null)
                "box" -> CaptionStyleCompat(color, 0x99000000.toInt(), clear, CaptionStyleCompat.EDGE_TYPE_NONE, black, null)
                else -> userStyle(view.context).let {
                    CaptionStyleCompat(color, it.backgroundColor, it.windowColor, it.edgeType, it.edgeColor, it.typeface)
                }
            }
        )
    }
}

/**
 * 粗细不是标准时用的字幕视图：Media3 画描边 / 阴影的粗细是 2dp × 屏幕像素密度、不能设置，
 * 所以另建一个字幕视图，给它一个像素密度乘上 [outline] 的 Context（字号按视图高度的比例算，不受影响），
 * 叠在 PlayerView 原来的字幕视图上（原来的隐藏），字幕内容从播放器的 onCues 拿。
 */
class SubtitleOverlay(private val original: SubtitleView, private val player: Player, val outline: Float) {
    val view: SubtitleView
    private val listener = object : Player.Listener {
        override fun onCues(cueGroup: CueGroup) = view.setCues(cueGroup.cues)
    }

    init {
        val base = original.context
        val config = Configuration(base.resources.configuration).apply {
            densityDpi = (base.resources.displayMetrics.densityDpi * outline).roundToInt().coerceAtLeast(1)
        }
        view = SubtitleView(base.createConfigurationContext(config))
        val parent = original.parent as ViewGroup
        parent.addView(view, parent.indexOfChild(original) + 1, original.layoutParams)
        original.visibility = View.INVISIBLE
        player.addListener(listener)
        view.setCues(player.currentCues.cues)
    }

    fun remove() {
        player.removeListener(listener)
        (view.parent as? ViewGroup)?.removeView(view)
        original.visibility = View.VISIBLE
    }
}
