# 09 · 里程碑与待确认事项

## 1. 里程碑

| 阶段 | 内容 | 产出 |
| --- | --- | --- |
| M0 工程骨架 | Flutter 工程（Windows + Android TV）、主题与 1920 缩放、TV 组件库（焦点卡片 / 行 / 导航栏 / 面板）、输入意图映射 | ✅ 已完成：可用遥控器和键鼠浏览的假数据首页、资源库、详情首屏 |
| M1 Emby 打通 | 网络拦截器链（线路 / 代理 / UA / 鉴权）、Emby 适配器、资源库页、媒体库网格、mpv 播放、进度上报 | ✅ v0.2.0：Emby / Jellyfin 登录、多线路测速与自动切换、反向代理改写、自定义 UA、资源库 → 媒体库 → 详情 → 播放、进度上报；Windows 与 Android 均先用 mpv 播放 |
| M2 Android TV 播放 | `viora_exoplayer` 插件、PlayerEngine 双实现、HDR / 音频直通 / 自动帧率、播放器 OSD 与面板 | TV 上流畅播放 4K HDR |
| M3 聚合 | 聚合索引同步、作品匹配、详情页播放资源面板、多版本选择与播放中切换、聚合搜索 | 多台服务器合并成一个片库 |
| M4 TMDB 首页 | TMDB 客户端与缓存、首页全部推荐行、动态背景、人物页、平台/公司/分类页 | 与 Rex 对齐的首页与详情页 |
| M5 片头片尾 | SegmentResolver、服务器 Provider（Emby/Jellyfin/Plex）、第三方 Provider、跳过按钮与自动下一集、手动标记 | 完整的跳过体验 |
| M6 Jellyfin / Plex | Jellyfin 子类差异、Plex PIN 登录与 resources 多线路、Plex Markers | 四类服务器中的三类完成 |
| M7 fnOS | 抓包分析飞牛影视 Web API，实现浏览 + 播放 + 进度 | 四类服务器全部支持 |
| M8 打磨 | 设置页完整化、配置导入导出、错误面板、性能（低端 TV 盒子 2GB 内存）、日志导出 | 第一个公开版本 |

## 2. 待确认事项

| # | 问题 | 影响 |
| --- | --- | --- |
| 1 | 技术栈是否接受 Flutter + 双内核方案（见 01 §3） | 全局 |
| 2 | TheOtherDB、PublicMetaDB、IntroDB、TheIntroDB 的 API（暂时留空，Provider 先做接口占位） | 05 §3 |
| 3 | 飞牛影视是否有可用的官方或社区 API 文档 | M7 工作量 |
| 4 | ~~反向代理服务端类型~~ 已确认：emby-reverse-proxy-go（见 03 §5.2） | — |
| 5 | ~~默认主题~~ 已确认：深色 | — |
| 6 | 首页推荐默认是否隐藏"无资源"的 TMDB 条目 | 06 §4 |
| 7 | Android TV 最低版本（建议 Android 7.0 / API 24） | 兼容性与 ExoPlayer 能力 |
| 8 | 外部评分（豆瓣 / IMDb / 烂番茄）与家长指南的数据源 | 详情页后续版本 |
