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

- 鉴权：v4 Read Access Token（`Authorization: Bearer`）或 v3 API Key，用户可在设置中填写；构建时可用 `--dart-define=VIORA_TMDB_TOKEN=...` 内置一个默认 Token（CI 读取仓库 Secret `TMDB_TOKEN`，Token 不进代码仓库），用户填写的优先。
- 网络：TMDB 在部分地区访问困难 → API 与图片（`image.tmdb.org`）都可单独配置代理（复用 §03 的代理模板），也可填写自建的 TMDB 反代域名。
- 缓存：列表接口 6 小时，详情 3 天，图片走磁盘缓存。

### 2.1 首页各行数据源

> v0.5.0 实现：`lib/data/tmdb/`（客户端、模型、缓存）、`lib/data/aggregate/tmdb_link.dart`（按 TMDB / IMDb ID 在聚合索引里找媒体库副本，用于资源角标和点击跳转：有资源进媒体库详情，没有进 TMDB 详情）。分类浏览、电影公司、行排序 / 隐藏留到后续版本。

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
| `server` | itemId | ✅ Jellyfin 10.10+ `/MediaSegments/{id}`（Intro / Outro / Recap / Preview，Intro Skipper 插件也写到这里）；Emby 4.8+ 章节 `MarkerType`（IntroStart / IntroEnd / CreditsStart）；Plex `Marker` 待 M6 |
| `theintrodb` | tmdbId（剧）+ 季 + 集；电影为 tmdbId；可回落 imdbId | 已接入 v3；片头 / 前情提要 / 片尾 / 预告，可返回同类型多段 |
| `introdb` | imdbId（剧）+ 季 + 集；电影为 imdbId | 已接入 `/segments`；片头 / 前情提要 / 片尾；保护片尾后的彩蛋 |
| `theotherdb` | 待确认 | 已核实 [Postman 工作区](https://www.postman.com/somebyteorg/todb/overview)说明指向 theotherdb.org，具体片段接口待补充，本次未启用 |
| `publicmetadb` | tmdbId + media_type + 季 + 集；电影不带季集 | 已接入；片头 / 片尾，API Key 必需；未核实前情提要字段，不虚构支持 |
| `chapters` | 章节名 | ✅ 兜底启发式：章节名匹配 `OP / Opening / Intro / 片头`、`ED / Ending / Credits / 片尾`、`Recap / 前情提要`、`Preview / 预告`，该章节到下一章节开始，置信度 0.6 |

每个 Provider 是独立文件。实际优先级：**媒体服务器标记 → 第三方数据库（设置里的顺序）→ 章节名识别**。在「设置 → 片头片尾」可以单独开关、调整第三方顺序、设置 HTTPS API 地址及填写 API Key，并可让第三方数据库经反向代理访问。默认第三方顺序为 TheIntroDB → IntroDB → PublicMetaDB；前两个默认启用，PublicMetaDB 配置 Key 后才能开启。不会以片名搜索代替缺失的作品 ID；剧集用"剧"的 TMDB / IMDb ID + 季 + 集查询。

#### 已接入的读取协议

| 来源 | 请求 | 鉴权 | 返回时间单位与映射 |
| --- | --- | --- | --- |
| TheIntroDB | `GET https://api.theintrodb.org/v3/media?tmdb_id=…&season=…&episode=…&duration_ms=…`；无 TMDB 时改用 `imdb_id`；电影不带季集 | 公开读取无需 Key；可选 `Authorization: Bearer <用户 Key>` | `intro / recap / credits / preview` 数组，`start_ms / end_ms` 为毫秒。空 start 为 0，credits / preview 的空 end 为实际文件结尾 |
| IntroDB | `GET https://api.introdb.app/segments?imdb_id=…&season=…&episode=…`；电影改为 `imdb_id=…&is_movie=true` | 公开读取无需 Key；可选 `X-API-Key` | `intro / recap / outro` 对象，优先读取 `start_ms / end_ms`，否则转换 `start_sec / end_sec`（秒或时钟字符串）；`outro` 映射为 `credits` |
| PublicMetaDB | `GET https://publicmetadb.com/api/external/skips?tmdb_id=…&media_type=tv&season=…&episode=…`；电影 `media_type=movie` 且不带季集 | `Authorization: Bearer <用户 Key>`；在 PublicMetaDB 设置 → API 中生成 | `items` 中的贡献记录，或官网展示的扁平对象；`intro_start_ms / intro_end_ms / credits_start_ms / credits_end_ms`，毫秒；片尾空 end 为结尾 |

核对来源（2026-10-10）：[IntroDB 官方 API 文档](https://introdb.app/docs/api)、[TheIntroDB 官方 SDK 与响应类型](https://github.com/TheIntroDB/theintrodb-npm)、[PublicMetaDB 官网接口示例](https://publicmetadb.com/)。IntroDB `/segments` 和 PublicMetaDB `items` / Bearer 的兼容实现另对照了 [AIOStreams 的实际 Provider 源码](https://github.com/Viren070/AIOStreams/tree/main/packages/core/src/jellyfin/segments/providers)。v0.8.0 已对 TheIntroDB、IntroDB 做真实联调（直连与经 emby-reverse-proxy-go 反代都通过，见 `test/live/segments_live_test.dart`）；PublicMetaDB 未配置 Key 时返回 401（与预期一致），带 Key 的返回格式仍待用户实测。

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

已实现的 `SegmentResolver` 按以上规则并发解析（单个来源 6 秒超时，不阻塞起播），网络超时覆盖连接、响应头和响应体。401 / 403、429、响应格式错误和单个来源故障均独立处理，其他来源仍可补全。只有全部请求成功时才落缓存，避免临时故障被缓存为长期「没有片段」。有效结果 TTL 为 7 天，成功但无数据的结果 TTL 为 1 小时。文件缓存限制 256 项；后续引入 drift 时可替换 `SegmentCache` 实现。

缓存身份包含作品类型、作品 ID、季集、播放源、时长 10 秒桶及来源配置指纹；指纹涵盖启用项、顺序、API 地址和 Key 的摘要。缓存保留原始空 end 与置信度，读取时用实际时长重新校验，避免同一时长桶错误固定结尾或重复降低置信度。

### 3.3 跳过行为（设置项）

| 设置 | 选项 | 默认 |
| --- | --- | --- |
| 片头 | 自动跳过 / 显示"跳过片头"按钮 / 关闭 | 显示按钮 |
| 前情回顾 | 同上 | 显示按钮 |
| 片尾 | 自动下一集 / 显示"下一集"按钮 / 关闭 | 显示按钮 |
| 自动跳过首次例外 | 每部剧的第一集不自动跳过片头 | 开 |
| 无数据时 | 固定跳过前 N 秒 / 后 N 秒（按剧设置） | 关 |

已实现前三项模式及首集例外：片头 / 前情提要可以自动 seek、显示按钮或关闭；片尾有下一集且区间直到实际文件结尾时才切集，否则 seek 到区间结束。首集例外按每部剧第 1 季第 1 集处理，自动片头改为显示按钮，不影响前情提要及后续季的首集。`post_credits` 为彩蛋，不映射为预告；IntroDB 若提供彩蛋起点，片尾跳过停在彩蛋之前。预告数据可以解析，但默认不自动跳过。"无数据时固定跳过 N 秒"尚未实现。

#### 播放器接入（v0.8.0）

- 起播后后台解析（`PlayerPage._beginSegments`）：剧集并行取"剧"的 TMDB / IMDb ID 与本季剧集列表（判断有没有下一集）；时长用片源时长。
- 位置事件送入 `SegmentPlaybackSession.onPosition`；自动跳过时提示"已自动跳过片头"。
- 按钮在右下角（OSD 显示时上移让出进度条），不随 OSD 隐藏：电视按 OK、电脑按回车或点击执行；空格仍是暂停。
- "下一集"直接切到预加载好的下一集（保留预加载数据）。
- 媒体信息（按 I）列出识别到的片段及来源。
- 切换版本时重新解析（缓存键包含服务器 + 版本 ID）。

#### 存储

API Key 存在系统安全存储（`flutter_secure_storage`：Windows 凭据管理器 / Android Keystore）；读取失败（部分电视盒子密钥库异常）时按未填写处理，不影响服务器标记和其他设置。片段缓存为应用数据目录下的 `segment_cache_v1.json`（256 项），不随"清除播放缓存"删除。

### 3.4 手动标记（让数据越用越准）

播放器"更多"菜单 → "标记片头/片尾"：

- 在当前位置按 OK 标记开始，再按一次标记结束；
- 选择"应用到本季所有集"或"仅本集"；
- 写入 `segment_user`，之后同季自动生效。
