@file:OptIn(UnstableApi::class)

package com.viora.viora.exo

import android.content.Context
import android.graphics.Color
import android.view.accessibility.CaptioningManager
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.SubtitleView

/**
 * 字幕亮度（HDR 片源上白色字幕常常刺眼）：在系统字幕样式（和 PlayerView 默认的 setUserDefaultStyle 一样）的基础上，
 * 只把文字颜色按 [brightness] 调暗，背景、描边、字体不变。brightness = 1 时恢复系统样式。
 */
fun SubtitleView.applyBrightness(context: Context, brightness: Float) {
    val cm = context.getSystemService(Context.CAPTIONING_SERVICE) as? CaptioningManager
    val base = if (cm?.isEnabled == true) CaptionStyleCompat.createFromCaptionStyle(cm.userStyle) else CaptionStyleCompat.DEFAULT
    if (brightness >= 0.999f) {
        setStyle(base)
        return
    }
    val b = brightness.coerceIn(0.2f, 1f)
    val fg = base.foregroundColor
    val dimmed = Color.argb(
        Color.alpha(fg),
        (Color.red(fg) * b).toInt(),
        (Color.green(fg) * b).toInt(),
        (Color.blue(fg) * b).toInt(),
    )
    setStyle(CaptionStyleCompat(dimmed, base.backgroundColor, base.windowColor, base.edgeType, base.edgeColor, base.typeface))
}
