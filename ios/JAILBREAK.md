# 越狱设备安装说明

本仓库的 CI 产出的是**无签名（ldid 伪签名）IPA**，不能上架 App Store，只能装在越狱设备或 TrollStore 环境。

## 产物

| 来源 | 路径 |
| --- | --- |
| GitHub Actions | Actions 页 → 最新一次 `Build iOS (unsigned IPA)` → Artifacts → `AuroraMusic-unsigned-ipa` |
| 打 tag 触发 | Releases 页 `v1.0.0` 的附件 |
| 本地 Mac | `scripts/build-unsigned-ipa.sh` → `dist/AuroraMusic-<version>-unsigned.ipa` |

包信息：bundle id `com.aurora.music`，最低 iOS 16.0，Release 配置。

## 安装方式

**Sileo / Zebra（推荐）**
1. 把 `.ipa` 传到手机（AirDrop / 夸克 / 浏览器下载均可）。
2. Sileo → 开发者 → 添加 `ldid` 与 `AppSync Unified`。
3. 用 Filza 打开 `.ipa`（`unzip` 出 `Payload/AuroraMusic.app`）。
4. Filza 内长按 `AuroraMusic.app` → 用 AppSync 打开 → Install。
5. 首次启动后如果闪退，用 Filza 进 `/Library/MobileSubstrate/DynamicLibraries` 无需操作；改用 `ldid -S` 重新伪签名 AppSync 才会装。

**AppSync 2（老设备 / rootful）**
1. `ldid -S -S<entitlements.plist> AuroraMusic.app` 后打成 ipa。
2. AppSync 里开启「Install/Uninstall IPA」，把 ipa 放 `/var/mobile/Documents`，用 AppSync 打开即可。

**TrollStore（永久签名，2.7.3+ 设备）**
CI 产物本身不带 TrollStore 的永久签名，`ldid` 伪签名后的包可导入 TrollStore 由它用 CoreTrust Bypass 重新签名；TrollStore 首次安装需要它自己处理 `ldid` 缺失的信任链。
若只想稳定安装，用 `ldid -S` 处理后在 TrollStore 导入 `.tipa` 即可长期保留。

**Filza 直装（无需 AppSync）**
Filza → 打开 `.ipa` 会自动解压 → 进入 `Payload/` → 长按 `.app` → 拷贝到 `/var/containers/Bundle/Application/` 对应目录后在 Filza 内执行，或直接用 Filza 的「安装包」功能。

## 常见问题

| 现象 | 原因 / 解决 |
| --- | --- |
| 安装提示 `Invalid Signature` | 包没伪签名。用 `brew install ldid && ldid -S AuroraMusic.app` 重新处理，或在设备端 `apt install ldid` |
| 装上但一点就闪退 | 缺 dylib 依赖（本项目不依赖 tweak，理论上不会出现；若出现检查 `DYLD` 注入冲突，用 ElleKit 排除本 bundle id） |
| 提示 `Requires API level` | 设备 iOS < 16.0 |
| 没有声音 | 未授予网络（示例音源走公网），或被其他 tweak 的音频 session 劫持（SpringBoard 关闭其他音频插件重试） |
| 音乐不自动播放 | iOS 17+ 的自动播放策略，需手动点一次播放键 |

## 想加 tweak 依赖

项目默认不注入任何 dylib。若需要注入（例如显示更多控制项），在 `ios/project.yml` 增加：

```yaml
    settings:
      base:
        OTHER_LDFLAGS: "$(inherited) -Wl,-sectcreate,__RESTRICT,__restrict /dev/null"
        LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/Frameworks /usr/lib/TweakInject"
```

并在 `Info.plist` 加 `LSApplicationQueriesSchemes`，注入后需用 `ldid -S` 伪签名并把 dylib 一起放进 `Frameworks/`。

## 重新打包

```bash
# 改完代码后
git tag v1.0.1 && git push --tags      # 触发 CI 并发 Release
# 或在 Actions 页手动点 Run workflow
```
