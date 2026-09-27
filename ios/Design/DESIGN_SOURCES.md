# 第三方音源

音源配置只存在本机（`UserDefaults`），仓库里不内置任何服务地址。全部在「我的 → 第三方音源」里自己添加。

## 两种形态

### 1. 接口模板

一个 URL 模板，程序把占位符换掉，请求它，从响应里按字段路径取出播放地址。

| 字段 | 说明 |
| --- | --- |
| 名称 | 随便起，方便自己认 |
| 请求地址 | 模板本体，见下方占位符 |
| 地址字段 | 响应里播放地址的字段路径，多个用 `\|` 分隔，例如 `data.url\|url\|data.music.url`。响应不是 JSON（直接返回一段以 `http` 开头的文本）时这项可以不管 |
| 默认音质 | `128k` / `320k` / `flac`，同时作为 `{quality}` 的值 |
| 请求头 | 每行一条 `Key=Value` |

占位符：

| 占位符 | 含义 |
| --- | --- |
| `{id}` | 歌曲 ID，QQ 的场景也会填 mid |
| `{name}` | 歌名（已 URL 编码） |
| `{artist}` | 歌手（已 URL 编码） |
| `{keyword}` | 歌名 + 歌手（已 URL 编码） |
| `{source}` | 平台代码，酷狗是 `kg` |
| `{quality}` / `{br}` / `{level}` | 音质档位 |
| `{apiKey}` / `{apikey}` / `{key}` | 密钥，配合请求头里的 `apiKey` |

请求头里的特殊键：

| 键 | 作用 |
| --- | --- |
| `apiKey` | 单个密钥，程序会作为 `X-API-Key` 请求头发出去 |
| `apiKeys` | 多个密钥，逗号分隔，逐个尝试，记住能用的那个 |
| `source` | 限定平台（`wy` / `tx` / `kg`）。填了之后这条音源只处理该平台的歌 |
| `quality` | 没填「默认音质」时的兜底 |

例：

```
https://your.api/song/url?id={id}&br={quality}&source={source}
```

```
apiKey=xxxx,yyyy
source=wy
```

### 2. JS 脚本

用 JavaScriptCore 跑，注入 `lx` 对象，脚本返回一个播放地址字符串。支持三种入口，按顺序探测：

```js
// LX 风格
lx.on('request', async (payload) => {
  // payload.source   平台代码，如 'wy'
  // payload.info.type        音质
  // payload.info.musicInfo   歌曲信息（id / name / artist / album / mid / hash …）
  const res = await lx.request(`https://your.api/url?id=${payload.info.musicInfo.id}&br=${payload.info.type}`, {
    method: 'GET',
    headers: { Referer: 'https://your.api/' }
  })
  return res.body.data.url
})

// 或 module.exports 风格
module.exports = {
  musicUrl: async (source, musicInfo, type) => 'https://cdn/xxx.mp3'
}

// 或 MusicPlugin 风格
const MusicPlugin = {
  getMusicUrl: async (source, musicInfo, type) => 'https://cdn/xxx.mp3'
}
```

脚本里可用的东西：

| 名称 | 说明 |
| --- | --- |
| `lx.request(url, options, callback)` | 发 HTTP 请求，回调收到 `{ status, headers, body, bodyType, error }`，`body` 已经是解析好的对象或字符串 |
| `lx.utils.md5(str)` | MD5 |
| `lx.utils.aesEncrypt(data, mode, key, iv)` | AES 加密，`mode` 含 `cbc` 走 CBC，否则 ECB；返回 `{ data: base64, hex }` |
| `lx.env` / `lx.version` / `lx.currentScriptInfo` | 运行环境信息 |
| `console.log` | 走 NSLog，输出到系统日志 |

返回值可以是字符串，也可以是 `{ url }`、`{ data: { url } }` 这类嵌套结构，程序会自己挖。

脚本超时 12 秒。

## 怎么用

1. 「我的 → 第三方音源 → 新增」，选模板或脚本；
2. 填完先点**测试解析**，程序用《晴天》跑一遍完整流程，告诉你成没成；
3. 通了再打开开关。

解析顺序说明：官方接口永远先试，只有拿不到完整地址才会用第三方音源。所有启用的音源是**并发**请求的，不是从上到下依次试——慢源或失效的不会拖住播放。所以列表顺序只影响谁先被尝试，不影响谁赢。

## 导入导出

「从 JSON 导入」支持三种形态，字段缺了会用默认值补上：

```json
{ "name": "我的音源", "template": "https://api/song?id={id}&br={quality}", "urlPath": "data.url|url", "headers": { "apiKey": "xxx" } }
```

```json
[ { "name": "音源 A", "url": "https://a.com/?id={id}" }, { "name": "音源 B", "template": "https://b.com/?id={id}" } ]
```

```json
{ "sources": [ { "name": "音源 C", "template": "https://c.com/?id={id}" } ] }
```

`url` 会当成 `template`。`kind` 写了 `script` / `lx` / `plugin` 之一的按脚本处理，只填了 `script` 内容没写 `kind` 的也按脚本处理。
