# 08 · 播放器

## 1. 内核策略

| 平台 | 默认 | 备用 | 切换时机 |
| --- | --- | --- | --- |
| Windows | mpv（`media_kit`） | — | — |
| Android TV | ExoPlayer（Media3） | mpv | ① 用户在设置中改默认；② 按资源手动"用 mpv 播放"；③ ExoPlayer 起播失败（不支持的编码/封装）自动回退一次；④ 资源含 ASS 特效字幕且用户开启"ASS 优先 mpv" |

## 1.1 实现（M2）

| 部分 | 位置 |
| --- | --- |
| 内核接口 `PlayerEngine` / `EngineState` / `EngineTrack` | `lib/player/engine.dart` |
| mpv 内核 | `lib/player/mpv_engine.dart`（media_kit） |
| ExoPlayer 内核（Dart 侧） | `lib/player/exo_engine.dart`：MethodChannel `viora/exo`、EventChannel `viora/exo/events`、PlatformView `viora/exo-view`（Hybrid Composition） |
| ExoPlayer 内核（原生） | `android/app/src/main/kotlin/com/viora/viora/exo/`：`ExoController`（播放器、轨道、事件）、`ExoPlugin`（通道、PlayerView、自动帧率） |

- **画面**：PlayerView 使用 SurfaceView，以 Hybrid Composition 嵌入 Flutter，SurfaceView 直接参与系统合成，HDR10 / HLG / 杜比视界可直通到电视；Flutter 的 OSD 叠在上面。PlayerView 设置为不可聚焦，遥控器按键始终由 Flutter 处理。
- **网络**：`DefaultHttpDataSource` 设置播放 UA、请求头，允许跨协议重定向（https → http 的网盘直链）。
- **音频直通**：由 ExoPlayer 根据 HDMI 能力（AudioCapabilities）自动选择 AC3 / EAC3 / DTS / TrueHD 直通。
- **自动帧率**：拿到视频帧率后，在同分辨率的显示模式里选刷新率等于帧率（或整数倍）的一项，设置 `preferredDisplayModeId`；退出播放恢复。开启时关闭 ExoPlayer 自带的 `Surface.setFrameRate`，避免冲突。
- **回退**：ExoPlayer 报解析 / 解码 / 音频输出类错误（错误码 3xxx、4xxx、5xxx），或所有音轨 / 视频轨都不被设备支持（否则会静音或黑屏继续播）时，"自动"模式下换 mpv 从当前位置重试一次。网络错误不回退。
- **语言偏好**：音轨优先 zh / chi / zho / cmn / yue，字幕优先中文。

## 1.2 起播加速与预加载（v0.6.0）

| 手段 | 时机 | 作用 |
| --- | --- | --- |
| 播放信息缓存 | 详情页查资源、首页「继续观看」焦点停留 0.8 秒 | 起播时不再请求 PlaybackInfo（经反代一次约 1.5~2 秒），3 分钟内有效；同一条目并发请求合并 |
| 视频预热 | 详情页默认版本、「继续观看」焦点停留 | 读片头 1MB、片尾 256KB（MKV Cues / MP4 moov）、续播位置附近 1MB，唤醒服务器硬盘、解析网盘 302 直链、建立反代回源；同一版本 5 分钟内只预热一次 |
| 下一集预加载 | 剧集播放到 85% | 提前拿到下一集并预热，播完直接跳转 |
| 并行起播 | 进入播放页 | 创建播放内核、取条目信息、取播放信息同时进行 |
| ExoPlayer 起播缓冲 | Android | bufferForPlayback 1 秒（默认 2.5 秒），卡顿后 2.5 秒（默认 5 秒） |

设置 → 播放 →「播放预加载」可关闭（会多用少量流量）。实现：`lib/player/preload.dart`。

v0.7.0 起可调（设置 → 播放）：

| 设置 | 选项 | 说明 |
| --- | --- | --- |
| 起播预热量 | 2 / 8 / 32 / 128 MB | 片头 40%、续播位置 40%、片尾 20%（至少 256KB）；从头播放时续播那份并入片头 |
| 播放缓冲上限 | 64 / 256 / 512 MB / 1 / 2 GB（默认 256 MB） | mpv：`demuxer-max-bytes`，超过 256 MB 时 `cache-on-disk` 写到系统临时目录 `viora_play_cache`；ExoPlayer：`targetBufferBytes`，最多用可用内存的 40% |
| 关闭播放器后清除播放缓存 | 开（默认）/ 关 | 退出播放时删除磁盘缓存文件与预加载数据；连播下一集 / 切换版本时保留预加载数据；启动时清理上次残留 |

实现：`lib/player/playback_cache.dart`。

## 2. PlayerEngine 接口

```dart
abstract class PlayerEngine {
  Future<void> open(PlaybackRequest req);          // URL + headers(UA) + 起始位置 + 外挂字幕
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration pos);
  Future<void> setRate(double rate);
  Future<void> setVolume(double v);                // Windows
  Future<void> selectAudio(AudioTrack? t);
  Future<void> selectSubtitle(SubtitleTrack? t);   // null = 关闭
  Future<void> setSubtitleDelay(Duration d);
  Future<void> setAspect(AspectMode m);            // 适应 / 填充 / 拉伸 / 16:9 / 4:3
  Future<void> dispose();

  Stream<PlayerState> get state;                   // idle/buffering/ready/playing/paused/ended/error
  Stream<Duration> get position;
  Stream<Duration> get buffered;
  Stream<List<Track>> get tracks;
  Stream<PlayerError> get errors;
  Stream<VideoStats> get stats;                    // 解码器、分辨率、码率、丢帧（I 键叠加层）
  Widget buildView();                              // mpv: Texture；Exo: AndroidView(SurfaceView)
}
```

## 3. 关键能力

### 3.1 网络与 UA

- 每次 `open` 都带完整 `headers`，由 `RequestComposer` 生成：`User-Agent`（播放 UA）、鉴权头、代理附加头。
- mpv：`user-agent`、`http-header-fields`、`network-timeout=15`、`demuxer-max-bytes`（缓冲大小设置）、`cache=yes`。
- ExoPlayer：自定义 `HttpDataSource.Factory`（OkHttp 实现），处理 UA、Header、302 处理（03 §5.2、§5.4）、`Range` 请求；`DefaultLoadControl` 缓冲时长可配置。

### 3.2 画面

| 能力 | Windows（mpv） | Android TV（ExoPlayer） |
| --- | --- | --- |
| 硬解 | `hwdec=auto-safe`（D3D11VA） | MediaCodec |
| HDR10 / HLG | `vo=gpu-next` + `target-colorspace-hint=yes`（系统开 HDR 时直通），否则色调映射到 SDR | 直通（设备/电视支持时） |
| Dolby Vision | P5 做色彩映射显示；P7/P8 取 HDR10 基础层 | 设备支持则直通；不支持时 P8 回落 HDR10，P5 提示"可能偏色，建议用 mpv" |
| 自动帧率 | 不做（可选：全屏时切换显示器刷新率，后续） | `Surface.setFrameRate` / 显示模式切换（设置项，默认开） |
| 隧道播放 | — | 可选（部分设备音画同步更好） |

### 3.3 音频

- Android：AC3 / EAC3 / DTS / TrueHD 直通（`AudioCapabilities` 检测），不支持时软解为 PCM。
- Windows：默认解码为 PCM；可选 WASAPI 独占 + 直通（mpv `audio-spdif`）。
- 默认音轨语言：按设置的语言优先级（如 国语 > 粤语 > 原声）。

### 3.4 字幕

- 内封：SRT / ASS / PGS / VobSub。mpv 全部原生；ExoPlayer 对 ASS 只支持基础样式（复杂特效需 mpv），PGS 需 Media3 的相应扩展。
- 外挂：服务器提供的外挂字幕 URL 同样带 UA 和代理改写。
- 默认字幕规则：按语言优先级（简中 > 繁中 > 中英双语 > 无）；"强制字幕"自动开启。
- 样式：字号、颜色、描边、背景、底部边距，对 SRT 生效；ASS 默认保持原样式，可选"覆盖 ASS 样式"。

## 4. 播放页 UI 状态机

```
            open()
  [加载中] ────────▶ [缓冲] ──ready──▶ [播放中] ◀──▶ [暂停]
     │                 ▲                │  │
     │ error           └─────seek───────┘  │ 进入片头区间
     ▼                                     ▼
  [错误面板]                          [跳过按钮可见]
  · 重试                                    │ 到达片尾区间 / 结束
  · 切换线路                                 ▼
  · 切换资源（自动倒计时 5s）           [下一集卡片 + 倒计时]
  · 用备用内核播放
```

- **加载页**：显示作品 Logo/标题、当前资源（服务器 · 线路 · 4K HDR10）、加载进度；按返回可取消。
- **错误面板**按错误类型给出最可能的操作：403/401 → "检查播放 UA / 重新登录"；连接超时 → "切换线路"；解码失败 → "用 mpv 播放"/"切换资源"。

## 5. 播放会话（PlaySession）

```
start(title, episode, source):
  req = RequestComposer.build(source)            # 线路、代理、UA、鉴权
  engine.open(req.copyWith(start: resumePos))    # 续播位置：服务器进度与本地记录取较新者
  server.reportStart()
  segments = SegmentResolver.resolve(...)        # 异步，不阻塞
  every 10s: server.reportProgress(); watch_history.upsert()
  on pause/seek: 立即 reportProgress
  on exit/stop: server.reportStop(); 进度 ≥ 90% 或进入片尾区间 → 标记已看
  on ended: 有下一集 → 用"同一服务器"的下一集（不存在则按 04 §5.3 重新选资源）
```

- **切换资源**：记录当前位置 → `reportStop` 旧服务器 → `open` 新资源并 seek 到原位置 → `reportStart` 新服务器。
- **切换线路**（播放中网络失败）：保持资源不变，只换线路重新 `open` 到当前位置。
- 进度只上报给实际播放的服务器；本地 `watch_history` 记录跨服务器的统一进度，详情页"继续"按钮读取它。
