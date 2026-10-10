# 02 · 工程结构与核心模型

## 1. 目录结构

```
viora/
├─ lib/
│  ├─ main.dart
│  ├─ app/                    # 启动、路由(go_router)、主题、平台判断、DI(riverpod providers)
│  ├─ core/
│  │  ├─ net/                 # Dio 工厂、拦截器（RouteSelector / ProxyRewriter / UserAgent / Auth / Retry）
│  │  ├─ db/                  # drift 数据库定义与 DAO
│  │  ├─ storage/             # 设置项、secure storage
│  │  └─ util/                # 日志、时间、语言、标题归一化
│  ├─ domain/
│  │  ├─ models/              # MediaItem / MediaSource / Segment / ServerConfig ...（freezed）
│  │  └─ usecases/            # HomeFeed、ResolveSources、AggregatedSearch、PlaySession、SegmentResolver、LibrarySync
│  ├─ data/
│  │  ├─ servers/
│  │  │  ├─ media_server.dart # 抽象接口
│  │  │  ├─ emby/  jellyfin/  plex/  fnos/
│  │  ├─ tmdb/                # TMDB 客户端 + 缓存
│  │  ├─ segments/            # 片头片尾 Provider：server / theintrodb / introdb / theotherdb / publicmetadb / chapters / user
│  │  └─ index/               # 聚合索引（同步、匹配、查询）
│  ├─ features/
│  │  ├─ home/  detail/  library/  search/  player/  settings/  onboarding/
│  ├─ player/
│  │  ├─ engine.dart          # PlayerEngine 接口
│  │  ├─ mpv_engine.dart      # media_kit 实现
│  │  └─ exo_engine.dart      # 平台通道 → Android 插件
│  └─ ui/                     # TV 组件库（见 06-ui-design.md / 07-input-control.md）
│     ├─ focus/               # FocusableCard、FocusMemory、DpadScrollController
│     ├─ rows/                # MediaRow、PosterCard、BackdropCard、PersonCard、LogoCard
│     ├─ nav/                 # SideNavRail
│     └─ panels/              # SidePanel、BottomSheet(TV)、Toast
├─ packages/
│  └─ viora_exoplayer/        # Flutter 插件：Media3 ExoPlayer（Kotlin），PlatformView + MethodChannel/EventChannel
├─ android/                   # Leanback launcher、banner、android:isGame=false、横屏
└─ windows/
```

## 2. 核心数据模型

> 以下为 Dart 伪代码（实际用 `freezed`）。

```dart
enum ServerType { emby, jellyfin, plex, fnos }

class ServerConfig {
  String id;                 // 本地 UUID
  ServerType type;
  String name;               // "私服"、"探花 TV"
  String? iconUrl;
  List<ServerLine> lines;    // 多线路
  String? activeLineId;      // null = 自动选线
  Credentials credentials;   // 用户名/密码 或 Token（存 secure storage）
  String? userAgentOverride; // 覆盖全局播放 UA
  ClientIdentity? identityOverride; // 覆盖 Client/Device 名称（部分服务器按客户端名做白名单）
  bool adult;                // R18 标识
  String? note;              // "主线路" / "30 天观看" 之类的备注
  DateTime? lastAccessAt;
}

class ServerLine {
  String id;
  String name;               // "主线路"、"CF 线路"
  Uri baseUrl;               // https://emby.example.com:8920
  String? proxyId;           // 绑定的反向代理，null = 直连
  ProxyScope proxyScope;     // apiAndStream / streamOnly / apiOnly
  int? lastLatencyMs;        // 最近一次测速
}

class ReverseProxy {
  String id;
  String name;
  String template;           // 见 03-media-servers.md §5
  Map<String, String> extraHeaders;
}

/// 统一的媒体条目（来自某一台服务器）
class MediaItem {
  String serverId;
  String itemId;             // 服务器内 ID（Plex 为 ratingKey）
  MediaKind kind;            // movie / series / season / episode / person / collection
  String title;
  String? originalTitle;
  int? year;
  DateTime? premiereDate;
  ProviderIds ids;           // tmdb / imdb / tvdb
  String? overview;
  ImageSet images;           // poster / backdrop / logo / thumb（URL 已经是"可直接请求"的形式）
  List<String> genres;
  double? communityRating;
  Duration? runtime;
  UserData userData;         // played / position / favorite
  // episode 专用
  String? seriesId; int? seasonNumber; int? episodeNumber;
}

class ProviderIds { String? tmdb; String? imdb; String? tvdb; }

/// 一个可播放版本
class MediaSource {
  String serverId;
  String itemId;
  String sourceId;           // Emby/Jellyfin MediaSourceId，Plex 为 Part id
  String? name;              // "4K HDR 10 HEVC"
  String container;          // mkv / mp4 / ts / strm
  int? sizeBytes;
  int? bitrate;              // bps
  Duration? duration;
  VideoInfo? video;          // width/height/codec/profile/fps/bitDepth/colorPrimaries/transfer/range(SDR/HDR10/HDR10+/HLG/DV)
  List<AudioTrack> audio;
  List<SubtitleTrack> subtitles;
  List<Chapter> chapters;
  bool isRemote;             // strm / 网盘直链
  DateTime? dateAdded;       // "入库时间"
}

enum SegmentType { intro, recap, credits, preview }

class Segment {
  SegmentType type;
  Duration start;
  Duration end;
  String provider;           // 来源，用于展示与调试
  double confidence;         // 0~1
}

/// 聚合后的作品（详情页、搜索结果的单位）
class Title {
  String key;                // "tmdb:tv:95479" 或 fallback "title:时光代理人:2021"
  MediaKind kind;
  ProviderIds ids;
  MediaItem? primary;        // 元数据主来源（优先媒体库）
  List<MediaItem> copies;    // 所有服务器上的同一作品
  TmdbDetail? tmdb;          // 补全数据
}
```

## 3. 核心接口

### 3.1 媒体服务器适配器

```dart
abstract class MediaServer {
  ServerConfig get config;

  // 连接与鉴权
  Future<ServerInfo> probe(ServerLine line);                 // 测速 + 版本识别（公开接口，免登录）
  Future<Session> login(Credentials c);
  Future<void> logout();

  // 浏览
  Future<List<Library>> libraries();
  Future<Page<MediaItem>> items(ItemQuery q);                // 支持 parentId / kind / sort / 分页 / 增量(updatedSince)
  Future<MediaItem> item(String id);
  Future<List<MediaItem>> seasons(String seriesId);
  Future<List<MediaItem>> episodes(String seriesId, {int? season});
  Future<List<MediaItem>> resume();                          // 继续观看
  Future<List<MediaItem>> latest({String? libraryId});
  Future<List<MediaItem>> search(String keyword, {Set<MediaKind>? kinds});
  Future<LibraryCounts> counts();                            // 电影数 / 剧集数

  // 播放
  Future<List<MediaSource>> playbackInfo(String itemId);
  PlaybackRequest buildStream(MediaSource s, {AudioTrack? audio, SubtitleTrack? sub});
  Future<List<Segment>> segments(String itemId);             // 服务器自带的片头片尾（可能为空）
  Future<void> reportStart(PlaybackReport r);
  Future<void> reportProgress(PlaybackReport r);
  Future<void> reportStop(PlaybackReport r);
  Future<void> setPlayed(String itemId, bool played);
  Future<void> setFavorite(String itemId, bool fav);

  // 图片
  ImageRequest image(String itemId, ImageKind kind, {int? maxWidth});
}

/// 交给播放器的最终请求 —— URL 已完成线路选择和代理改写
class PlaybackRequest {
  Uri url;
  Map<String, String> headers;   // 含 User-Agent、鉴权头、代理附加头
  List<ExternalSubtitle> externalSubs;
  Duration? startPosition;
}
```

### 3.2 片头片尾 Provider

```dart
abstract class SegmentProvider {
  String get id;                  // "server" / "theintrodb" / "introdb" / ...
  Future<List<Segment>> fetch(SegmentQuery q);
}

class SegmentQuery {
  MediaItem item;                 // 含 tmdb/imdb/tvdb、季集号
  MediaSource source;             // 含实际时长（用于时长校验）
  MediaServer server;
}
```

### 3.3 播放器

见 [08-player.md](08-player.md) §2。

## 4. 本地数据库（drift）

| 表 | 主要字段 | 用途 |
| --- | --- | --- |
| `servers` / `server_lines` / `proxies` | 见模型 | 配置 |
| `index_items` | server_id, item_id, kind, tmdb_id, imdb_id, tvdb_id, title, title_norm, original_title, year, poster, updated_at | 聚合索引（只存电影和剧，不存集） |
| `index_sync_state` | server_id, library_id, last_sync_at, cursor | 增量同步游标 |
| `watch_history` | title_key, server_id, item_id, season, episode, position_ms, duration_ms, updated_at | 跨服务器的统一继续观看 |
| `segment_cache` | title_key, season, episode, source_duration_ms, type, start_ms, end_ms, provider, confidence, fetched_at | 片头片尾缓存（TTL 7 天，用户手动标记永久） |
| `segment_user` | series_key, season, type, start_ms, end_ms | 用户手动标记（可整季套用） |
| `tmdb_cache` | path, lang, body, expires_at | TMDB 响应缓存 |
| `search_history` | keyword, at | 搜索历史 |

## 5. 网络拦截器链

请求从业务层出来时只带"逻辑地址"（`server://{serverId}/Items/xxx`），依次经过：

1. **RouteSelector**：把 `server://` 解析为当前线路的 `baseUrl`（手动指定或自动测速选最快）；请求失败时按延迟顺序切换下一条线路，并记录。
2. **ProxyRewriter**：线路绑定了代理且 `proxyScope` 覆盖本次请求类型 → 按模板改写 URL、附加代理 Header。
3. **UserAgent**：API 请求用"客户端 UA"，播放/图片按设置决定是否使用"播放 UA"（见 03 §6）。
4. **Auth**：按服务器类型注入 `X-Emby-Token` / `Authorization: MediaBrowser ...` / `X-Plex-Token` / fnOS Token。
5. **Retry**：幂等请求在超时 / 5xx 时指数退避重试 2 次。

播放 URL 不走 Dio，但通过同一套 `RequestComposer` 生成 `PlaybackRequest`，保证 API 和播放的线路、代理、UA 规则一致。
