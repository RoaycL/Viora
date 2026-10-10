# 08 · 播放器

## 1. 内核策略

| 平台 | 默认 | 备用 | 切换时机 |
| --- | --- | --- | --- |
| Windows | mpv（`media_kit`） | — | — |
| Android TV | ExoPlayer（Media3） | mpv | ① 用户在设置中改默认；② 按资源手动"用 mpv 播放"；③ ExoPlayer 起播失败（不支持的编码/封装）自动回退一次；④ 资源含 ASS 特效字幕且用户开启"ASS 优先 mpv" |

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
