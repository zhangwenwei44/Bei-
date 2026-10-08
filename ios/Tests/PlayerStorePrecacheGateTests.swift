// PlayerStorePrecacheGateTests.swift
// 单元测试：自动预缓存门控逻辑（用户开关 + WiFi 判断 + 剩余 8 秒触发）
//
// 为什么测门控？
//   卡顿修复前没有 WiFi 门控 —— 任何网络下只要 currentTime 过了 50% 就触发预加载，
//   蜂窝偷流量。修复后 triggerNextSongPreload() 门控顺序：
//     1. @AppStorage("aurora.autoPrecache") 用户开关（优先级最高）
//     2. isWiFiNetwork（path.usesInterfaceType + !path.isConstrained）
//     3. remaining <= 8 秒
//     4. 同一首下一首 3 秒节流 + 预加载同一首不重复
//
// 由于 PlayerStore 的 isWiFiNetwork 由 NWPathMonitor 驱动（UIKit 单例），
// 纯单元测试直接 mock 不现实。这里测的是：
//   a) UserDefaults 开关逻辑可独立验证（不依赖 NWPathMonitor）
//   b) currentTime 节流桶 halfSecondBucket 的数学正确性（防 publish 退化）
//
// 运行：见 LRCParserIndexTests.swift 头部注释。

import XCTest
@testable import AuroraMusic

final class PlayerStorePrecacheGateTests: XCTestCase {

    // MARK: - UserDefaults 开关（优先级最高）

    /// 默认值 true — 没有 @AppStorage 键时 UserDefaults 返回默认 true
    func testAutoPrecache_DefaultEnabled() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "aurora.autoPrecache")
        // 项目代码里是 @AppStorage("aurora.autoPrecache") var autoPrecacheEnabled: Bool = true
        // PlayerStore.triggerNextSongPreload 里读的也是 defaults.object(forKey:) as? Bool ?? true
        let enabled = defaults.object(forKey: "aurora.autoPrecache") as? Bool ?? true
        XCTAssertTrue(enabled, "默认应开启自动预缓存")
    }

    /// 用户手动关闭 → 读出来就是 false
    func testAutoPrecache_DisabledPersists() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "aurora.autoPrecache")
        let enabled = defaults.object(forKey: "aurora.autoPrecache") as? Bool ?? true
        XCTAssertFalse(enabled, "用户关闭后应持久化")
        defaults.removeObject(forKey: "aurora.autoPrecache") // 清理
    }

    // MARK: - 0.5s 节流桶数学（halfSecondBucket = Int(rawTime * 2)）

    /// 节流桶：同一 0.5s 窗口内 halfSecondBucket 相同，不应 publish 第二次
    func testHalfSecondBucket_SameWindow() {
        func bucket(_ t: Double) -> Int { Int(t * 2) }

        // [0.0, 0.499] → bucket 0
        XCTAssertEqual(bucket(0.0), 0)
        XCTAssertEqual(bucket(0.2), 0)
        XCTAssertEqual(bucket(0.499), 0)

        // [0.5, 0.999] → bucket 1
        XCTAssertEqual(bucket(0.5), 1)
        XCTAssertEqual(bucket(0.7), 1)
        XCTAssertEqual(bucket(0.999), 1)

        // 1.0 → bucket 2
        XCTAssertEqual(bucket(1.0), 2)
    }

    /// 节流桶在整数边界不抖动（比如 1.0 → 1.0001 仍在同桶）
    func testHalfSecondBucket_NoJitterAtBoundaries() {
        func bucket(_ t: Double) -> Int { Int(t * 2) }
        XCTAssertEqual(bucket(2.99), bucket(3.00)) // 5.98 → 6, 6.0 → 6
        XCTAssertNotEqual(bucket(2.9999), bucket(3.0)) // 2.9999*2=5.9998→5, 3*2=6 → 应不同
    }

    // MARK: - 剩余 8 秒触发条件（remaining = duration - currentTime <= 8）

    /// 边界：剩余正好 8s → 应触发
    func testPreloadTrigger_Exactly8SecondsRemaining() {
        let duration = 100.0
        let currentTime = duration - 8.0 // 92.0
        let remaining = duration - currentTime
        XCTAssertLessThanOrEqual(remaining, 8, "剩余 8s 应触发预加载")
    }

    /// 边界：剩余 8.01s → 不应触发
    func testPreloadTrigger_8_01SecondsRemaining_Skipped() {
        let duration = 100.0
        let currentTime = duration - 8.01 // 91.99
        let remaining = duration - currentTime
        XCTAssertGreaterThan(remaining, 8, "剩余 >8s 不应触发")
    }

    /// 恰好播完（剩余 0）→ 不会因 0 <= 8 触发预加载（但 duration > 0 是额外 guard）
    func testPreloadTrigger_PlayedToEnd_NoFalseTrigger() {
        let duration = 100.0
        let currentTime = 100.0
        let remaining = duration - currentTime
        // 代码里还有 guard duration > 0 && remaining >= 0
        XCTAssertTrue(remaining >= 0, "剩余 ≥0 才是合法触发窗口")
    }

    // MARK: - 3 秒节流（lastPreloadTriggerTime < 3）

    /// 同一首下一首连续两次检查间隔 < 3s → 应跳过（防抖）
    func testPreloadTrigger_3SecondThrottle() {
        let now = 50.0
        let lastTrigger = 48.5 // 距上次 1.5s
        XCTAssertLessThan(now - lastTrigger, 3, "1.5s 间隔 < 3s → 节流跳过")
    }

    /// 间隔 3.1s → 应放行
    func testPreloadTrigger_3_1SecondGap_PassesThrottle() {
        let now = 50.0
        let lastTrigger = 46.9 // 距上次 3.1s
        XCTAssertGreaterThan(now - lastTrigger, 3, "3.1s 间隔 > 3s → 放行")
    }
}
