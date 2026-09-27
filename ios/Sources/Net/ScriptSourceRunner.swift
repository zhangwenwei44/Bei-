import CommonCrypto
import Foundation
import JavaScriptCore

// MARK: - JS 桥

@objc protocol ScriptRequestBridge: JSExport {
    /// 对应脚本里的 `lx.request(url, options, callback)`
    func request(_ url: String, _ options: JSValue?, _ callback: JSValue?)
}

@objc protocol ScriptUtilsBridge: JSExport {
    func md5(_ value: String) -> String
    func aesEncrypt(_ data: String, _ mode: String, _ key: String, _ iv: String) -> NSDictionary
}

@objc protocol ScriptDoneBridge: JSExport {
    func resolve(_ value: JSValue?)
    func reject(_ value: JSValue?)
}

final class ScriptCompletion: NSObject, ScriptDoneBridge {
    private let lock = NSLock()
    private var finished = false
    var onFinish: ((Any?) -> Void)?

    func resolve(_ value: JSValue?) {
        finish(value?.toObject())
    }

    func reject(_ value: JSValue?) {
        finish(nil)
    }

    private func finish(_ value: Any?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        onFinish?(value)
    }
}

/// 暴露给脚本的网络与工具方法。
final class ScriptBridge: NSObject, ScriptRequestBridge, ScriptUtilsBridge {
    weak var owner: ScriptRuntime?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func request(_ urlString: String, _ options: JSValue?, _ callback: JSValue?) {
        guard let url = URL(string: urlString) else {
            respond(callback, ["status": 0, "body": "", "bodyType": "text", "error": "地址无效"])
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = (options?.forProperty("method")?.toString()) ?? "GET"
        request.setValue("AuroraMusic/1.0", forHTTPHeaderField: "User-Agent")

        if let headers = options?.forProperty("headers")?.toObject() as? [String: Any] {
            for (key, value) in headers {
                request.setValue(String(describing: value), forHTTPHeaderField: key)
            }
        }
        if let body = options?.forProperty("body"), !body.isUndefined, !body.isNull {
            if body.isString, let text = body.toString() {
                request.httpBody = Data(text.utf8)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            } else if let object = body.toObject(), JSONSerialization.isValidJSONObject(object) {
                request.httpBody = try? JSONSerialization.data(withJSONObject: object)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            var result: [String: Any] = [:]
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result["status"] = status
            result["headers"] = (response as? HTTPURLResponse)?.allHeaderFields ?? [:]
            if let error {
                result["error"] = error.localizedDescription
                result["body"] = ""
                result["bodyType"] = "text"
                self?.respond(callback, result)
                return
            }
            let payload = data ?? Data()
            if let object = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]) {
                result["body"] = object
                result["bodyType"] = "json"
            } else {
                result["body"] = String(data: payload, encoding: .utf8) ?? ""
                result["bodyType"] = "text"
            }
            self?.respond(callback, result)
        }.resume()
    }

    private func respond(_ callback: JSValue?, _ result: [String: Any]) {
        guard let callback else { return }
        let argument = NSDictionary(dictionary: result)
        if let owner {
            owner.queue.async { callback.call(withArguments: [argument]) }
        } else {
            callback.call(withArguments: [argument])
        }
    }

    // MARK: utils

    func md5(_ value: String) -> String {
        Data(value.utf8).md5Hex()
    }

    func aesEncrypt(_ data: String, _ mode: String, _ key: String, _ iv: String) -> NSDictionary {
        let keyData = Data(key.utf8)
        let ivData = Data(iv.utf8)
        let input = Data(data.utf8)
        let isCBC = mode.lowercased().contains("cbc")

        var outBytes = [UInt8](repeating: 0, count: input.count + 32)
        var outLen: size_t = 0
        let options = isCBC ? CCOptions(kCCOptionPKCS7Padding) : CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
        let status = keyData.withUnsafeBytes { keyBytes in
            input.withUnsafeBytes { dataBytes in
                CCCrypt(CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        options,
                        keyBytes.baseAddress, keyData.count,
                        isCBC ? ivData.baseAddress : nil,
                        dataBytes.baseAddress, input.count,
                        &outBytes, outBytes.count,
                        &outLen)
            }
        }
        guard status == kCCSuccess else {
            return ["data": "", "hex": ""]
        }
        let out = Data(outBytes.prefix(outLen))
        return ["data": out.base64EncodedString(), "hex": out.map { String(format: "%02x", $0) }.joined()]
    }
}

// MARK: - 运行时

/// 一个脚本对应一个 JSContext，串行队列保证 JSContext 不被并发访问。
final class ScriptRuntime {
    private let context: JSContext
    let queue = DispatchQueue(label: "Aurora.ScriptRuntime")
    private let bridge = ScriptBridge()
    private let sourceID: String

    init?(source: ThirdPartySource, script: String) {
        guard let context = JSContext() else { return nil }
        self.context = context
        self.sourceID = source.id
        bridge.owner = self

        context.exceptionHandler = { _, exception in
            NSLog("[音源脚本] \(source.name) 异常: \(exception?.toString() ?? "unknown")")
        }

        context.setObject(bridge, forKeyedSubscript: "__beansRequest" as NSString)
        context.setObject(bridge, forKeyedSubscript: "__beansUtils" as NSString)
        context.setObject(bridge, forKeyedSubscript: "__beansCrypto" as NSString)

        let info: [String: Any] = [
            "name": source.name,
            "id": source.id,
            "version": "1.0",
            "author": "",
            "supportOpenDevTools": false,
        ]
        context.setObject(info as NSDictionary, forKeyedSubscript: "__beansInfo" as NSString)

        context.evaluateScript(Self.bootstrap)
        if context.exception != nil { return nil }

        context.evaluateScript(script)
        if context.exception != nil { return nil }

        // 兼容 module.exports = { musicUrl }
        context.evaluateScript("globalThis.__beansPlugin = (typeof module !== 'undefined' && module.exports && Object.keys(module.exports).length) ? module.exports : null;")

        let hasEntry = context.evaluateScript("""
        (function () {
            if (typeof globalThis.__beansHandler === 'function') return 1;
            if (globalThis.__beansPlugin && typeof globalThis.__beansPlugin.musicUrl === 'function') return 1;
            if (globalThis.MusicPlugin && (typeof globalThis.MusicPlugin.getMusicUrl === 'function' || typeof globalThis.MusicPlugin.musicUrl === 'function')) return 1;
            return 0;
        })()
        """)?.toInt32()

        guard hasEntry == 1 else { return nil }
    }

    /// 注入 lx / MusicPlugin 兼容层，并定义 __beansCall。
    private static let bootstrap = """
    (function () {
      var handlers = {};
      globalThis.module = globalThis.module || { exports: {} };
      var lx = {
        version: '2.8.0',
        env: 'mobile',
        currentScriptInfo: __beansInfo,
        utils: {
          md5: function (v) { return __beansUtils.md5(String(v)); },
          aesEncrypt: function (d, m, k, i) { return __beansUtils.aesEncrypt(String(d), String(m), String(k), String(i || '')); }
        },
        on: function (event, handler) {
          handlers[event] = handler;
          globalThis.__beansHandler = handler;
        },
        off: function (event) { delete handlers[event]; },
        send: function () {},
        request: function (url, options, callback) { __beansRequest.request(url, options, callback); },
        channel: { send: function () {}, on: function () {} },
        log: function () { if (typeof console !== 'undefined') console.log.apply(console, arguments); }
      };
      globalThis.lx = lx;
      globalThis.__beansCall = function (payload, done) {
        var info = payload.info || {};
        var invoke = null;
        try {
          if (typeof globalThis.__beansHandler === 'function') {
            invoke = globalThis.__beansHandler(payload);
          } else if (globalThis.MusicPlugin && typeof globalThis.MusicPlugin.getMusicUrl === 'function') {
            invoke = globalThis.MusicPlugin.getMusicUrl(payload.source, info.musicInfo, info.type);
          } else if (globalThis.MusicPlugin && typeof globalThis.MusicPlugin.musicUrl === 'function') {
            invoke = globalThis.MusicPlugin.musicUrl(payload.source, info.musicInfo, info.type);
          } else if (globalThis.__beansPlugin && typeof globalThis.__beansPlugin.musicUrl === 'function') {
            invoke = globalThis.__beansPlugin.musicUrl(payload.source, info.musicInfo, info.type);
          } else if (globalThis.__beansPlugin && typeof globalThis.__beansPlugin.getMusicUrl === 'function') {
            invoke = globalThis.__beansPlugin.getMusicUrl(payload.source, info.musicInfo, info.type);
          } else {
            done({ error: '脚本没有可用的解析入口' });
            return;
          }
        } catch (error) {
          done({ error: String(error) });
          return;
        }
        Promise.resolve(invoke).then(
          function (value) { done({ value: value }); },
          function (error) { done({ error: String(error) }); }
        );
      };
    })();
    """

    /// 调用脚本，超时或失败返回 nil。
    func invoke(payload: [String: Any], timeout: TimeInterval = 12) async -> Any? {
        await withCheckedContinuation { continuation in
            let completion = ScriptCompletion()
            let lock = NSLock()
            var resumed = false

            func resume(_ value: Any?) {
                lock.lock()
                if resumed {
                    lock.unlock()
                    return
                }
                resumed = true
                lock.unlock()
                continuation.resume(returning: value)
            }

            completion.onFinish = { value in
                guard let dict = value as? [String: Any], dict["error"] == nil else {
                    return resume(nil)
                }
                resume(dict["value"])
            }

            queue.async { [weak self] in
                guard let self else { return resume(nil) }
                self.context.setObject(payload as NSDictionary, forKeyedSubscript: "__beansPayload" as NSString)
                self.context.setObject(completion, forKeyedSubscript: "__beansDone" as NSString)
                self.context.evaluateScript("""
                (function () {
                  try {
                    __beansCall(__beansPayload, __beansDone);
                  } catch (error) {
                    __beansDone.reject(error && error.message ? error.message : String(error));
                  }
                  return 1;
                })();
                """)
                if self.context.exception != nil {
                    NSLog("[音源脚本] \(self.sourceID) 调用失败")
                    resume(nil)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resume(nil)
            }
        }
    }
}

// MARK: - 解析入口

final class ScriptSourceRunner {
    static let shared = ScriptSourceRunner()

    private let buildQueue = DispatchQueue(label: "Aurora.ScriptSourceRunner")
    private var cache: [String: ScriptRuntime] = [:]

    func resolve(source: ThirdPartySource,
                 song: Song,
                 quality: MusicQuality,
                 excludedHosts: Set<String>) async -> ResolvedAudio? {
        let script = source.script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return nil }
        guard let runtime = runtime(for: source, script: script) else { return nil }

        let payload: [String: Any] = [
            "action": "musicUrl",
            "source": song.source.code,
            "info": [
                "type": quality.sourceValue,
                "musicInfo": Self.musicInfo(for: song),
            ],
        ]

        guard let raw = await runtime.invoke(payload: payload),
              let urlString = Self.extractURLString(from: raw),
              let url = URL(string: urlString),
              let playable = Self.playable(url, excludedHosts: excludedHosts) else {
            return nil
        }
        return ResolvedAudio(url: playable, sourceName: source.name, quality: quality, isThirdParty: true)
    }

    private func runtime(for source: ThirdPartySource, script: String) -> ScriptRuntime? {
        let key = "\(source.id)|\(script.hashStable)"
        return buildQueue.sync { () -> ScriptRuntime? in
            if let cached = cache[key] { return cached }
            guard let runtime = ScriptRuntime(source: source, script: script) else { return nil }
            // 脚本改一次就多一个 JSContext，只留最近几个
            if cache.count >= 8, let oldest = cache.keys.sorted().first {
                cache[oldest] = nil
            }
            cache[key] = runtime
            return runtime
        }
    }

    /// 脚本里常见的字段名，尽量都带上。
    private static func musicInfo(for song: Song) -> [String: Any] {
        let songID = song.neteaseID.map(String.init) ?? song.id
        let artistList = song.artist
            .components(separatedBy: CharacterSet(charactersIn: "/&,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return [
            "id": songID,
            "songId": songID,
            "musicId": songID,
            "copyrightId": songID,
            "contentId": songID,
            "rid": songID,
            "mid": songID,
            "songmid": songID,
            "mediaMid": songID,
            "media_mid": songID,
            "strMediaMid": songID,
            "hash": songID,
            "name": song.title,
            "songName": song.title,
            "artist": song.artist,
            "artists": artistList,
            "singer": song.artist,
            "album": song.album,
            "albumName": song.album,
            "albumId": "",
            "interval": Int(song.duration),
            "source": song.source.code,
            "types": [String: Any](),
            "meta": [String: Any](),
        ]
    }

    /// 从脚本返回值里挖出播放地址。
    private static func extractURLString(from raw: Any) -> String? {
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("http") ? trimmed : nil
        }
        guard let dict = raw as? [String: Any] else { return nil }
        let keys = ["url", "musicUrl", "music_url", "playUrl", "audioUrl", "src", "streamUrl", "link", "data"]
        for key in keys {
            if let value = dict[key] {
                if let text = value as? String, text.hasPrefix("http") { return text }
                if let nested = extractURLString(from: value) { return nested }
            }
        }
        return nil
    }

    private static func playable(_ url: URL, excludedHosts: Set<String>) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        return excludedHosts.contains(host) ? nil : url
    }
}
