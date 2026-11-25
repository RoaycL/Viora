# FFmpeg 音频扩展（src/main/java/androidx/media3/decoder/ffmpeg/）：源码是直接放进应用的，
# 不会带上 Media3 扩展自己的混淆规则，这里照 Media3 1.10.1 decoder_ffmpeg/proguard-rules.txt 补上。

# native 方法的名字不能改（JNI 按名字找）
-keepclasseswithmembernames class * {
    native <methods>;
}

# 原生代码在 JNI_OnLoad 里按原名和原签名查找这个回调，找不到时整个库加载失败
-keep, includedescriptorclasses class androidx.media3.decoder.ffmpeg.FfmpegAudioDecoder {
  private java.nio.ByteBuffer growOutputBuffer(androidx.media3.decoder.SimpleDecoderOutputBuffer, int);
}

# DefaultRenderersFactory 用反射创建 FfmpegAudioRenderer
-keep class androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer {
  <init>(android.os.Handler, androidx.media3.exoplayer.audio.AudioRendererEventListener, androidx.media3.exoplayer.audio.AudioSink);
}
