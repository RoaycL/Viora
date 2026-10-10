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
| `theintrodb` | tmdbId + 季 + 集 | TheIntroDB |
| `introdb` | imdbId（剧）+ 季 + 集 | IntroDB |
| `theotherdb` | 待确认 | TheOtherDB |
| `publicmetadb` | 待确认 | PublicMetaDB |
| `chapters` | 章节名 | 兜底启发式：章节名匹配 `Opening / OP / Intro / 片头` 与 `Ending / ED / Credits / 片尾`，置信度 0.5 |

> 第三方数据库的具体接口地址、鉴权方式、返回格式需要在实现阶段逐一核对其官方文档后再写死；在代码中每个 Provider 是独立文件，可在设置中单独启用、排序、填写 API Key。

### 3.2 合并算法

```
SegmentResolver.resolve(item, source):
  1. 查 segment_cache（key = 作品 + 季 + 集 + 文件时长取整到 10s），命中且未过期 → 返回
  2. 按用户设置的优先级并发请求各 Provider（每个 3s 超时）
  3. 对每种类型（intro / recap / credits / preview）独立选取：
       - 取优先级最高、且通过校验的那条
  4. 校验规则：
       - 0 ≤ start < end ≤ 文件时长
       - intro：时长 5s ~ 180s，start 在前 40% 内
       - credits：end 距结尾 ≤ 5 分钟（或 end 为空 = 直到结尾），start 在后 40% 内
       - 第三方数据带参考时长时：|参考时长 − 文件时长| > 30s → 置信度 ×0.5（不同剪辑版本，时间轴可能对不上）
       - 置信度 < 0.4 丢弃
  5. 写缓存，返回
```

时间轴尚未就绪不阻塞起播：起播后后台解析，拿到结果再挂到播放器上。

### 3.3 跳过行为（设置项）

| 设置 | 选项 | 默认 |
| --- | --- | --- |
| 片头 | 自动跳过 / 显示"跳过片头"按钮 / 关闭 | 显示按钮 |
| 前情回顾 | 同上 | 显示按钮 |
| 片尾 | 自动下一集 / 显示"下一集"按钮 / 关闭 | 显示按钮 |
| 自动跳过首次例外 | 每部剧的第一集不自动跳过片头 | 开 |
| 无数据时 | 固定跳过前 N 秒 / 后 N 秒（按剧设置） | 关 |

### 3.4 手动标记（让数据越用越准）

播放器"更多"菜单 → "标记片头/片尾"：

- 在当前位置按 OK 标记开始，再按一次标记结束；
- 选择"应用到本季所有集"或"仅本集"；
- 写入 `segment_user`，之后同季自动生效。
