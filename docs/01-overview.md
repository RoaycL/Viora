# 01 · 总览

## 1. 产品定位

一个只做"看"的客户端：不做媒体服务器，不做刮削入库，把用户已有的多台媒体服务器（自建、公益服、付费服）统一起来，在电视和 PC 上提供接近原生流媒体 App 的观看体验。

目标平台：

| 平台 | 输入 | 典型分辨率 | 备注 |
| --- | --- | --- | --- |
| Windows 10/11 x64 | 键盘 + 鼠标（兼容手柄） | 1080p ~ 4K，窗口可缩放 | 需要窗口模式与全屏模式 |
| Android TV / Google TV（Android 7.0+） | 遥控器（D-pad），兼容手柄 | 输出 1080p/4K，UI 按 1920×1080 设计 | 需要 Leanback 启动器入口、HDR 直通 |

## 2. 功能范围

### 2.1 第一版（MVP）必须有

- **媒体服务器**：Emby、Jellyfin、Plex、飞牛影视（fnOS）登录与浏览；一台服务器可配多条线路，支持测速和自动选线。
- **反向代理**：全局代理地址，线路可"绑定"到代理，API 和视频流都可经代理访问（参考 Rex「绑定线路」页）。
- **自定义播放 UA**：全局 UA + 按服务器覆盖，播放请求使用该 UA；可选同时作用于 API / 图片请求。
- **首页**：Hero 轮播、继续观看、以及 TMDB 驱动的推荐行（正在热映、正在播出、本周趋势、今日动漫、热门人物、播出平台、分类浏览、高分剧集、电影公司）。
- **详情页**：元数据、季/集选择、**播放资源**面板（按 4K / 1080P / 其他 分组列出所有服务器上的可用版本）、媒体信息、演职员、剧照、相似作品。
- **资源库**：服务器卡片网格（在线状态、最近访问、影片/剧集数量、R18 标识），进入后按媒体库浏览。
- **聚合搜索**：一次搜索所有服务器 + TMDB，同一部作品合并为一个结果。
- **播放**：多版本选择、音轨/字幕切换、进度回报服务器、**跳过片头 / 片尾**（自动或按钮）、自动下一集。
- **操作**：Windows 键鼠、TV 遥控器完整可用（见 [07-input-control.md](07-input-control.md)）。

### 2.2 后续版本

- ~~手机扫码配置~~ 已实现：电视扫码 + Windows 一键同步，见 [11-sync.md](11-sync.md)。
- 多用户 / 儿童模式、家长指南数据、外部评分（豆瓣/IMDb/烂番茄）。
- 在线字幕搜索（OpenSubtitles 等）。（弹幕已提前实现，见 [10-danmaku.md](10-danmaku.md)）
- 配置云同步（WebDAV）。

### 2.3 明确不做

- 视频转码、本地文件刮削入库、下载离线（v1 不做）。

## 3. 技术选型

### 3.1 结论

**Flutter（UI + 业务，单代码库）+ 双播放内核：**

| 层 | Windows | Android TV |
| --- | --- | --- |
| UI / 业务 | Flutter（Dart） | Flutter（Dart） |
| 默认播放内核 | libmpv（`media_kit`） | **Media3 ExoPlayer**（平台视图，Kotlin 插件） |
| 备用播放内核 | — | libmpv（`media_kit`），用于 ExoPlayer 不支持的格式 / ASS 特效字幕 |

### 3.2 理由

- **一套 UI 代码覆盖两端**。两端都是"横屏大屏 + 焦点导航"，布局几乎一致，差异只在输入方式；Flutter 的 `Focus` / `Shortcuts` / `Actions` 体系可以同时承载遥控器、键盘和鼠标悬停。
- **Windows 播放选 mpv**：解码格式最全（HEVC/AV1/DV Profile 5 色彩映射/各种封装），ASS 字幕渲染最好，`user-agent`、`http-header-fields` 原生支持。
- **Android TV 播放选 ExoPlayer**：只有走 `MediaCodec` + `SurfaceView` 才能稳定做到 HDR10 / Dolby Vision 直通、音频直通（AC3/EAC3/TrueHD Passthrough）、隧道播放、自动帧率切换（`Surface.setFrameRate`）。mpv 在 Android 上 HDR 直通能力弱，因此只做备用。
- 两个内核共同实现 Dart 侧的 `PlayerEngine` 接口（见 [08-player.md](08-player.md)），业务层无感知。

### 3.3 备选方案（未采用）

| 方案 | 不采用的原因 |
| --- | --- |
| Kotlin Multiplatform + Compose（TV 用 Compose for TV，PC 用 Compose Desktop） | Android TV 体验最好，但 Compose Desktop 的视频播放生态薄弱，Windows 端需要自己嵌 libmpv/VLC，成本高 |
| 两端各自原生（WinUI 3 + Android Compose） | 两套 UI 代码，人力翻倍 |
| Electron / Web | TV 端性能和 HDR 直通都不可接受 |

### 3.4 主要依赖

| 用途 | 依赖 |
| --- | --- |
| 状态管理 / DI | `flutter_riverpod` |
| 路由 | `go_router` |
| 网络 | `dio`（拦截器负责 UA、代理改写、鉴权头、重试） |
| 本地数据库 | `drift`（SQLite），存服务器配置、聚合索引、观看记录、片头片尾缓存 |
| 敏感信息 | `flutter_secure_storage`（Token、密码） |
| 图片 | `extended_image` 或 `cached_network_image`（需支持自定义 Header，以便图片也能带 UA / 走代理） |
| 播放 | `media_kit`（libmpv）、自研 `viora_exoplayer` 插件（Media3） |
| 序列化 | `freezed` + `json_serializable` |

## 4. 整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│ Presentation  首页 · 详情 · 资源库 · 搜索 · 播放器 · 设置              │
│               TV 组件库（焦点卡片 / 横向行 / 导航栏 / 侧边面板）       │
├─────────────────────────────────────────────────────────────────────┤
│ Application   用例：HomeFeed · ResolveSources · AggregatedSearch ·    │
│               PlaySession · SegmentResolver · LibrarySync            │
├──────────────┬──────────────┬───────────────┬───────────────────────┤
│ Media Server │ Metadata     │ Segments      │ Local                 │
│ Adapters     │ TMDB         │ Providers     │ drift DB · 设置 · 缓存 │
│ Emby/Jelly/  │              │ Server/TIDB/  │                       │
│ Plex/fnOS    │              │ IntroDB/...   │                       │
├──────────────┴──────────────┴───────────────┴───────────────────────┤
│ Network       Dio + 拦截器：线路选择 → 代理改写 → UA → 鉴权 → 重试     │
├─────────────────────────────────────────────────────────────────────┤
│ Player        PlayerEngine 接口 ← mpv(media_kit) / ExoPlayer(Media3) │
└─────────────────────────────────────────────────────────────────────┘
```

核心数据流（以"首页点一部 TMDB 推荐的剧 → 播放"为例）：

1. 首页行数据来自 TMDB（`/trending`、`/discover` 等），卡片只带 `tmdbId`。
2. 点进详情：先查本地**聚合索引**，找出所有服务器上 `tmdbId` 相同的条目；有则以媒体库元数据为主、TMDB 补全；无则展示 TMDB 元数据并提示"暂无可用资源"。
3. 选集后，`ResolveSources` 并发向各服务器取该集的 `MediaSource` 列表，合并成"播放资源"面板。
4. 用户选一个版本 → `PlaySession` 生成最终 URL（线路 + 代理改写 + UA + 鉴权）→ 交给 `PlayerEngine`。
5. 同时 `SegmentResolver` 按优先级拉取片头片尾数据，播放中触发跳过。
6. 进度回报给**实际播放的那台服务器**，同时写入本地统一观看记录（按 tmdbId 聚合，用于"继续观看"）。
