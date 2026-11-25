#!/bin/bash
# 编译 ExoPlayer FFmpeg 音频扩展的原生库 libffmpegJNI.so（LGPL 版 FFmpeg，只开音频解码器），
# 输出到 android/app/src/main/jniLibs/<架构>/。Java 部分在 android/app/src/main/java/androidx/media3/decoder/ffmpeg/，
# 和应用一起编译（取自 Media3 1.10.1 的 libraries/decoder_ffmpeg，与应用用的 Media3 同版本）。
#
# 编好的 .so 提交在仓库里，平时发布不用重新编译。升级 Media3 时：
#   1. 用新版 Media3 的 decoder_ffmpeg 替换上面的 Java 文件和这里的 ffmpeg_jni.cc
#   2. 运行 Actions →「FFmpeg 音频扩展」（.github/workflows/ffmpeg.yml），或在 Linux 上运行本脚本，提交生成的 .so
#
# 用法：android/ffmpeg/build.sh <NDK 路径>
# 依据：Media3 decoder_ffmpeg 的 README / build_ffmpeg.sh / CMakeLists.txt（推荐 FFmpeg 6.0）。
# 不加 --enable-gpl / --enable-nonfree：FFmpeg 按 LGPL 2.1+ 授权，静态链接进单独的 libffmpegJNI.so。
set -euo pipefail

NDK="${1:?用法：build.sh <NDK 路径>}"
FFMPEG_VERSION=6.0.1
MIN_API=21
DECODERS=(aac mp3 ac3 eac3 truehd mlp dca vorbis opus amrnb amrwb flac alac pcm_mulaw pcm_alaw)
ABIS=(arm64-v8a armeabi-v7a x86_64)

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../app/src/main/jniLibs"
WORK="${WORK:-$HERE/build}"
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[[ -d "$TC" ]] || { echo "NDK 路径不对：$TC 不存在"; exit 1; }
JOBS="$(nproc 2>/dev/null || echo 4)"

mkdir -p "$WORK"
cd "$WORK"
if [[ ! -d "ffmpeg-$FFMPEG_VERSION" ]]; then
  curl -fsSL -o ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  tar xf ffmpeg.tar.xz
fi
SRC="$WORK/ffmpeg-$FFMPEG_VERSION"

COMMON=(
  --target-os=android --enable-static --disable-shared --disable-doc --disable-programs
  --disable-everything --disable-avdevice --disable-avformat --disable-swscale --disable-postproc
  --disable-avfilter --disable-symver --enable-swresample --disable-v4l2-m2m --disable-vulkan
  --enable-pic
)
for d in "${DECODERS[@]}"; do COMMON+=("--enable-decoder=$d"); done

for abi in "${ABIS[@]}"; do
  case "$abi" in
    arm64-v8a) triple=aarch64-linux-android; arch=(--arch=aarch64 --cpu=armv8-a) ;;
    armeabi-v7a) triple=armv7a-linux-androideabi; arch=(--arch=arm --cpu=armv7-a --extra-cflags="-march=armv7-a -mfloat-abi=softfp" --extra-ldflags="-Wl,--fix-cortex-a8") ;;
    x86_64) triple=x86_64-linux-android; arch=(--arch=x86_64 --cpu=x86-64 --disable-asm) ;;
  esac
  prefix="$WORK/out/$abi"
  echo "==> FFmpeg $abi"
  (
    cd "$SRC"
    make distclean >/dev/null 2>&1 || true
    ./configure --prefix="$prefix" \
      --cross-prefix="$TC/$triple$MIN_API-" --cc="$TC/$triple$MIN_API-clang" --cxx="$TC/$triple$MIN_API-clang++" \
      --nm="$TC/llvm-nm" --ar="$TC/llvm-ar" --ranlib="$TC/llvm-ranlib" --strip="$TC/llvm-strip" \
      "${arch[@]}" "${COMMON[@]}" >/dev/null
    make -j"$JOBS" >/dev/null
    make install-libs install-headers >/dev/null
  )
  echo "==> libffmpegJNI.so $abi"
  extra=()
  [[ "$abi" == arm64-v8a ]] && extra+=(-Wl,-Bsymbolic)
  mkdir -p "$OUT/$abi"
  "$TC/$triple$MIN_API-clang++" -std=c++11 -O2 -fPIC -shared \
    -I"$prefix/include" "$HERE/ffmpeg_jni.cc" \
    -L"$prefix/lib" -lswresample -lavcodec -lavutil -landroid -llog -lm \
    -Wl,-z,max-page-size=16384 -Wl,--gc-sections -Wl,--exclude-libs,ALL "${extra[@]}" \
    -static-libstdc++ \
    -o "$OUT/$abi/libffmpegJNI.so"
  "$TC/llvm-strip" --strip-unneeded "$OUT/$abi/libffmpegJNI.so"
  ls -la "$OUT/$abi/libffmpegJNI.so"
done
echo "完成：$OUT"
