# Viora

面向 **Windows** 与 **Android TV** 的大屏媒体播放器。连接 Emby / Jellyfin / Plex / 飞牛影视（fnOS），把多台服务器聚合成同一个片库，用 TMDB 做首页推荐和元数据补全，支持反向代理线路、多版本资源选择、自动跳过片头片尾和自定义播放 UA。

UI 参考 iOS 端 Rex 的信息结构（首页 / 详情 / 资源库），并针对 10 英尺大屏、遥控器和键鼠做了重新设计。

## 设计文档

| 文档 | 内容 |
| --- | --- |
| [docs/01-overview.md](docs/01-overview.md) | 产品定位、功能范围、技术选型、整体架构 |
| [docs/02-architecture.md](docs/02-architecture.md) | 工程结构、分层、核心数据模型与接口 |
| [docs/03-media-servers.md](docs/03-media-servers.md) | Emby / Jellyfin / Plex / fnOS 适配、多线路、反向代理、自定义 UA |
| [docs/04-aggregation.md](docs/04-aggregation.md) | 聚合索引、聚合搜索、多资源（多版本）选择 |
| [docs/05-metadata-and-segments.md](docs/05-metadata-and-segments.md) | 元数据优先级、TMDB 接入、片头片尾数据源与合并策略 |
| [docs/06-ui-design.md](docs/06-ui-design.md) | 大屏设计规范与各页面线框（首页 / 详情 / 资源库 / 搜索 / 播放器 / 设置） |
| [docs/07-input-control.md](docs/07-input-control.md) | 遥控器与键鼠操作方案、焦点系统 |
| [docs/08-player.md](docs/08-player.md) | 播放内核、HDR / 字幕 / 音轨、进度上报、跳过片头片尾交互 |
| [docs/09-roadmap.md](docs/09-roadmap.md) | 里程碑与待确认事项 |
