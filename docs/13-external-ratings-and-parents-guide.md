# 13 · 外部评分与家长指南

基于 main `829a0e4`（v0.15.0）。OMDb 与 Trakt 的标准 API 已接入；豆瓣和详细家长指南等待可用数据源。接口核对日期：2026-10-11。

## 1. 设置与使用

「设置 → 元数据 → 外部评分」分别配置 OMDb、Trakt，点击「保存并测试」。有凭据时自动开启，也可以单独关闭来源。进入媒体库详情或 TMDB 详情后才查询，首页海报列表不发外部评分请求。

- **OMDb**：填写 API Key，或粘贴申请邮件中的示例链接，客户端提取 `apikey`。提供 IMDb、烂番茄、Metacritic 评分及可选年龄分级。免费额度当前为每天 1,000 次。
- **Trakt**：填写应用的 Client ID，公开社区评分无需用户 OAuth，也不使用 Client Secret。可识别复制内容中的数字 HTML 实体，例如 `&#x39;` 为 `9`。创建应用需要绑定经过验证的 GitHub 账号。
- **API 地址**：默认使用官方 HTTPS 地址，可改为 HTTPS 反代，保留路径前缀；不接受带账号密码、查询参数或片段的地址。
- **反向代理**：可选择复用「设置 → 反向代理」中的 HTTPS 地址，按已有 emby-reverse-proxy-go 地址格式改写完整请求。

Key 和设置以一个记录原子保存到系统安全存储。读取或写入失败会显示错误，不会退回明文配置，也不会把未保存的 Key 显示为保存成功。普通配置 JSON 和评分缓存不含凭据。

可选构建默认值为 `--dart-define=VIORA_OMDB_KEY=...` 和 `--dart-define=VIORA_TRAKT_CLIENT_ID=...`。用户设置优先；来源开关可以关闭构建默认值。构建凭据不提交到代码仓库。

## 2. 已实现的标准协议

| 来源 | 请求 | 鉴权 | 解析 |
| --- | --- | --- | --- |
| OMDb | `GET https://www.omdbapi.com/?i=tt...&r=json&apikey=...` | 查询参数 `apikey` | `imdbRating` / `imdbVotes`、`Ratings` 中烂番茄及 Metacritic、`Metascore`、`Rated` |
| Trakt 电影 | `GET https://api.trakt.tv/movies/{IMDb或Trakt ID}/ratings` | `trakt-api-version: 2`、`trakt-api-key: {client_id}` | `rating` / `votes`，0–10 |
| Trakt 剧集 | `GET /shows/{IMDb或Trakt ID}/ratings` | 同上 | 整部剧评分，详情页标明「整剧评分」 |
| Trakt 单集 | `GET /shows/{所属剧ID}/seasons/{季}/episodes/{集}/ratings` | 同上 | 单集评分，不以单集 IMDb ID 代替所属剧 ID |
| Trakt ID 映射 | `GET /search/tmdb/{id}?type=movie` 或 `type=show` | 同上 | 校验类型和返回 TMDB ID，只接受唯一匹配，缓存映射 |

OMDb 单集有自己的 IMDb ID 时直接查询；只有所属剧 IMDb ID 时使用 `Season` / `Episode` 参数，并核对返回的 `seriesID`、季集和 `Type=episode`。媒体库电影/剧集缺少 IMDb ID 时复用现有 TMDB 详情中的 `external_ids` 补全；Trakt 可直接映射 TMDB ID。仅有单集 IMDb ID、没有所属剧 ID 或季集信息时，Trakt 显示无法查询，不猜测所属剧。

响应必须匹配查询身份和类型。`N/A`、无效数字、缺失评分和零投票视为未知。IMDb 票数支持千分位字符串；烂番茄保留百分比，Metacritic 保留百分制，不能把不同来源求平均。媒体库 `CommunityRating` 仍标为媒体库评分，不冒充 IMDb 或豆瓣；影评人评分也保留媒体库来源。

OMDb 的 HTTP 200 仍检查 `Response` / `Error`。401/403、配额耗尽、错误格式、ID 不匹配均作为故障，只有明确没有作品或成功的空评分可以缓存为空。第三方错误文本不直接显示，避免凭据泄露。

## 3. 加载、缓存与同步

- 两个来源由独立 Riverpod 查询加载，先完成的评分立即展示；失败不阻塞其他评分或播放。
- 相同查询共享进行中的请求；每个来源最多同时处理两次查询。
- HTTP 覆盖连接、响应头、响应体的 8 秒超时；Provider 查询有 10 秒预算。响应最大 1 MiB，不自动跟随携带凭据的重定向。
- 429 尊重 `Retry-After` 并对该来源退避。网络、认证、额度及格式错误不写成「无评分」缓存；失败时可显示过期评分，明确标记「旧缓存」。
- 成功数据 TTL 24 小时，成功空结果 6 小时。应用数据目录的 `ratings_cache_v1.json` 最多 512 项，缓存损坏或写失败不影响在线查询。
- 缓存身份包含来源、作品类型、确认的 ID、所属剧与季集，以及来源配置、Key 摘要和代理地址的指纹。更换凭据或 API 地址不能复用旧用户缓存。
- 两类详情页使用同一个可换行的评分组件；每个评分显示来源，已知票数可显示。失败时显示原因和重试按钮；缺少 ID、暂无评分、评分设置读不出来不算故障，详情页首屏不显示提示。
- 局域网发送、WebDAV 和手机配置网页支持评分设置。默认仅同步开关、顺序与地址；「同步评分凭据」是每台设备自己的选择，不会被远端打开。开启后只发送自行填写的凭据（空 Key 不发送，避免清掉对方已填的 Key），构建默认值不导出；缺省 Key 保留接收端值，显式空值清除。评分设置读写失败（系统安全存储不可用）时，局域网 / WebDAV 同步跳过评分部分，不影响其他配置。

## 4. 代码位置与验证范围

| 位置 | 工作 |
| --- | --- |
| `lib/domain/models/external_rating.dart` | 类型明确的查询、评分来源/值/满分/票数/作品身份、分级与结果状态 |
| `lib/domain/models/ratings_settings.dart` | 来源开关、顺序、地址、凭据标准化、构建默认值、同步选择 |
| `lib/core/storage/ratings_settings_store.dart` | 单条系统安全存储记录，原子保存与清除，安全错误提示 |
| `lib/data/metadata/` | 独立 OMDb / Trakt Provider、HTTPS 请求与有界文件缓存 |
| `lib/domain/usecases/ratings_resolver.dart` | 请求去重、并发限制、缓存、退避、离线旧数据 |
| `lib/features/metadata/` | Riverpod 服务、共用评分组件、设置与连接测试 |
| `lib/features/detail/`、`lib/features/tmdb/` | 两类详情页接入，单集与整剧身份隔离 |
| `lib/data/sync/`、`lib/features/sync/` | 配置传输、手机填写、凭据同步选择 |

`test/metadata/` 覆盖用户提供的真实 OMDb 响应字段、Trakt 标准协议模拟、类型/ID/季集核对、N/A/零票、业务错误、限流、去重与并发、TTL/离线/缓存损坏、Key 隔离、存储失败和清除、同步选择及界面部分结果与换行。

本次新增 24 项测试。Dart 3.13.5 配合仓库指定的 Flutter 3.47.7 框架源码完成静态检查，无问题；Flutter 3.44.0 兼容副本的全量回归为 165 项通过、12 项在线测试跳过。兼容副本调整了 SDK 与 sqlite3 约束以适配其工具链，正式项目的 `pubspec.yaml` 与锁文件未修改。Flutter 3.47.7 引擎运行和 Windows / Android 打包尚未在此环境验证。

用户设备已验证 OMDb Key 返回成功；当前执行环境到两个服务的请求均被网络代理拦截，因此本次标准协议测试不等于 Trakt 带凭据的真实联调。设置中的「保存并测试」可在用户设备完成验证。

## 5. 豆瓣与家长指南：待确定数据源

本次没有找到可确认当前开放申请、能用于此项目的豆瓣官方电影评分接口。[豆瓣旧 SDK](https://github.com/douban/douban-client)已归档，历史 v2 文档和网上流传的 Key 不作为稳定协议。后续可以接明确标注豆瓣来源的媒体服务器数据，或有文档的第三方/自建元数据服务；必须核对 subject ID、类型、年份和季信息，不按同名作品选第一条，也不把某季评分标成整剧评分。

家长指南与年龄分级分开。OMDb `Rated`、服务器 `OfficialRating` 和 TMDB 地区分级都不是暴力、裸露等内容指南。当前儿童模式继续依赖已有服务器分级，外部评分不会改写儿童模式规则。

[IMDb 官方 Parents Guide](https://data.imdb.com/documentation/bulk-data-documentation/data-dictionary/parentsGuide)含五类严重程度：性与裸露、暴力与血腥、粗俗语言、酒精/毒品/吸烟、惊吓与紧张场景；说明文字及剧透标记属于更高版本授权数据。完整严重程度数据的[公开商品](https://aws.amazon.com/marketplace/pp/prodview-3r7fik4bgmmcu)当前标价 40,000 美元/12 个月，仅作为核心套餐附加产品，实际费用按用途与合同确定；有[免费有限样本](https://aws.amazon.com/marketplace/pp/prodview-pqstnztzqoq7i)可评估格式。官方 API 的[订阅申请](https://data.imdb.com/documentation/api-documentation/getting-access/)由工作人员审批；不能假定 API 订阅自动包含家长指南。

后续指南单独接 Provider 和详情面板，明确标注单集/整剧及来源，缺失类别为 unknown，不能补成安全等级 None；说明默认隐藏剧透。需要先确认授权或第三方服务覆盖、协议及实际响应。此前候选 `imdbapi.dev` 官网及 Swagger 打开失败，当前可用性未确认，不作为默认依赖。MDBList 也仅为聚合服务候选，未验证其豆瓣及完整指南能力。

## 6. 官方依据

- [OMDb 官网](https://www.omdbapi.com/)、[Key 申请与额度](https://www.omdbapi.com/apikey.aspx)：第三方服务，内容标注 CC BY-NC 4.0，不是 IMDb 官方 API。
- [Trakt 创建应用](https://developer.trakt.tv/docs/create-an-app)、[API 文档](https://trakt.docs.apiary.io/)。
- [IMDb 非商业数据集](https://data.imdb.com/non-commercial-datasets/)：个人、非商业使用条件下可下载日更评分，不含家长指南；批量导入适合可选离线/自建服务。
- [TMDB 电影分级](https://developer.themoviedb.org/reference/movie-release-dates)、[剧集分级](https://developer.themoviedb.org/reference/tv-series-content-ratings)。
