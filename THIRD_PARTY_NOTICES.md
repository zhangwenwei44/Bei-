# 第三方音源署名

本应用通过「内置音源」机制随包发布第三方洛雪（lx-music）音源脚本。它们由各自的作者开发并提供服务，
本仓库只做分发，不修改其逻辑，也不保证可用性。

## 随包发布：洛雪音源6（`luoxue.js`）

| 项 | 值 |
|---|---|
| 脚本内名称 | K×H测试 |
| 版本 | 1.7.17 |
| 作者 | HYW & Koneko |
| 许可 | **MIT**（脚本头部 `@license MIT` 声明） |
| 主页 | https://github.com/Miao-moe |

因为声明了 MIT（允许再分发），脚本本体随仓库走：`ios/BundledSources/luoxue.js`。
应用首次启动时会自动把它装进「音源列表」，在列表里显示为「默认音源」。

> 该脚本内部包含若干第三方解析服务的接入凭据，均由脚本作者提供并已随其公开发布。
> 本仓库不对这些服务的可用性作任何保证。

## 本地槽位：任何 `*.local.js` 及其他无 license 的 `.js`

`ios/BundledSources/` 下**没有 license 声明**的脚本（第三方音源常见）默认**不入库**，
但会被打进 IPA。要使用请自行把文件放到该目录：

```
ios/BundledSources/你的音源.js
```

`.gitignore` 已排除该类脚本，因此：

- **本地打包**的 IPA 里会包含它
- **CI（GitHub Actions）打出的 IPA**只有通过 Release 资产
  `bundled-sources.tar.gz` 提供的那些会包含（见下）
- 公开仓库里不会出现它
- 别人克隆后需要自己提供

这样做是因为没有 license 声明的代码默认保留所有权利，仓库无权再分发。

## CI 怎么拿到这些文件

`actions/checkout` 因为上面的 .gitignore 规则拿不到无 license 的脚本，所以 CI 改成从
**v2.5.0 Release 资产 `bundled-sources.tar.gz`** 下载解包：

```
https://github.com/zhangwenwei44/Bei-/releases/download/v2.5.0/bundled-sources.tar.gz
```

**仓库内已有同名文件时以仓库版本为准**（解包用 `--keep-old-files`，再逐个比对跳过），
所以即使 CDN 缓存导致拿到旧 tarball，也不会把仓库里的 `luoxue.js` 覆盖成旧版本。

资产不存在时 CI 打印警告并继续，产出的包只含仓库内的 `luoxue.js`
（用户手动导入音源，功能不受影响）。

## 更新本地槽位里的脚本

```bash
cd ios/BundledSources
tar -czf bundled-sources.tar.gz *.local.js
# 上传到 v2.5.0 Release，资产名必须叫 bundled-sources.tar.gz
```

验证上传是否正确（**必须能解出 .js 才算成功**）：

```bash
curl -sL "https://github.com/zhangwenwei44/Bei-/releases/download/v2.5.0/bundled-sources.tar.gz?nocache=$(date +%s)" -o /tmp/b.tgz
tar -tzf /tmp/b.tgz          # 应列出 .js 文件名
```

> **上传踩过的坑**：手动拼 multipart 会把 boundary 头一起存进资产，
> 下到的是请求体而不是文件。用 `curl --data-binary` 上传裸文件，
> 或检查资产前 2 字节是不是 gzip 魔号 `1f8b`。
>
> GitHub Release 的 CDN 有缓存，改完资产后验证要带 `?nocache=<时间戳>`，
> 否则下到的还是旧文件。

## 生效方式

应用启动时会把本目录里所有 `.js` 都注册成可选音源（内置音源在「我的 → 第三方音源 →
音源列表」里以「默认音源」显示，不暴露脚本音乐名）。

音源名、版本、作者、许可从脚本头部的注释里读：

```js
/*!
 * @name 音源名称
 * @version 1.0.0
 * @author 作者
 * @license MIT
 */
```

## 使用须知

- 这些脚本本质是转发到第三方服务的解析器，服务可能随时变更、限流或关闭
- 部分音源需要用户自备 cookie（脚本头部的 `@tx_cookie` / `@wy_cookie`），
  没有则只能解析公开可用的部分
- 仅供个人学习研究，请遵守各平台服务条款，不要用于商业分发
