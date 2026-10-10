# 03 · 媒体服务器、多线路、反向代理与自定义 UA

## 1. 适配器概览

| 能力 | Emby | Jellyfin | Plex | fnOS 飞牛影视 |
| --- | --- | --- | --- | --- |
| 登录 | 用户名密码 / API Key | 用户名密码 / Quick Connect | plex.tv PIN 登录 / Token | 用户名密码 |
| 服务器发现 | 手填地址 | 手填地址 | plex.tv `resources` 返回所有连接（天然多线路） | 手填地址 |
| Provider IDs | `ProviderIds` | `ProviderIds` | `Guid`（`includeGuids=1`） | 待抓包确认 |
| 多版本 | `MediaSources` | `MediaSources` | `Media[]` / `Part[]` | 待确认 |
| 服务器片头片尾 | Chapters 中的 `MarkerType`（IntroStart/IntroEnd，4.8+ 有 CreditsStart） | 10.10+ `MediaSegments` API；旧版本依赖 Intro Skipper 插件 | `includeMarkers=1` 返回 `Marker type=intro/credits` | 待确认 |
| 进度上报 | `/Sessions/Playing*` | `/Sessions/Playing*` | `/:/timeline` | 待确认 |

> fnOS 没有公开文档的第三方 API，需要对其 Web 端抓包实现，单独放在 `data/servers/fnos/`，接口变化不影响其他适配器。v1 先实现浏览 + 播放 + 进度，其他能力按抓包结果补齐。

## 2. Emby / Jellyfin

两者 API 同源，共用 `EmbyLikeServer` 基类，差异点用子类覆盖。

### 2.1 鉴权

```
POST /Users/AuthenticateByName
X-Emby-Authorization: MediaBrowser Client="Viora", Device="Living Room TV", DeviceId="<uuid>", Version="1.0.0"
{ "Username": "...", "Pw": "..." }
→ AccessToken, User.Id
```

- Emby 后续请求带 `X-Emby-Token: <token>`；Jellyfin 带 `Authorization: MediaBrowser ..., Token="<token>"`。
- `Client`、`Device`、`Version` 可在服务器设置中覆盖（`identityOverride`）—— 很多公益服/付费服按客户端名做白名单，这一项和 UA 一样重要。
- `DeviceId` 按"安装 + 服务器"生成并持久化，避免被服务器当成新设备反复占用设备数。

### 2.2 常用接口

| 用途 | 接口 |
| --- | --- |
| 公开信息 / 测速 | `GET /System/Info/Public`（免登录） |
| 媒体库 | `GET /Users/{uid}/Views` |
| 条目列表 | `GET /Users/{uid}/Items?ParentId=&IncludeItemTypes=Movie,Series&Recursive=true&Fields=ProviderIds,Overview,Genres,DateCreated,MediaSources&StartIndex=&Limit=` |
| 增量 | 上面加 `MinDateLastSaved=`（Emby）/ 按 `DateLastSaved` 排序比对（Jellyfin） |
| 数量 | `GET /Items/Counts` → MovieCount / SeriesCount / EpisodeCount |
| 继续观看 | `GET /Users/{uid}/Items/Resume` |
| 最近添加 | `GET /Users/{uid}/Items/Latest` |
| 季 / 集 | `GET /Shows/{id}/Seasons`、`GET /Shows/{id}/Episodes?SeasonId=` |
| 搜索 | `GET /Users/{uid}/Items?SearchTerm=&Recursive=true&IncludeItemTypes=Movie,Series,Episode` |
| 播放信息 | `POST /Items/{id}/PlaybackInfo?UserId=` → `MediaSources[]` |
| 直链播放 | `GET /Videos/{id}/stream.{container}?Static=true&MediaSourceId=&api_key=`（Jellyfin `static=true`） |
| 外挂字幕 | `GET /Videos/{id}/{sourceId}/Subtitles/{index}/Stream.{fmt}` |
| 进度 | `POST /Sessions/Playing`、`/Sessions/Playing/Progress`、`/Sessions/Playing/Stopped` |
| 片头片尾 | Emby：条目 `Chapters[].MarkerType`；Jellyfin：`GET /MediaSegments/{itemId}` |
| 图片 | `GET /Items/{id}/Images/{Primary|Backdrop|Logo|Thumb}?maxWidth=&tag=` |

### 2.3 播放策略

- 默认 **直接播放**（`Static=true`），客户端解码；不主动请求转码（避免给服务器压力，也是公益服的普遍要求）。
- `strm` / 网盘直链（`MediaSource.IsRemote` 或 `Path` 为 http）：服务器通常会 302 到外部地址，播放器需要跟随重定向；重定向后的地址是否继续走代理由代理配置决定（见 §5.2、§5.4）。
- 仅当两个内核都无法解码时，才提示用户"请求服务器转码"（手动，非自动）。

## 3. Plex

- 登录：`POST https://plex.tv/api/v2/pins` 获取 code → TV 上显示 `plex.tv/link` 与 4 位码（遥控器友好）→ 轮询 pin 拿到 `authToken`。
- 服务器与线路：`GET https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1` 返回每台服务器的多个 `connections`（本地、远程、relay），直接映射为 `ServerLine`，复用测速与自动选线。
- 公共 Header：`X-Plex-Token`、`X-Plex-Client-Identifier`、`X-Plex-Product`、`X-Plex-Version`、`X-Plex-Platform`、`Accept: application/json`。

| 用途 | 接口 |
| --- | --- |
| 媒体库 | `GET /library/sections` |
| 条目 | `GET /library/sections/{id}/all?includeGuids=1&X-Plex-Container-Start=&X-Plex-Container-Size=` |
| 详情 | `GET /library/metadata/{ratingKey}?includeMarkers=1&includeGuids=1&includeChapters=1` |
| 季 / 集 | `GET /library/metadata/{ratingKey}/children` |
| 继续观看 | `GET /hubs/continueWatching`（或 `/hubs/home/continueWatching`，按服务器版本兼容） |
| 搜索 | `GET /hubs/search?query=` |
| 直链 | `Part.key`（`/library/parts/{id}/{ts}/file.mkv`）+ `X-Plex-Token` |
| 进度 | `GET /:/timeline?ratingKey=&key=&state=playing|paused|stopped&time=&duration=` |
| 片头片尾 | 详情返回的 `Marker`（`type=intro` / `credits`，单位毫秒） |

## 4. 多线路

参考 Rex 截图：一台服务器下有多条线路（主线路、CF 线路……），每条线路可单独绑定代理。

- **测速**：并发请求每条线路的公开接口（Emby/Jellyfin `/System/Info/Public`，Plex `/identity`），取 3 次中位数延迟；超时 5s 视为不可用。
- **选线**：
  - 手动：用户固定一条线路。
  - 自动（默认）：启动时和每次从后台恢复时测速，选最快；请求连续失败 2 次自动切到下一条，并在资源库卡片上显示当前线路名。
- 资源库卡片右上角的绿点 = 当前线路可用，黄点 = 已切换到备用线路，红点 = 全部不可用。

## 5. 反向代理

对应 Rex「绑定线路」页：顶部填"完整地址"，下方列出每台服务器的线路，逐条绑定。

### 5.1 配置

```
ReverseProxy {
  name: "我的代理",
  kind: embyReverseProxyGo,          // 默认类型，见 §5.2
  baseUrl: "https://embyproxy.example.com/proxy/",   // 即 Rex 的"完整地址"
  template: null,                    // kind = custom 时使用
  extraHeaders: {}
}
```

### 5.2 默认类型：emby-reverse-proxy-go

用户实际使用的反代服务端是 [Gsy-allen/emby-reverse-proxy-go](https://github.com/Gsy-allen/emby-reverse-proxy-go)，按其源码确认的行为如下：

| 项 | 行为 | 对客户端的要求 |
| --- | --- | --- |
| URL 格式 | `{完整地址}/{scheme}/{host}/{port}{path}?{query}` | **端口必须显式写出**，443 / 80 也要写；`scheme` 只能是 `http` / `https` |
| 子路径 | 服务端只认 `/{scheme}/...`，`/proxy/` 这类前缀由前置 Nginx 去掉，并通过 `X-Forwarded-Prefix` 告诉服务端 | 客户端只管拼"完整地址"，不需要额外 Header |
| 鉴权 | 没有代理级鉴权 | 不需要额外 Header |
| User-Agent | 原样透传给上游 | **自定义 UA 经过代理后仍然有效** |
| 302 重定向 | 服务端不跟随重定向，而是把 `Location` 改写成代理地址（**包括跳到其他域名的网盘/CDN 地址**）后返回给客户端 | 客户端正常跟随即可，默认整条链路都走代理 |
| 响应体改写 | `PlaybackInfo` 和 `Sessions/Playing/Progress` 的 JSON 里出现的绝对地址（如 `DirectStreamUrl`）会被改写成代理地址 | 客户端拿到的播放地址可能已经是代理地址，**拼接前要先判断，避免重复套代理** |
| Referer / Origin | 还原为上游真实值；去掉 `X-Forwarded-*`、`Via` 等头 | 无 |
| WebSocket | 支持（需前置 Nginx 转发 Upgrade 头） | Emby 的会话 WebSocket 也可走代理 |
| 内网目标 | 默认拒绝 localhost / 内网地址（`BLOCK_PRIVATE_TARGETS=true`） | 内网服务器的线路不要绑代理；绑定时提示 |

示例：完整地址 `https://embyproxy.example.com/proxy/`，原地址 `https://emby.a.com/emby/Items?x=1`
→ `https://embyproxy.example.com/proxy/https/emby.a.com/443/emby/Items?x=1`

客户端配套逻辑：

- **去重**：URL 已以"完整地址"开头时不再改写。
- **还原（unwrap）**：能把代理地址反解回原地址（解析 `/{scheme}/{host}/{port}`），用于日志显示真实目标，以及下面的"网盘直连"。
- **网盘直连（可选，默认关）**：302 目标被代理改写后，若反解出的域名与服务器域名不同（即网盘/CDN），可选择还原为原地址直连，节省代理流量。
- **内网检测**：线路地址是内网 IP / `localhost` / `.local` 时，绑定代理前提示"该代理默认不允许访问内网地址"。

### 5.3 其他代理类型（kind = custom）

保留模板方式，兼容其他反代：

| 变量 | 含义 | 示例（原地址 `https://emby.a.com:8920/emby/Items?x=1`） |
| --- | --- | --- |
| `{url}` | 完整原地址 | `https://emby.a.com:8920/emby/Items?x=1` |
| `{url_encoded}` | URL 编码后的完整原地址 | `https%3A%2F%2Femby.a.com...` |
| `{scheme}` `{host}` `{port}` `{path}` `{query}` | 拆分字段（`{port}` 总是显式端口） | `https` / `emby.a.com` / `8920` / `/emby/Items` / `x=1` |

| 代理类型 | 模板 |
| --- | --- |
| emby-reverse-proxy-go（等价写法） | `{base}{scheme}/{host}/{port}{path}?{query}` |
| 前缀拼接整条 URL | `https://proxy.example.com/{url}` |
| 参数型 | `https://proxy.example.com/?target={url_encoded}` |
| 主机替换 + Header 型 | `https://proxy.example.com{path}?{query}`，`extraHeaders: { "X-Target-Host": "{scheme}://{host}:{port}" }` |

### 5.4 作用范围

- 不区分代理范围：线路勾选走代理后，API、图片、视频流全部经过代理（v0.12 起合并）；内网地址始终直连。
- 图片请求跟随 API 的规则。
- 对于不改写 `Location` 的自定义代理：播放器需要自己处理 302（Windows 的 mpv 和 Android 的 ExoPlayer 自定义 `DataSource` 都关闭自动跟随），对重定向目标再改写一次。
- 更换代理地址后，已绑定的线路继续生效（绑定关系存的是 `proxyId`，与 Rex 提示一致）。

### 5.5 绑定页交互（TV）

```
┌ 绑定线路 ─────────────────────────────────────────────────────────┐
│ 完整地址  [ https://embyproxy.example.com/proxy/              ]  │
│ 更换地址后，已绑定的线路会继续使用这个代理。                        │
│                                                                  │
│ 媒体服务器线路                         [全部绑定] [全部解绑]         │
│ ┌ 私服            1 条线路                                    ›  ┐│
│ ┌ 探花 TV         1 条线路   已绑定 1 条线路                   ›  ┐│
│ ┌ cc 公益         2 条线路   已绑定 2 条线路                   ›  ┐│
└──────────────────────────────────────────────────────────────────┘
进入某台服务器 → 每条线路一个开关 + "测试"按钮（同时显示直连与代理延迟）。
```

## 6. 自定义 UA

### 6.1 规则

- **播放 UA**：全局设置 + 服务器级覆盖（服务器 > 全局 > 内置默认）。
- 设置后，以下请求使用该 UA：
  - 视频流（mpv `user-agent` 选项 / ExoPlayer `DefaultHttpDataSource.Factory.setUserAgent`）
  - 外挂字幕下载
  - 重定向后的网盘/CDN 请求（经 emby-reverse-proxy-go 时 UA 原样透传）
- 可选开关"API 与图片也使用此 UA"（默认关；某些服务器只在播放时校验 UA，API 用真实 UA 便于服务器统计，打开后则全部统一）。
- Emby/Jellyfin 的 `X-Emby-Authorization` 中 `Client` / `Device` / `Version` 单独可配（§2.1）。

### 6.2 预设

设置页提供预设列表 + 自定义输入：

| 预设 | 说明 |
| --- | --- |
| Viora 默认 | `Viora/1.0.0 (Windows; x64)` / `Viora/1.0.0 (Android TV)` |
| 自定义 | 任意字符串，支持变量 `{version}` `{platform}` `{device}` |
| 常见客户端模板 | 若干常见播放器 / 浏览器 UA 模板，由用户自行选择 |

### 6.3 验证

设置页提供"测试播放 UA"：用当前 UA 对选定服务器的任一资源发 `Range: bytes=0-1023` 请求，显示 HTTP 状态码，帮助用户判断 UA 是否被服务器拒绝。

### 6.4 实现要点

| 内核 | 设置方式 |
| --- | --- |
| mpv | `user-agent=<ua>`，其余头用 `http-header-fields`（逗号分隔，需转义） |
| ExoPlayer | 自定义 `HttpDataSource.Factory`：设置 UA、默认 Header、关闭自动跨协议重定向并手动处理（§5.4） |
| 图片 | 图片加载器的 headers 由同一 `RequestComposer` 生成 |
