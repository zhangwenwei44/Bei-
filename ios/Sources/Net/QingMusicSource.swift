import Foundation

/// 青听音源（QingMusic）适配。
///
/// 青听的 `music.json` 只描述「有哪些源、每个源的平台代码（kg/wy/tx/bili/mg/kw）」，
/// 真正的解析逻辑在这一段共享脚本里：按 `payload.source` 分派到对应平台。
///
/// 当前实现：
/// - **酷狗（kg）**：走公开的 `www.kugou.com/yy/index.php?r=play/getdata` web 接口，
///   绝大多数歌曲无需签名即可拿到播放地址，正好补上 App 因官方 gateway 鉴权失效而停用的官方解析。
/// - **其余平台（wy/tx/bili/mg/kw）**：需要各自平台的歌曲 id（酷狗歌曲没有），
///   且部分接口需要签名，对 AuroraMusic 这类「只搜酷狗、拿酷狗歌曲解析」的 App 来说暂无可用地址，
///   脚本会返回明确错误 —— 在音源设置里显示为红点（无用）。后续若加入多平台搜索，这些源即可生效。
enum QingMusicSource {
    /// 共享解析脚本（按平台分派的 `musicUrl`）。
    static let resolverScript: String = #"""
    (function () {
      // 酷狗：公开 web 接口，绝大多数歌曲不需要签名即可拿到播放地址。
      function kgResolve(m, quality) {
        var hash = m.hash || m.id || m.songmid || m.mid || '';
        if (!hash) return Promise.reject('酷狗缺少 hash');
        var album = m.albumId || m.album_id || '';
        var url = 'https://www.kugou.com/yy/index.php?r=play/getdata'
                + '&hash=' + encodeURIComponent(hash)
                + '&album_id=' + encodeURIComponent(album)
                + '&dfid=&mid=111111&appid=1014&platid=4&version=9999';
        return new Promise(function (resolve, reject) {
          try {
            lx.request(url, { method: 'GET' }, function (err, resp) {
              if (err) return reject('请求失败: ' + err);
              if (!resp) return reject('无响应');
              var body = resp.body;
              if (typeof body === 'string') {
                try { body = JSON.parse(body); } catch (e) { return reject('JSON 解析失败'); }
              }
              if (!body || body.status !== 1) return reject('接口返回异常');
              var data = body.data;
              if (!data) return reject('无 data');
              var play = data.play_url || data.audio_url
                       || (data.backup_url && data.backup_url[0]) || '';
              if (!play) return reject('无播放地址（可能需要签名）');
              if (play.indexOf('http') !== 0) play = 'https://www.kugou.com' + play;
              resolve(play.replace(/\\/g, ''));
            });
          } catch (e) { reject('异常: ' + e); }
        });
      }

      lx.on('musicUrl', function (payload) {
        var info = (payload && payload.info) || {};
        var m = info.musicInfo || {};
        var src = payload && payload.source;
        if (src === 'kg' || src === 'kugou') {
          return kgResolve(m, info.type);
        }
        // 其它平台需要各自平台的歌曲 id，酷狗歌曲无法跨平台解析
        return Promise.reject('该音源仅支持 ' + (src || '?') + ' 平台，当前歌曲无法跨平台解析');
      });
    })();
    """#
}

extension SourceStore {
    /// 解析青听音源配置（`music.json` 的 `lines` 数组）。
    ///
    /// 每条 line 转成一个脚本型 `ThirdPartySource`，绑定上面的共享解析脚本，
    /// 并用 `headers["source"]` 限定平台（kg/wy/...），只对匹配平台的歌曲生效。
    /// 同名音源按「覆盖导入」处理（见 `upsertReplacingByName`）。
    static func parseQingMusic(_ text: String) -> [ThirdPartySource] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 🔴 v2.9.9：青听 music.json 文件头部带一段 `/* ... */` 注释块（作者/版本信息），
        // 直接丢给 JSONSerialization 会整体解析失败、返回空数组 → 表现就是「导入不了」。
        // 先把块注释和行注释都剥掉再解析。
        if let block = try? NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/", options: []) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            trimmed = block.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "")
        }
        if let line = try? NSRegularExpression(pattern: "//[^\\n]*", options: []) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            trimmed = line.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "")
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let lines: [[String: Any]]? = {
            if let lines = object["lines"] as? [[String: Any]] { return lines }
            if let inner = object["data"] as? [[String: Any]] { return inner }
            return nil
        }()
        guard let lines else { return [] }

        var result: [ThirdPartySource] = []
        for line in lines {
            guard let name = line["name"] as? String, !name.isEmpty else { continue }
            let rawID = (line["id"] as? String) ?? ""
            let platform = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let enabled = (line["enabled"] as? Bool) ?? true
            var source = ThirdPartySource(
                name: name,
                kind: .script,
                script: QingMusicSource.resolverScript,
                enabled: enabled
            )
            if !platform.isEmpty {
                source.headers["source"] = platform
            }
            result.append(source)
        }
        return result
    }
}
