import CommonCrypto
import Foundation
import JavaScriptCore

// MARK: - JS 桥

// 注意：所有桥方法的参数都必须是可选类型。
// JavaScriptCore 在把 undefined / null / JS 对象桥接成非可选的 String 或 NSNumber 时
// 会抛 ObjC 异常，那是硬崩溃，Swift 侧 try/catch 拦不住。
// 混淆过的洛雪脚本经常少传参数、或把 new Date() 这类对象传进来，
// 参数改成可选后 JSExport 会传 nil，我们在 Swift 里兜住即可。
@objc protocol ScriptRequestBridge: JSExport {
    /// 对应脚本里的 `lx.request(url, options, callback)`
    func request(_ url: String?, _ options: JSValue?, _ callback: JSValue?)
}

@objc protocol ScriptUtilsBridge: JSExport {
    func md5(_ value: String?) -> String
    func aesEncrypt(_ data: String?, _ mode: String?, _ key: String?, _ iv: String?) -> NSDictionary
    func aesDecrypt(_ data: String?, _ mode: String?, _ key: String?, _ iv: String?) -> String
    func toBase64(_ text: String?) -> String
    func fromBase64(_ text: String?) -> String
    func toHexEncode(_ text: String?) -> String
    func fromHexDecode(_ hex: String?) -> String
    func urlEncode(_ text: String?) -> String
    func urlDecode(_ text: String?) -> String
    func dateFormat(_ time: JSValue?, _ pattern: String?) -> String
    func nowMillis() -> NSNumber
    func nowSeconds() -> NSNumber
    func randomInt(_ min: JSValue?, _ max: JSValue?) -> NSNumber
    func guid() -> String
}

@objc protocol ScriptDoneBridge: JSExport {
    func resolve(_ value: JSValue?)
    func reject(_ value: JSValue?)
}

/// 把 JS 值安全地转成数字/字符串。
/// 直接用 JSValue.toDouble()/toString() 在值是 undefined 或对象时会抛异常。
private func jsDouble(_ value: JSValue?) -> Double? {
    guard let value, !value.isUndefined, !value.isNull else { return nil }
    if value.isNumber, let d = value.toNumber()?.doubleValue { return d }
    if value.isString, let s = value.toString(), let d = Double(s) { return d }
    return nil
}

private func jsInt(_ value: JSValue?) -> Int? {
    guard let d = jsDouble(value), d.isFinite else { return nil }
    return Int(d)
}

final class ScriptCompletion: NSObject, ScriptDoneBridge {
    private let lock = NSLock()
    private var finished = false
    /// reject 带过来的原因，仅用于记日志。
    private(set) var errorMessage: String?
    var onFinish: ((Any?) -> Void)?

    func resolve(_ value: JSValue?) {
        finish(value?.toObject())
    }

    func reject(_ value: JSValue?) {
        if let value, !value.isUndefined, !value.isNull {
            errorMessage = value.toString()
        }
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
        // onFinish 闭包里会引用 completion 自己（读 errorMessage），
        // 触发完就断开，避免循环引用。
        let callback = onFinish
        onFinish = nil
        callback?(value)
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

    func request(_ urlString: String?, _ options: JSValue?, _ callback: JSValue?) {
        guard let urlString, let url = URL(string: urlString) else {
            respond(callback, ["status": 0, "body": "", "bodyType": "text", "error": "地址无效"])
            return
        }

        var request = URLRequest(url: url)
        // JSValue.toString() 对 undefined 返回字符串 "undefined"（不是 nil），
        // 之前 `?? "GET"` 永远不触发，脚本没传 method 时 httpMethod 被设成
        // 字符串 "undefined"，服务端 nginx 直接 400 Bad Request。
        // 必须显式判 undefined / null，并 uppercase（HTTP method 大小写敏感）。
        let methodValue = options?.forProperty("method")
        let resolvedMethod: String = {
            guard let methodValue, !methodValue.isUndefined, !methodValue.isNull else { return "GET" }
            let s = methodValue.toString() ?? ""
            return s.isEmpty ? "GET" : s.uppercased()
        }()
        request.httpMethod = resolvedMethod
        request.setValue("AuroraMusic/1.0", forHTTPHeaderField: "User-Agent")

        // 脚本发出什么请求、拿到什么结果，之前完全没有记录，
        // 播放失败时只能看到「invoke 没返回地址」，无从判断卡在哪一步。
        Log.info("脚本网络", "\(request.httpMethod ?? "GET") \(urlString.prefix(160))")

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
            let http = response as? HTTPURLResponse
            var result: [String: Any] = [:]
            // 洛雪脚本读 statusCode，不是 status
            result["status"] = http?.statusCode ?? 0
            result["statusCode"] = http?.statusCode ?? 0
            result["headers"] = http?.allHeaderFields ?? [:]
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
            let preview = String(data: payload.prefix(160), encoding: .utf8) ?? ""
            Log.info("脚本网络", "  -> \(http?.statusCode ?? 0) / \(payload.count) 字节 / \(preview.prefix(120))")
            self?.respond(callback, result)
        }.resume()
    }

    private func respond(_ callback: JSValue?, _ result: [String: Any]) {
        guard let callback, !callback.isUndefined, !callback.isNull else { return }
        // 脚本传的未必是函数，直接 call 会抛 JS 异常进而崩掉，先确认它是对象/函数
        guard callback.isObject else {
            Log.warn("脚本音源", "回调不是可调用的对象，已忽略")
            return
        }
        // 洛雪的约定是 (err, resp)，第一个参数必须是 null，
        // 否则脚本会把响应体当成错误直接 reject。
        var payload = result
        if payload["status"] == nil, let status = payload["statusCode"] as? Int {
            payload["status"] = status
        }
        let argument = NSDictionary(dictionary: payload)
        let null = NSNull()
        if let owner {
            owner.queue.async { callback.call(withArguments: [null, argument]) }
        } else {
            callback.call(withArguments: [null, argument])
        }
    }

    // MARK: utils

    func md5(_ value: String?) -> String {
        guard let value else { return "" }
        return Data(value.utf8).md5Hex()
    }

    /// 注意：Data 没有 baseAddress，得用 withUnsafeBytes 拿裸指针。
    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func aesEncrypt(_ data: String?, _ mode: String?, _ key: String?, _ iv: String?) -> NSDictionary {
        guard let data, let key, !key.isEmpty else { return ["data": "", "hex": ""] }
        let mode = mode ?? ""
        let iv = iv ?? ""
        let keyData = Data(key.utf8)
        let ivData = Data(iv.utf8)
        let input = Data(data.utf8)
        // 输出缓冲至少要能容纳 PKCS7 补位后的长度，最坏情况是输入的 1.06 倍多 16 字节
        let capacity = input.count + 32
        let isCBC = mode.lowercased().contains("cbc")

        var outBytes = [UInt8](repeating: 0, count: capacity)
        var outLen: size_t = 0
        let options = isCBC ? CCOptions(kCCOptionPKCS7Padding) : CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
        let status = keyData.withUnsafeBytes { keyBytes -> Int32 in
            // Data 没有 baseAddress，用 withUnsafeBytes 包一层拿到裸指针
            ivData.withUnsafeBytes { ivBytes -> Int32 in
                input.withUnsafeBytes { dataBytes -> Int32 in
                    CCCrypt(CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyBytes.baseAddress, keyData.count,
                            isCBC ? ivBytes.baseAddress : nil,
                            dataBytes.baseAddress, input.count,
                            &outBytes, capacity,
                            &outLen)
                }
            }
        }
        guard status == kCCSuccess, outLen > 0, outLen <= capacity else {
            Log.error("脚本音源", "aesEncrypt 失败，status=\(status)，输入 \(input.count) 字节，key \(keyData.count) 字节")
            return ["data": "", "hex": ""]
        }
        let out = Data(outBytes.prefix(Int(outLen)))
        return ["data": out.base64EncodedString(), "hex": ScriptBridge.hexString(out)]
    }

    func aesDecrypt(_ data: String?, _ mode: String?, _ key: String?, _ iv: String?) -> String {
        guard let data, let key, !key.isEmpty else { return "" }
        let mode = mode ?? ""
        let iv = iv ?? ""
        let keyData = Data(key.utf8)
        let ivData = Data(iv.utf8)
        // 洛雪的 aesDecrypt 收的是 base64
        guard let input = Data(base64Encoded: data), !input.isEmpty else { return "" }
        let isCBC = mode.lowercased().contains("cbc")
        let capacity = input.count + 32

        var outBytes = [UInt8](repeating: 0, count: capacity)
        var outLen: size_t = 0
        let options = isCBC ? CCOptions(kCCOptionPKCS7Padding) : CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
        let status = keyData.withUnsafeBytes { keyBytes -> Int32 in
            ivData.withUnsafeBytes { ivBytes -> Int32 in
                input.withUnsafeBytes { dataBytes -> Int32 in
                    CCCrypt(CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyBytes.baseAddress, keyData.count,
                            isCBC ? ivBytes.baseAddress : nil,
                            dataBytes.baseAddress, input.count,
                            &outBytes, capacity,
                            &outLen)
                }
            }
        }
        guard status == kCCSuccess, outLen <= capacity else { return "" }
        return String(data: Data(outBytes.prefix(Int(outLen))), encoding: .utf8) ?? ""
    }

    func toBase64(_ text: String?) -> String {
        guard let text else { return "" }
        return Data(text.utf8).base64EncodedString()
    }

    func fromBase64(_ text: String?) -> String {
        guard let text, let data = Data(base64Encoded: text) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func toHexEncode(_ text: String?) -> String {
        guard let text else { return "" }
        return ScriptBridge.hexString(Data(text.utf8))
    }

    func fromHexDecode(_ hex: String?) -> String {
        guard let hex else { return "" }
        return String(data: Data(hexString: hex), encoding: .utf8) ?? ""
    }

    func urlEncode(_ text: String?) -> String {
        guard let text else { return "" }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    func urlDecode(_ text: String?) -> String {
        guard let text else { return "" }
        return text.removingPercentEncoding ?? text
    }

    /// 洛雪脚本常用 `lx.utils.dateFormat(new Date(), 'YYYY-MM-DD HH:mm:ss')`。
    /// 第一个参数可能是时间戳数字，也可能是 Date 对象，用 JSValue 兜住所有形态。
    func dateFormat(_ time: JSValue?, _ pattern: String?) -> String {
        guard let time, !time.isUndefined, !time.isNull else { return "" }
        var seconds: Double?
        if let d = jsDouble(time) {
            seconds = d
        } else if let object = time.toObject() as? Date {
            seconds = object.timeIntervalSince1970
        } else if time.isObject {
            // new Date() 桥接过来可能是 NSDictionary 形式的日期
            if let d = time.forProperty("getTime")?.call(withArguments: []), let ms = jsDouble(d) {
                seconds = ms / 1000
            }
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return "" }
        let date = seconds > 1_000_000_000 ? Date(timeIntervalSince1970: seconds / 1000)
                                           : Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        // JS 的时间戳是毫秒
        formatter.dateFormat = Self.jsPattern(from: pattern ?? "YYYY-MM-DD HH:mm:ss")
        return formatter.string(from: date)
    }

    private static func jsPattern(from pattern: String) -> String {
        let map: [String: String] = [
            "YYYY": "yyyy", "YY": "yy",
            "MM": "MM", "DD": "dd", "dd": "dd",
            "HH": "HH", "mm": "mm", "ss": "ss",
            "SSS": "SSS", "A": "a",
        ]
        var out = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let ch = pattern[index]
            let next = pattern.index(after: index)
            if let end = pattern[next...].firstIndex(of: ch) {
                let token = String(pattern[index...end])
                if let mapped = map[token] {
                    out += mapped
                } else {
                    out += token
                }
                index = pattern.index(after: end)
            } else {
                out.append(ch)
                index = next
            }
        }
        return out
    }

    func nowMillis() -> NSNumber {
        NSNumber(value: Int64(Date().timeIntervalSince1970 * 1000))
    }

    func nowSeconds() -> NSNumber {
        NSNumber(value: Int64(Date().timeIntervalSince1970))
    }

    func randomInt(_ min: JSValue?, _ max: JSValue?) -> NSNumber {
        guard let low = jsInt(min), let high = jsInt(max) else { return NSNumber(value: 0) }
        guard high > low else { return NSNumber(value: low) }
        // 脚本偶尔会传出天文数字般的范围，直接 random(in:) 会因为跨度过大而崩
        guard high - low <= 1_000_000_000 else {
            return NSNumber(value: low + Int.random(in: 0...1_000_000_000))
        }
        return NSNumber(value: Int.random(in: low...high))
    }

    func guid() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

// MARK: - 运行时

/// 一个脚本对应一个 JSContext，串行队列保证 JSContext 不被并发访问。
final class ScriptRuntime {
    private let context: JSContext
    /// 16MB 专用线程。libdispatch 工作线程只有 512KB 栈，聚合音源脚本
    /// 做签名解密时递归很深，会撞栈保护页变成 SIGTRAP。
    let queue = ScriptExecutor(label: "Aurora.ScriptRuntime")
    private let bridge = ScriptBridge()
    private let sourceName: String
    /// 脚本求值期间是否出现过异常。出现过的运行时一律不再使用。
    private var sawException = false

    init?(source: ThirdPartySource, script: String) {
        guard let context = JSContext() else { return nil }
        self.context = context
        self.sourceName = source.name
        bridge.owner = self

        // JSContext 没有任何线程安全保证，所有访问必须落在同一条线程上。
        // 之前 init 里的 evaluateScript 跑在 buildQueue 上，而 invoke 里的跑在
        // 脚本线程上——同一个上下文被两个线程同时使用，正是 SIGTRAP 的来源。
        // 这里把所有求值都塞进 queue 里统一执行。
        var bootstrapFailed = false
        var scriptFailed = false
        var noEntry = false
        var hasEntryValue: Int32 = 0

        queue.sync {
            context.exceptionHandler = { [weak self] _, exception in
                let message = exception?.toString() ?? "unknown"
                Log.error("脚本音源", "「\(source.name)」JS 异常: \(message)")
                // JavaScriptCore 允许脚本自己 try/catch 把异常吃掉，exception 属性会变回 nil，
                // 但上下文已经处于不确定状态。标记一下，后面直接丢弃这个运行时。
                self?.sawException = true
            }

            context.setObject(self.bridge, forKeyedSubscript: "__beansRequest" as NSString)
            context.setObject(self.bridge, forKeyedSubscript: "__beansUtils" as NSString)
            context.setObject(self.bridge, forKeyedSubscript: "__beansCrypto" as NSString)
            // nativeLog 必须是「函数」，不能是对象，否则脚本按函数调用会抛
            // TypeError: nativeLog is not a function。
            let logBlock: @convention(block) (String) -> Void = { message in
                Log.debug("脚本音源", "「\(source.name)」脚本日志: \(message.prefix(300))")
            }
            context.setObject(unsafeBitCast(logBlock, to: AnyObject.self),
                              forKeyedSubscript: "nativeLog" as NSString)

            let info: [String: Any] = [
                "name": source.name,
                "id": source.id,
                "version": "1.0",
                "author": "",
                "supportOpenDevTools": false,
            ]
            context.setObject(info as NSDictionary, forKeyedSubscript: "__beansInfo" as NSString)

            context.evaluateScript(Self.bootstrap)
            if context.exception != nil {
                bootstrapFailed = true
                return
            }
            self.sawException = false

            context.evaluateScript(script)
            // 不只看 context.exception，还要看异常处理器有没有被叫醒。
            // 脚本自己 catch 掉异常时 exception 会变回 nil，但上下文已经脏了。
            if context.exception != nil || self.sawException {
                scriptFailed = true
                return
            }

            // 兼容 module.exports = { musicUrl }
            context.evaluateScript("globalThis.__beansPlugin = (typeof module !== 'undefined' && module.exports && Object.keys(module.exports).length) ? module.exports : null;")

            hasEntryValue = context.evaluateScript("""
            (function () {
                if (typeof globalThis.__beansHandler === 'function') return 1;
                if (globalThis.__beansPlugin && typeof globalThis.__beansPlugin.musicUrl === 'function') return 1;
                if (globalThis.MusicPlugin && (typeof globalThis.MusicPlugin.getMusicUrl === 'function' || typeof globalThis.MusicPlugin.musicUrl === 'function')) return 1;
                return 0;
            })()
            """)?.toInt32() ?? 0
            noEntry = hasEntryValue != 1
        }

        if bootstrapFailed {
            Log.error("脚本音源", "「\(source.name)」bootstrap 注入失败")
            return nil
        }
        if scriptFailed {
            Log.error("脚本音源", "「\(source.name)」主脚本求值期间出现异常，这个音源本次不可用")
            return nil
        }
        if noEntry {
            Log.error("脚本音源", "「\(source.name)」里找不到入口函数（需要 __beansHandler / module.exports.musicUrl / MusicPlugin.getMusicUrl）")
            return nil
        }
        Log.info("脚本音源", "「\(source.name)」\(script.count) 字符，入口已识别")
    }

    /// 调用前先确认上下文还健康。经历过异常的运行时直接拒绝使用。
    private var isUsable: Bool { !sawException && context.exception == nil }

    /// 作废这个运行时。后续所有调用都会被拒绝，并从缓存里剔除。
    func invalidate() {
        sawException = true
        onInvalidate?(self)
    }

    /// 作废回调，供 ScriptSourceRunner 把自己从缓存里摘掉。
    var onInvalidate: ((ScriptRuntime) -> Void)?

    /// 注入洛雪（lx）兼容层：lx.utils 全套、lx.request、lx.on，
    /// 另外兼容 module.exports.musicUrl 与 MusicPlugin.getMusicUrl。
    private static let bootstrap = """
    (function () {
      var handlers = {};
      globalThis.module = globalThis.module || { exports: {} };

      // 洛雪的脚本普遍这么写：const { EVENT_NAMES, request, on, send } = globalThis.lx
      // EVENT_NAMES 的具体取值不重要（我们按注册的事件名回调），但必须存在，
      // 否则 EVENT_NAMES[xxx] 直接抛 TypeError。用 Proxy 兜住任意取值。
      var EVENT_NAMES = new Proxy({}, {
        get: function (target, prop) {
          if (typeof prop === 'symbol') { return undefined; }
          return String(prop);
        }
      });

      // JavaScriptCore 默认没有 console，脚本里的 console.log 会直接崩
      function makeLog(level) {
        return function () {
          var parts = [];
          for (var i = 0; i < arguments.length; i++) {
            try { parts.push(String(arguments[i])); } catch (e) { parts.push('[unserializable]'); }
          }
          nativeLog(level + ' ' + parts.join(' '));
        };
      }
      globalThis.console = {
        log: makeLog('log'),
        info: makeLog('info'),
        warn: makeLog('warn'),
        error: makeLog('error'),
        debug: makeLog('debug'),
        trace: makeLog('trace')
      };

      // 少数脚本会 require('./env') 拿自己的源码 / 配置，这里给个不报错的实现
      globalThis.require = globalThis.require || function (name) {
        if (String(name).indexOf('env') !== -1) {
          return { scriptInfo: __beansInfo, name: __beansInfo.name || '' };
        }
        return {};
      };

      var utils = {
        md5: function (v) { return __beansUtils.md5(String(v)); },
        aesEncrypt: function (d, m, k, i) { return __beansUtils.aesEncrypt(String(d), String(m), String(k), String(i || '')); },
        aesDecrypt: function (d, m, k, i) { return __beansUtils.aesDecrypt(String(d), String(m), String(k), String(i || '')); },
        base64Encode: function (v) { return __beansUtils.toBase64(String(v)); },
        base64Decode: function (v) { return __beansUtils.fromBase64(String(v)); },
        hexEncode: function (v) { return __beansUtils.toHexEncode(String(v)); },
        hexDecode: function (v) { return __beansUtils.fromHexDecode(String(v)); },
        urlEncode: function (v) { return __beansUtils.urlEncode(String(v)); },
        urlDecode: function (v) { return __beansUtils.urlDecode(String(v)); },
        dateFormat: function (t, p) { return __beansUtils.dateFormat(t, String(p)); },
        getTime13: function () { return __beansUtils.nowMillis(); },
        getTime10: function () { return __beansUtils.nowSeconds(); },
        rand: function (a, b) { return __beansUtils.randomInt(a, b); },
        guid: function () { return __beansUtils.guid(); }
      };
      // 洛雪部分脚本会读 buffer / toBuffer，给个最小可用实现
      utils.toBuffer = function (v) { return { __auroraBuffer: String(v) }; };
      utils.fromBuffer = function (b) { return b && b.__auroraBuffer ? b.__auroraBuffer : ''; };
      utils.buffer = { from: utils.toBuffer, toString: function (b) { return b.__auroraBuffer; } };

      var lx = {
        version: '2.9.0',
        env: 'mobile',
        currentScriptInfo: __beansInfo,
        utils: utils,
        EVENT_NAMES: EVENT_NAMES,
        status: { appVersion: '2.9.0' },
        on: function (event, handler) {
          handlers[event] = handler;
          globalThis.__beansHandler = handler;
        },
        off: function (event) { delete handlers[event]; },
        send: function () {},
        request: function (url, options, callback) { __beansRequest.request(url, options, callback); },
        channel: { send: function () {}, on: function () {} },
        log: function () { if (typeof console !== 'undefined') console.log.apply(console, arguments); }
      };      globalThis.lx = lx;
      globalThis.__beansCall = function (payload, done) {
        // 注意：done 是原生 JSExport 对象（ScriptCompletion），只能调方法。
        // 之前写成 done({ value: ... }) —— JS 对象不是函数，
        // JavaScriptCore 直接抛 TypeError: done is not a function，
        // 而且异常发生在 Promise 回调里，被静默吞掉，
        // 表现为「invoke 永远超时、任何脚本音源都解析不了」。
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
            done.reject('脚本没有可用的解析入口');
            return;
          }
        } catch (error) {
          done.reject(String(error));
          return;
        }
        Promise.resolve(invoke).then(
          function (value) { done.resolve(value); },
          function (error) { done.reject(String(error)); }
        );
      };
    })();
    """

    /// 调用脚本，超时或失败返回 nil。
    ///
    /// 超时 12 秒：长青这类音源在一次解析里会串行发两个请求
    /// （计数 ping + 解析 POST），8 秒在弱网下不够。
    /// 音源本身是串行尝试的，超时太长会让用户干等，不能再往上加了。
    func invoke(payload: [String: Any], timeout: TimeInterval = 12) async -> Any? {
        Log.debug("脚本音源", "invoke 开始，超时 \(Int(timeout)) 秒")
        let result: Any? = await withCheckedContinuation { continuation in
            let completion = ScriptCompletion()
            let lock = NSLock()
            var resumed = false

            /// 返回 true 表示是本次调用第一次落地（用于区分真超时和迟到回调）。
            @discardableResult
            @Sendable func resume(_ value: Any?) -> Bool {
                lock.lock()
                if resumed {
                    lock.unlock()
                    return false
                }
                resumed = true
                lock.unlock()
                continuation.resume(returning: value)
                return true
            }

            completion.onFinish = { value in
                // resolve 直接给值，reject 给 nil（原因在 errorMessage 里）
                if let value {
                    Log.debug("脚本音源", "invoke 收到脚本返回")
                    resume(value)
                    return
                }
                if let message = completion.errorMessage, !message.isEmpty {
                    Log.error("脚本音源", "脚本自己报错：\(message)")
                }
                resume(nil)
            }

            queue.async { [weak self] in
                guard let self else { resume(nil); return }
                guard self.isUsable else {
                    Log.error("脚本音源", "「\(self.sourceName)」运行时已因异常失效，跳过本次调用")
                    resume(nil)
                    return
                }
                self.context.setObject(payload as NSDictionary, forKeyedSubscript: "__beansPayload" as NSString)
                self.context.setObject(completion, forKeyedSubscript: "__beansDone" as NSString)
                self.sawException = false
                Log.debug("脚本音源", "「\(self.sourceName)」开始执行 musicUrl")
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
                Log.debug("脚本音源", "「\(self.sourceName)」musicUrl 同步部分执行完毕")
                if self.context.exception != nil || self.sawException {
                    Log.error("脚本音源", "「\(self.sourceName)」调用期间出现异常，运行时作废")
                    self.invalidate()
                    resume(nil)
                    return
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                // 已经成功/失败过的调用不要再记超时，否则每次慢解析都多一条假告警
                if resume(nil) {
                    Log.warn("脚本音源", "invoke 超过 \(Int(timeout)) 秒没有返回，按超时处理")
                }
            }
        }
        if result == nil {
            Log.error("脚本音源", "invoke 最终没有拿到地址")
        }
        return result
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
        if isTripped(source) {
            Log.debug("脚本音源", "「\(source.name)」处于熔断状态，跳过")
            return nil
        }
        let script = source.script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else {
            Log.error("脚本音源", "「\(source.name)」的脚本文本是空的")
            noteFailure(source)
            return nil
        }
        guard let runtime = runtime(for: source, script: script) else {
            Log.error("脚本音源", "「\(source.name)」\(script.count) 字符的脚本没能建立 JS 运行时（语法错误或不支持的语法）")
            noteFailure(source)
            return nil
        }

        let payload: [String: Any] = [
            "action": "musicUrl",
            "source": song.source.code,
            "info": [
                "type": quality.sourceValue,
                "musicInfo": Self.musicInfo(for: song, quality: quality),
            ],
        ]

        guard let raw = await runtime.invoke(payload: payload) else {
            noteFailure(source)
            Log.error("脚本音源", "「\(source.name)」调用 musicUrl 返回了空（连续失败 \(failureCounts[source.id, default: 0]) 次）")
            return nil
        }
        guard let urlString = Self.extractURLString(from: raw) else {
            noteFailure(source)
            Log.error("脚本音源", "「\(source.name)」的返回里找不到播放地址，原始返回: \(String(describing: raw).prefix(200))")
            return nil
        }
        guard let url = URL(string: urlString) else {
            noteFailure(source)
            Log.error("脚本音源", "「\(source.name)」返回的地址不是合法 URL: \(urlString.prefix(120))")
            return nil
        }
        guard let playable = Self.playable(url, excludedHosts: excludedHosts) else {
            noteFailure(source)
            Log.error("脚本音源", "「\(source.name)」返回的地址不可用: \(urlString.prefix(120))")
            return nil
        }
        failureCounts[source.id] = 0
        return ResolvedAudio(url: playable, sourceName: source.name, quality: quality, isThirdParty: true)
    }

    // MARK: 熔断

    /// 连续失败次数。表现为一首歌就连续失败时，阈值设低一点。
    private let failureLimit = 3
    /// 熔断窗口：只封 60 秒，别一断就是整个运行期——网络抖一下不至于废掉整个音源。
    private let breakerWindow: TimeInterval = 60
    private var failureCounts: [String: Int] = [:]
    private var trippedAt: [String: Date] = [:]
    private let failureLock = NSLock()

    private func noteFailure(_ source: ThirdPartySource) {
        failureLock.lock()
        let next = failureCounts[source.id, default: 0] + 1
        failureCounts[source.id] = next
        if next >= failureLimit, trippedAt[source.id] == nil {
            trippedAt[source.id] = Date()
        }
        failureLock.unlock()
        if next == failureLimit {
            Log.warn("脚本音源", "「\(source.name)」已连续失败 \(next) 次，暂时跳过 \(Int(breakerWindow)) 秒")
        }
    }

    /// 熔断中的音源不再参与解析，避免每首歌都白等一次超时。
    /// 窗口过了自动解封（计数清零），网络恢复后音源立即可用。
    private func isTripped(_ source: ThirdPartySource) -> Bool {
        failureLock.lock()
        defer { failureLock.unlock() }
        guard let tripped = trippedAt[source.id] else { return false }
        if Date().timeIntervalSince(tripped) > breakerWindow {
            trippedAt[source.id] = nil
            failureCounts[source.id] = 0
            return false
        }
        return failureCounts[source.id, default: 0] >= failureLimit
    }

    /// 音源改动后（或用户手动重试）把熔断状态清掉。
    func resetFailures() {
        failureLock.lock()
        failureCounts.removeAll()
        failureLock.unlock()
    }

    private func runtime(for source: ThirdPartySource, script: String) -> ScriptRuntime? {
        let key = "\(source.id)|\(script.hashStable)"
        return buildQueue.sync { () -> ScriptRuntime? in
            if let cached = cache[key] { return cached }
            guard let runtime = ScriptRuntime(source: source, script: script) else { return nil }
            runtime.onInvalidate = { [weak self] dead in
                guard let self else { return }
                self.buildQueue.async {
                    self.cache = self.cache.filter { $0.value !== dead }
                }
            }
            // 脚本改一次就多一个 JSContext，只留最近几个。
            // 混淆脚本的 JSContext 很吃内存，和 AVPlayer 叠在一起容易触发
            // 内存压力被杀（jetsam 不会留下任何崩溃记录，表现就是日志突然断掉）。
            if cache.count >= maxCachedRuntimes, let oldest = cache.keys.sorted().first {
                cache[oldest] = nil
            }
            cache[key] = runtime
            return runtime
        }
    }

    private var maxCachedRuntimes: Int { 3 }

    /// 收到内存警告时把 JSContext 全部丢掉。重新建一次的开销远小于被杀进程。
    func handleMemoryWarning() {
        buildQueue.sync {
            let count = cache.count
            cache.removeAll()
            Log.warn("脚本音源", "内存警告，丢弃了 \(count) 个 JS 运行时缓存")
        }
    }

    /// 按洛雪的 musicInfo 约定投递。
    ///
    /// 洛雪的 custom source 脚本只认这几个字段：
    /// `songmid`(kw) / `copyrightId`+`songId`(wy) / `songmid`(tx) / `hash`(kg)，
    /// 另外会读 `types` 和 `meta` 判断音质支持。缺的字段一律补齐，
    /// 这样一份洛雪脚本不用改就能跑。
    private static func musicInfo(for song: Song, quality: MusicQuality) -> [String: Any] {
        // 酷狗的音频标识是 hash，脚本普遍读 musicInfo.hash / musicInfo.id
        let songID = song.kugouHash.isEmpty ? song.id : song.kugouHash
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
            "albumId": song.kugouAlbumID,
            "album_id": song.kugouAlbumID,
            "audioId": song.kugouAudioID,
            "audioid": song.kugouAudioID,
            "name": song.title,
            "songName": song.title,
            "artist": song.artist,
            "artists": artistList,
            "singer": song.artist,
            "album": song.album,
            "albumName": song.album,
            "interval": Int(song.duration),
            "source": song.source.code,
            // 洛雪脚本会读 musicInfo.types 判断哪些音质位可用
            "types": quality.lxTypes.reduce(into: [String: Any]()) { map, type in
                map[type] = true
            },
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
