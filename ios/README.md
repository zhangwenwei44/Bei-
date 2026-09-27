# Aurora Music (SwiftUI)

原生 iOS 播放器，播放页 1:1 还原参考图：毛玻璃背景取色、Hero 大字标题、逐行歌词高亮滚动、标签行、六个操作按钮、可拖动进度条、循环模式 / 上一首 / 播放 / 下一首 / 列表、底部会员条。

## 运行

需要 macOS + Xcode 15+。两种方式任选：

**A. XcodeGen（推荐）**

```bash
brew install xcodegen
cd ios
xcodegen generate
open AuroraMusic.xcodeproj
```

在 Signing & Capabilities 里选自己的 Team，⌘R 运行到真机。

**B. 手动建工程**

1. Xcode → File → New → Project → iOS → App，命名为 `AuroraMusic`，Interface 选 SwiftUI，Language 选 Swift。
2. 把 `Sources/` 下所有文件夹拖进工程（勾选 Copy items if needed → 目标选 "Add to targets"）。
3. Build Settings 里删除自动生成的 `Info.plist` 引用，改填 `Sources/Resources/Info.plist` 路径；把 `Sources/Resources/Assets.xcassets` 加进工程。
4. 选 Team 后 ⌘R。

## 结构

| 文件 | 作用 |
| --- | --- |
| `Sources/App/AuroraMusicApp.swift` | 入口，`AVAudioSession` 设为 `.playback`（后台播放） |
| `Sources/Models/Song.swift` | 歌曲模型、播放模式、示例曲库 |
| `Sources/Models/LyricLine.swift` | 歌词行模型 + LRC 解析器 + 时间格式化 |
| `Sources/Player/PlayerStore.swift` | `AVPlayer` 封装：进度、歌词定位、队列、收藏、锁屏/控制中心远程命令、`NowPlaying` |
| `Sources/Views/RootView.swift` | 曲库列表 + 迷你播放条 + 全屏播放页容器 |
| `Sources/Views/PlayerView.swift` | 播放页全部控件（对应参考图） |
| `Sources/Views/LyricsView.swift` | 歌词滚动与当前行高亮 |
| `Sources/Views/QueueView.swift` | 播放列表抽屉、导入本地音频、删除/清空 |

## 特性

- 封面取色渐变背景，歌曲切换时平滑过渡（`ArtworkPalette`）
- 锁屏 / 控制中心：播放、暂停、上下曲、进度拖动、跳过 15 秒、循环模式
- 耳机拔出自动暂停；后台音频（Info.plist 已声明 `UIBackgroundModes: audio`）
- 播放模式循环：列表循环 / 单曲循环 / 随机
- 收藏状态用 `UserDefaults` 持久化
- Haptics：切歌、模式切换、进度起手
- 下拉手势关闭播放页；本地音频通过 `fileImporter` 导入

## 换成自己的音乐

替换 `Song.swift` 里的 `DemoLibrary.songs` 的 `url` 为你的音频直链（AVPlayer 支持 http(s) 直链与 HLS `.m3u8`）。歌词可换成解析 LRC 文本：`LRCParser.parse(歌词字符串)`，把结果赋给 `PlayerStore.lyrics`。

## 注意

示例音频来自 SoundHelix 公共测试文件，需要联网；离线时用播放列表里的「添加本地音频」导入。
