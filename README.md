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

## 开发

当前进度：**M0 工程骨架已完成**（假数据），见 [docs/09-roadmap.md](docs/09-roadmap.md)。

```bash
flutter pub get
flutter run -d windows          # Windows（需要 Visual Studio C++ 桌面开发组件）
flutter run -d <android-tv-id>  # Android TV / 模拟器（adb connect <电视IP>:5555 后可见）
flutter test                    # 焦点导航测试
flutter analyze
```

代码结构：

| 目录 | 内容 |
| --- | --- |
| `lib/app/` | 应用入口、路由、主题令牌、应用壳（导航栏 + 内容区）、输入意图与返回键链 |
| `lib/ui/` | 大屏组件库：`DesignScale`（1920 画布缩放）、`Glass`（磨砂玻璃）、`VFocusable`（焦点外壳）、`FocusRow` / `RowFocusScope`（行导航与行记忆）、卡片、按钮、侧边菜单 |
| `lib/features/` | 页面：首页、资源库、详情页（首屏），其余页面为占位 |
| `test/` | 遥控器操作的 Widget 测试（行记忆、导航栏进出、返回键、页面跳转） |

操作：方向键移动；OK / Enter 确认，长按 OK 或菜单键 / 右键打开菜单；返回 / Esc 后退；鼠标悬停即聚焦。

## 测试包与更新

- 推送到 `main` 或 `claude/**` 分支时，GitHub Actions（`.github/workflows/release.yml`）会构建 APK 和 Windows 安装包。
- **发布新测试版**：把 `pubspec.yaml` 的 `version` 改大（如 `0.1.0+1` → `0.1.1+2`）后推送，CI 会自动创建预发布 Release `v0.1.1`。
- 应用内更新：启动 3 秒后静默检查，或在「设置 → 关于与更新」手动检查。
  - 更新源默认是本仓库的 GitHub Releases，**仓库需要公开**客户端才能访问；仓库保持私有时可改用自建 `latest.json` 地址（每个 Release 都附带一份）。
  - Windows：下载安装包后静默覆盖安装，完成后自动重新打开。
  - Android：下载 APK 后拉起系统安装界面；首次需要允许 Viora「安装未知应用」。
- Android 测试包用仓库内的测试证书 `android/keystore/viora-test.jks` 签名（保证每次更新签名一致）。正式发布前应换成私有证书，通过 CI 环境变量 `VIORA_KEYSTORE_PATH` 等注入。
