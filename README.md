# KUgou

一个 SwiftUI 写的第三方音乐播放器，播放页按酷狗音乐的排版思路做：白字压在封面取色渐变上，歌词居中逐行高亮，底部信息 → 图标 → 进度 → 控制四段呼吸。

默认音源是**酷狗音乐**（搜索 / 歌词 / 榜单 / 封面直连），播放地址交给可配置的第三方音源脚本解析。接口思路来自开源项目 [Beans-Music](https://github.com/zhangwenwei44/Beans-Music)，本仓库只保留学习用的最小实现，代码全部重写。

| | |
| --- | --- |
| 平台 | iOS 16.0+ / iPhone · iPad |
| 语言 | Swift 5.9 · SwiftUI |
| 依赖 | 仅系统框架（JavaScriptCore 用于跑脚本音源） |
| 签名 | 无签名 + ldid 伪签名，供越狱设备 / TrollStore 安装 |

## 拿 IPA

**Actions（推荐）**

1. 打开仓库的 Actions 页，点 `Build iOS (unsigned IPA)` → `Run workflow`；
2. 跑完后在这次 run 的 Artifacts 里下载 `AuroraMusic-unsigned-ipa`；
3. 把里面的 `.ipa` 传到手机，用 AppSync / Sileo / TrollStore 安装。

**Releases**

打一个 `v*` tag 会同时构建并把 IPA 挂到 Release：

```bash
git tag v1.0.0 && git push kugou main --tags
```

**本地 macOS**

```bash
brew install xcodegen ldid
./scripts/build-unsigned-ipa.sh      # 产物在 dist/
```

安装步骤和排错见 [`ios/JAILBREAK.md`](ios/JAILBREAK.md)。

## 功能

- **在线播放**：酷狗音乐直连，搜索 / 排行榜 / 歌词
- **地址解析**：官方接口优先；VIP 或无版权时并发尝试用户配置的第三方音源，谁先返回可用地址就用谁
- **下载**：带进度的下载，存 `Documents/Aurora Downloads`，离线可播
- **收藏**：收藏、自建歌单、最近播放、导入本地音频，全部落盘
- **第三方音源**：内置洛雪脚本音源（一键启用，不用再选文件），另支持接口模板 + JS 脚本自行添加
- **播放体验**：锁屏与控制中心、后台播放、睡眠定时、三种循环模式、耳机拔出暂停

第三方音源怎么配见 [`ios/Design/DESIGN_SOURCES.md`](ios/Design/DESIGN_SOURCES.md)。

## 目录

```
ios/            SwiftUI 工程（XcodeGen，project.yml 是唯一事实来源）
  Sources/      全部源码
  Design/       播放页设计规范、音源配置说明
  JAILBREAK.md  越狱设备安装与排错
  README.md     工程结构与运行方式
scripts/        本地打包脚本
.github/        CI：构建无签名 IPA
```

根目录下的 `index.html` / `app.js` / `style.css` / `js/` 是早期的一个网页版原型，保留作为对照，与 iOS 工程无关。

## 本地开发

需要 macOS + Xcode 15+：

```bash
brew install xcodegen
cd ios && xcodegen generate && open AuroraMusic.xcodeproj
```


## 第三方音源

音源页里有「内置音源」区块，随包带了两个洛雪脚本，点一下就能启用，不用再选文件。

- **墨澜聚合音源 v2.3.3** — MIT，作者白姬9527，随仓库分发
- **长青SVIP音源 v1.2.0** — 没有 license 声明，仓库无权再分发。
  它的文件已放在 ios/BundledSources/changqing.js（被 .gitignore 排除），
  **你本地打包会带上它**，别人克隆则需要自己放

想加别的脚本，把 .js 丢进 ios/BundledSources/ 重新打包即可，
详见 [ios/BundledSources/README.local.md](ios/BundledSources/README.local.md)
和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

如果文件选择器还是不顺手，「粘贴内容导入」和「从剪贴板导入」两条路都绕开了权限问题。
## 注意

仅供个人学习与研究使用，请遵守各平台服务条款，不要用于商业分发。音乐、商标及各平台服务归其所有者所有。

MIT
