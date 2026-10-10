# 05 · 元数据与片头片尾

## 1. 元数据优先级

| 字段 | 第一来源 | 补全来源 |
| --- | --- | --- |
| 标题、简介、年份、类型 | 媒体库（`primary` 条目） | TMDB（`zh-CN`，无中文时回落 `en-US`） |
| 海报 / 背景图 | 媒体库 | TMDB `images` |
| Logo（标题艺术字，Hero 和详情页使用） | 媒体库 Logo | TMDB `images.logos`（`include_image_language=zh,en,null`） |
| 演职员 | 媒体库 People | TMDB `credits` / `aggregate_credits` |
| 剧照 | 媒体库 Backdrops | TMDB `images.backdrops` |
| 相似作品 | — | TMDB `recommendations`，回落 `similar` |
| 评分 | 媒体库 CommunityRating | TMDB `vote_average`；外部评分（豆瓣/IMDb/烂番茄）后续版本 |
| 分级 | 媒体库 OfficialRating | TMDB `release_dates` / `content_ratings` |
| 家长指南 | — | 后续版本（TMDB 无此数据，需另找数据源） |
| 季/集标题与简介 | 媒体库 | TMDB `/tv/{id}/season/{n}` |

"primary"条目选择：多台服务器都有时，选元数据最完整（有简介 + 有 Logo + 有中文标题）的那一份。

媒体库没有 tmdbId 的条目不调用 TMDB，避免错配。

## 2. TMDB 接入

- 鉴权：v4 Read Access Token（`Authorization: Bearer`），用户可在设置中填写自己的 Token；内置默认 Token 仅用于首页推荐。
- 网络：TMDB 在部分地区访问困难 → API 与图片（`image.tmdb.org`）都可单独配置代理（复用 §03 的代理模板），也可填写自建的 TMDB 反代域名。
- 缓存：列表接口 6 小时，详情 3 天，图片走磁盘缓存。

### 2.1 首页各行数据源

| 行（与 Rex 首页一致） | TMDB 接口 |
| --- | --- |
| Hero 轮播 | `/trending/all/day` 前 8 条，过滤无背景图的 |
| 继续观看 | **服务器**：各服务器 `Resume` + 本地 `watch_history`，按时间合并去重 |
| 正在热映 | `/movie/now_playing?region=CN`（区域可设置） |
| 正在播出 | `/tv/on_the_air` |
| 本周趋势 | `/trending/all/week` |
| 今日动漫 | `/discover/tv?with_genres=16&air_date.gte={today}&air_date.lte={today}&with_original_language=ja` |
| 热门人物 | `/person/popular` |
| 播出平台 | 固定列表（Netflix、Disney+、HBO、Apple TV+、Prime Video、爱奇艺、腾讯视频、优酷、Bilibili……）→ 点进去 `/discover/tv?with_networks={id}` |
| 分类浏览 | `/genre/movie/list` + `/genre/tv/list` → `/discover/*?with_genres=` |
| 高分剧集 | `/tv/top_rated` |
| 电影公司 | 固定列表 → `/discover/movie?with_companies={id}` |
| 最近入库（额外，按服务器） | 各服务器 `Latest` |

行可在设置中排序 / 隐藏，并可开关"只显示我有资源的条目"（用聚合索引过滤）。

## 3. 片头片尾（Segments）

### 3.1 数据源

| Provider | 键 | 说明 |
| --- | --- | --- |
| `user` | 剧 + 季 | 用户手动标记，最高优先级 |
| `server` | itemId | Emby Chapters `MarkerType`；Jellyfin `MediaSegments`（或 Intro Skipper 插件接口）；Plex `Marker` |
| `theintrodb` | tmdbId（剧）+ 季 + 集；电影为 tmdbId；可回落 imdbId | 已接入 v3；片头 / 前情提要 / 片尾 / 预告，可返回同类型多段 |
| `introdb` | imdbId（剧）+ 季 + 集；电影为 imdbId | 已接入 `/segments`；片头 / 前情提要 / 片尾；保护片尾后的彩蛋 |
| `theotherdb` | 待确认 | 已核实 [Postman 工作区](https://www.postman.com/somebyteorg/todb/overview)说明指向 theotherdb.org，具体片段接口待补充，本次未启用 |
| `publicmetadb` | tmdbId + media_type + 季 + 集；电影不带季集 | 已接入；片头 / 片尾，API Key 必需；未核实前情提要字段，不虚构支持 |
| `chapters` | 章节名 | 兜底启发式：章节名匹配 `Opening / OP / Intro / 片头` 与 `Ending / ED / Credits / 片尾`，置信度 0.5 |

每个 Provider 是独立文件，可在「设置 → 片头片尾与前情提要」单独启用、调整优先级、设置 HTTPS API 地址及填写 API Key。默认顺序为 TheIntroDB → IntroDB → PublicMetaDB；前两个默认启用，PublicMetaDB 配置 Key 后才能开启。不会以片名搜索代替缺失的作品 ID。

#### 已接入的读取协议

| 来源 | 请求 | 鉴权 | 返回时间单位与映射 |
| --- | --- | --- | --- |
| TheIntroDB | `GET https://api.theintrodb.org/v3/media?tmdb_id=…&season=…&episode=…&duration_ms=…`；无 TMDB 时改用 `imdb_id`；电影不带季集 | 公开读取无需 Key；可选 `Authorization: Bearer <用户 Key>` | `intro / recap / credits / preview` 数组，`start_ms / end_ms` 为毫秒。空 start 为 0，credits / preview 的空 end 为实际文件结尾 |
| IntroDB | `GET https://api.introdb.app/segments?imdb_id=…&season=…&episode=…`；电影改为 `imdb_id=…&is_movie=true` | 公开读取无需 Key；可选 `X-API-Key` | `intro / recap / outro` 对象，优先读取 `start_ms / end_ms`，否则转换 `start_sec / end_sec`（秒或时钟字符串）；`outro` 映射为 `credits` |
| PublicMetaDB | `GET https://publicmetadb.com/api/external/skips?tmdb_id=…&media_type=tv&season=…&episode=…`；电影 `media_type=movie` 且不带季集 | `Authorization: Bearer <用户 Key>`；在 PublicMetaDB 设置 → API 中生成 | `items` 中的贡献记录，或官网展示的扁平对象；`intro_start_ms / intro_end_ms / credits_start_ms / credits_end_ms`，毫秒；片尾空 end 为结尾 |

核对来源（2026-10-10）：[IntroDB 官方 API 文档](https://introdb.app/docs/api)、[TheIntroDB 官方 SDK 与响应类型](https://github.com/TheIntroDB/theintrodb-npm)、[PublicMetaDB 官网接口示例](https://publicmetadb.com/)。IntroDB `/segments` 和 PublicMetaDB `items` / Bearer 的兼容实现另对照了 [AIOStreams 的实际 Provider 源码](https://github.com/Viren070/AIOStreams/tree/main/packages/core/src/jellyfin/segments/providers)。当前环境不能访问这些 API 域名，因此离线契约测试不等于服务端真实联调；尤其 PublicMetaDB 的完整官方接口说明仍需实际请求进一步核验。

API Key 通过 `flutter_secure_storage` 保存于系统安全存储，不写入 `shared_preferences`、片段缓存或日志。Android 关闭应用自动备份，避免跨设备恢复安全存储密文造成解密失败。API 地址支持保留路径前缀的 HTTPS 反向代理；拒绝包含账号密码、查询参数的地址，也不携带 Key 自动跟随重定向。

### 3.2 合并算法

```
SegmentResolver.resolve(item, source):
  1. 查 segment_cache（key = 作品 + 季 + 集 + 文件时长取整到 10s），命中且未过期 → 返回
  2. 按用户设置的优先级并发请求各 Provider（每个 3s 超时）
  3. 对每种类型（intro / recap / credits / preview）独立选取：
       - 取有有效数据的最高优先级 Provider；保留它的多个互不重叠片段
       - 同 Provider 的重叠候选优先保留校验后置信度更高者；不拼接不同剪辑版本的起止点
  4. 校验规则：
       - 0 ≤ start < end ≤ 文件时长
       - intro：时长 5s ~ 180s，start 在前 40% 内
       - credits：end 距结尾 ≤ 5 分钟（或 end 为空 = 直到结尾），start 在后 40% 内
       - 第三方数据带参考时长时：|参考时长 − 文件时长| > 30s → 置信度 ×0.5（不同剪辑版本，时间轴可能对不上）
       - 置信度 < 0.4 丢弃
  5. 写缓存，返回
```

时间轴尚未就绪不阻塞起播：起播后后台解析，拿到结果再挂到播放器上。

已实现的 `SegmentResolver` 按以上规则并发解析，网络超时覆盖连接、响应头和响应体。401 / 403、429、响应格式错误和单个来源故障均独立处理，其他来源仍可补全。只有全部请求成功时才落缓存，避免临时故障被缓存为长期「没有片段」。有效结果 TTL 为 7 天，成功但无数据的结果 TTL 为 1 小时。文件缓存限制 256 项；后续引入 drift 时可替换 `SegmentCache` 实现。

缓存身份包含作品类型、作品 ID、季集、播放源、时长 10 秒桶及来源配置指纹；指纹涵盖启用项、顺序、API 地址和 Key 的摘要。缓存保留原始空 end 与置信度，读取时用实际时长重新校验，避免同一时长桶错误固定结尾或重复降低置信度。

### 3.3 跳过行为（设置项）

| 设置 | 选项 | 默认 |
| --- | --- | --- |
| 片头 | 自动跳过 / 显示"跳过片头"按钮 / 关闭 | 显示按钮 |
| 前情回顾 | 同上 | 显示按钮 |
| 片尾 | 自动下一集 / 显示"下一集"按钮 / 关闭 | 显示按钮 |
| 自动跳过首次例外 | 每部剧的第一集不自动跳过片头 | 开 |
| 无数据时 | 固定跳过前 N 秒 / 后 N 秒（按剧设置） | 关 |

本次实现了前三项模式及首集例外：片头 / 前情提要可以自动 seek、显示按钮或关闭；片尾有下一集且区间直到实际文件结尾时才切集，否则 seek 到区间结束。首集例外按每部剧第 1 季第 1 集处理，自动片头改为显示按钮，不影响前情提要及后续季的首集。`post_credits` 为彩蛋，不映射为预告；IntroDB 若提供彩蛋起点，片尾跳过停在彩蛋之前。预告数据可以解析，但默认不自动跳过。

`lib/player/segment_playback_session.dart` 提供播放内核适配入口：在 `engine.open` 后调用 `begin`，把位置流送入 `onPosition`，UI 接收 `onPrompt`，按钮调用 `activate`，退出时 `dispose`。解析不阻塞起播；切集后旧请求结果作废，重复位置事件只执行一次跳转，跳转失败仅提供手动重试。媒体服务器的真实 `MediaItem / MediaSource` 尚未实现，当前使用 `SegmentQuery` 投影传入剧/电影 ID、季集及实际时长。

**当前应用仍为 M0 假数据界面，尚无播放内核，不能在现有「播放」按钮上执行真实视频跳过。** 已接入的 Provider 可通过设置页「查询跳过片段」实际调用，展示校验后的时间轴及来源错误；播放会话接入上述适配器后即可使用跳过策略。服务器 / 手动标记 / 章节 Provider、按剧固定跳过秒数及手动标记 UI 仍属后续工作。

#### 本次验证（2026-10-10）

- Dart 3.13.5：生产代码中的 Provider、HTTP、解析器、缓存策略和播放控制核心通过静态分析及 29 项测试。独立测试包仅把 `flutter_test` 导入替换为 `test`，生产核心代码保持一致。
- Flutter 3.44.0 / Dart 3.12.0：在临时项目副本中调整 SDK 约束后，通过 `flutter analyze` 和全部 48 项测试（其中新增 37 项），覆盖设置页交互、安全存储及原有界面测试；未更改仓库的 SDK 约束或降级锁文件。
- 仓库仍要求 Dart `^3.13.5`；新增安全存储依赖使用 Dart 3.13.5 与 Flutter 3.47.7 的官方源包元数据解析并锁定。环境无法下载该 Flutter 版本的引擎，因此上述界面测试属于兼容性验证，尚未验证目标版本的完整构建、Android / Windows 原生包或真实 API 请求。

在项目要求的 Flutter SDK 环境中可运行 `flutter analyze` 和 `flutter test` 复验；新增测试位于 `test/segments/`。

### 3.4 手动标记（让数据越用越准）

播放器"更多"菜单 → "标记片头/片尾"：

- 在当前位置按 OK 标记开始，再按一次标记结束；
- 选择"应用到本季所有集"或"仅本集"；
- 写入 `segment_user`，之后同季自动生效。
