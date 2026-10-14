# 本地音源槽位

把第三方洛雪音源脚本（`.js`）直接丢在这个目录，重新打包就会被塞进 IPA。

```
ios/BundledSources/你的音源.js
```

## 规则

- 所有脚本文件都被 `.gitignore` 排除：**会打进 IPA，但不会进仓库**
- 这样做是因为没有 license 声明的代码默认保留所有权利，仓库无权再分发；
  但你自己下载、自己打包使用不受影响

## CI 怎么拿到这些文件

`actions/checkout` 因为上面的 .gitignore 规则拿不到脚本，所以 CI 改成从
**v2.5.0 Release 资产 `bundled-sources.tar.gz`** 下载解包：

```
https://github.com/zhangwenwei44/Bei-/releases/download/v2.5.0/bundled-sources.tar.gz
```

资产不存在时 CI 打印警告并继续，产出「无内置音源」的干净包
（用户手动导入音源，功能不受影响）。

## 更新内置音源

```bash
cd ios/BundledSources
tar -czf bundled-sources.tar.gz *.js
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

应用启动时会把本目录里所有 `.js` 都注册成可选音源，
在「我的 → 第三方音源 → 内置音源」里点「添加」即可。

音源名、版本、作者、许可从脚本头部的注释里读：

```js
/*!
 * @name 音源名称
 * @version 1.0.0
 * @author 作者
 * @license MIT
 */
```

## 注意

脚本由原作者提供服务，可能随时失效或需要自备 cookie。
本目录不会随仓库分发，别人克隆后需要自己提供脚本。
