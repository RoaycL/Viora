package com.viora.viora.exo

import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.view.View
import androidx.media3.ui.SubtitleView

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
