# 数据层（API 适配层）

纯前端，无后端。`js/api.js` 把不同音源统一成同一份契约，UI 只认契约，不关心数据从哪来。

## 文件

| 文件 | 作用 |
| --- | --- |
| `js/config.js` | 音源配置：默认 provider、HTTP 接口地址与路径模板、缓存 TTL |
| `js/api.js` | 适配层：3 个 provider 实现 + 字段归一 + 缓存 + 对外门面 `AuroraAPI` |
| `app.js` | 只调用 `AuroraAPI`，不再内置曲库数据 |

## 统一返回结构

任何 provider 的结果都会被 `normalize()` 归一成：

```js
{
  id: "sample-1",
  title: "有风无风皆自由",
  artist: "王一佳",
  url: "https://.../SoundHelix-Song-1.mp3",   // 可为 null，resolve() 后才有
  duration: 372,                              // 秒，0 表示未知
  bitrate: 320,
  tags: ["原唱", "高音质", "标准"],
  lyrics: [[0, "有风 无风 皆自由"], [8, "行走人海中 做个某某某"]],  // [秒, 文本]
  art: null,                                   // 缺省时用 id 哈希生成渐变封面
  provider: "publicSample"
}
```

## 对外接口

```js
await AuroraAPI.init("publicSample");   // 切换并初始化 provider
await AuroraAPI.getPlaylist();          // 全部曲目
await AuroraAPI.search("王一佳");        // 搜索歌名/歌手
await AuroraAPI.getTrack("sample-1");
await AuroraAPI.resolve(track);         // 并发取播放地址 + 歌词，返回补全后的 track
await AuroraAPI.addFiles(fileList);     // 导入本地文件
await AuroraAPI.removeTrack(id);        // 移除（localFiles 会删 IndexedDB 记录）
AuroraAPI.label();                      // 当前音源名，显示在播放列表顶部
```

`resolve()` 单独拆出来是因为播放地址常常有时效（需要签名/临时 URL），而列表接口不该为此多打一次请求；`app.js` 在 `load()` 里才调用它，失败会回退到 `track.url` 并提示。

## 三个 Provider

**1. `publicSample`（默认）** — 公开测试音源，取 SoundHelix 的示例 MP3，附带一份示例歌词。无需后端、无版权风险，联网即可用。

**2. `localFiles`** — 浏览器本地文件，Blob 存 IndexedDB（`aurora-music` / `local-audio`），刷新后仍在；`URL.createObjectURL` 生成播放地址。切换到此音源后导入的文件会持久化。

**3. `httpProvider`** — 自建接口模板。在 `js/config.js` 填 `base` 与 `endpoints`，支持路径模板变量：

```js
httpProvider: {
  base: "https://your.api.com",
  endpoints: {
    search: "/search?q={q}",
    playlist: "/playlist",
    url: "/song/{id}/url",
    lyrics: "/song/{id}/lyrics"
  }
}
```

接口约定：返回 `Track` 对象或 `{ data: Track | Track[] }`。歌词返回 `{ lyrics: ["[00:08.00]第一行", ...] }`，适配层会解析 LRC 时间戳转成 `[秒, 文本]`。跨域需自行开 CORS。

## 缓存

`AuroraMemoryStore` 为内存 Map，带 TTL：歌词 6 小时、播放地址 5 分钟（覆盖临时 URL 过期）。清缓存：`AuroraMemoryStore` 无公开 clear，需要时刷新页面。

## 加一个自己的音源

1. 在 `js/api.js` 里写一个工厂，返回 `{ label, getPlaylist, search, getTrack, getUrl, getLyrics }`（可选 `addFiles` / `remove`）。
2. 全部返回值用 `normalize(raw, "yourProvider")` 包一层。
3. 注册进 `registry` 对象，并在 `js/config.js` 的 `activeProvider` 指向它。
