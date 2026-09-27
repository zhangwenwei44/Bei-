# Aurora Music（iOS）

原生 SwiftUI 音乐播放器。播放页按酷狗音乐的思路做：白字压在封面取色渐变上，歌词居中逐行高亮，底部信息 → 图标 → 进度 → 控制四段呼吸，没有多余装饰。

音源接口思路搬自开源项目 [Beans-Music](https://github.com/zhangwenwei44/Beans-Music)（酷狗签名接口、第三方解锁源那套）。本仓库只保留学习用的最小实现，代码全部自己重写。

## 功能

| 能力 | 说明 |
| --- | --- |
| 在线播放 | 酷狗音乐直连：搜索 / 排行榜 / 歌词 |
| 播放地址解析 | 官方接口优先；VIP / 无版权时并发尝试用户配置的第三方音源 |
| 下载 | 带进度的后台下载，存 `Documents/Aurora Downloads`，离线可播 |
| 搜索 | 单曲 / 榜单 / 歌手，带搜索历史 |
| 收藏 | 收藏、自建歌单、最近播放、导入本地音频，全部落盘 |
| 第三方音源 | 接口模板 + JS 脚本（LX / MusicPlugin 协议）两种，可导入导出 |
| 播放体验 | 锁屏与控制中心、后台播放、睡眠定时、三种循环模式、耳机拔出暂停 |

## 运行

需要 macOS + Xcode 15+。

```bash
brew install xcodegen
cd ios
xcodegen generate
open AuroraMusic.xcodeproj
```

在 Signing & Capabilities 里选自己的 Team，⌘R 运行到真机。

不想用 XcodeGen 的话：Xcode → New Project → iOS → App（SwiftUI），把 `Sources/` 拖进工程，Build Settings 里把 `INFOPLIST_FILE` 指向 `Sources/Resources/Info.plist`，并在 Link Binary With Libraries 里手动添加 `JavaScriptCore.framework`（脚本音源需要）。

## 结构

```
Sources/
  App/AuroraMusicApp.swift      入口，AVAudioSession 设为 .playback
  Models/
    Song.swift                  歌曲、来源平台、音质档位、播放模式
    Catalog.swift               歌单 / 歌手 / 专辑 + 网易云 JSON 解析
    LyricLine.swift             LRC 解析（含翻译合并）与时间格式化
  Net/
    NetEaseCrypto.swift         weapi / eapi 加密，含一个大整数实现
    NetEaseClient.swift         网易云直连接口
    ThirdPartySource.swift      第三方音源配置模型与存储
    SourceResolver.swift        解析引擎：并发竞速 + 音质降级 + 节点切换
    ScriptSourceRunner.swift    JavaScriptCore 跑 LX 风格脚本
  Player/
    PlayerStore.swift           播放核心：队列、解析、歌词、锁屏控制
    LibraryStore.swift          收藏 / 歌单 / 历史 / 本地 持久化
    DownloadManager.swift       下载与进度
    ArtworkPalette.swift        封面取色（OKLab）
  Views/
    RootView.swift              Tab 容器 + 迷你播放条
    DiscoverView.swift          发现
    SearchView.swift            搜索
    LibraryView.swift           我的音乐
    ProfileView.swift           我的 + 关于
    SourceSettingsView.swift    第三方音源管理
    PlaylistViews.swift         歌单 / 歌手 / 专辑详情
    PlayerView.swift            播放页
    LyricsView.swift            歌词滚动
    QueueView.swift             播放队列
    Components.swift            配色、封面、歌曲行、卡片
Design/DESIGN.md                播放页设计规范
Design/DESIGN_SOURCES.md       第三方音源怎么配
```

## 播放地址是怎么来的

1. 如果这首歌在本地有下载文件，直接用文件；
2. 否则问网易云官方接口（`/api/song/enhance/player/url/v1`），拿到完整地址就用；
3. 官方只给 30 秒试听（`freeTrialInfo`）或干脆不给地址时，把歌丢给所有已启用的第三方音源，**并发**请求，谁先返回可用地址就用谁；
4. 播放失败且用的是第三方地址时，把这个域名拉黑并重新解析，QQ 的 CDN 节点还会自动换几个备用域名。

音质从「我的」里选。请求音质失败会按降级链往下试（Hi-Res → 无损 → 极高 → 较高 → 标准）。

## 第三方音源

见 `Design/DESIGN_SOURCES.md`：接口模板的占位符、请求头特殊键、JS 脚本支持的入口、导入导出格式。

## 注意

- 仅供个人学习研究，遵守各平台服务条款，不要用于商业分发。
- `Info.plist` 里放开了 ATS（`NSAllowsArbitraryLoads`），因为音源地址可能是 http，也可能是局域网自建服务。
- 下载目录开了文件共享，「文件 - 我的 iPhone - Aurora Downloads」里能看到下载的音频。
