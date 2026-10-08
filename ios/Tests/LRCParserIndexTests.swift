// LRCParserIndexTests.swift
// 单元测试：LRCParser.index(at:in:) — 卡顿修复中干掉 firstIndex(where:) O(n²) 的核心替代目标
//
// 为什么测 index(at:in:)？
//   卡顿修复前，BigLyricsView.isNearActive(_:) 每行调 lyrics.firstIndex(where:)
//   → ForEach × firstIndex = O(n²)。修复后 ForEach 直接持有 enumerated() index，
//   isActive/isNearActive 用 idx == currentIndex 比较（O(1)）。
//   所以 LRCParser.index(at:in:) 是 SwiftUI body 外唯一需要保持 O(1) 或 O(n) 正确的
//   歌词行号查找函数 —— PlayerStore.refreshLyric(at:) 每秒调用它来更新 currentLyricIndex。
//
// 运行：Xcode → File → New → Target → Unit Testing Bundle，
//       把本文件拖进测试 target，加 @testable import AuroraMusic。

import XCTest
@testable import AuroraMusic

final class LRCParserIndexTests: XCTestCase {

    // MARK: - 构造歌词数据

    /// 10 行歌词，time 均匀分布在 [1s...10s]
    private func makeLines(count: Int = 10) -> [LyricLine] {
        (1...count).map { LyricLine(time: Double($0), text: "Line \($0)") }
    }

    // MARK: - 基础定位

    /// 时间戳 0 → 应返回第 0 行（最早的歌词）
    func testIndex_ZeroTime_ReturnsFirst() {
        let lines = makeLines()
        XCTAssertEqual(LRCParser.index(at: 0, in: lines), 0)
    }

    /// 时间戳远大于最后一行 → 应返回最后一行 index
    func testIndex_PastEnd_ReturnsLast() {
        let lines = makeLines()
        XCTAssertEqual(LRCParser.index(at: 999, in: lines), lines.count - 1)
    }

    /// 时间戳落在两行之间 → 应返回较近的那行（带 +0.25s 容差）
    func testIndex_BetweenTwoLines_ReturnsEarlier() {
        let lines = makeLines()
        // time=2.3 离 line[2](time=2) 差 0.3，离 line[3](time=3) 差 0.7
        // +0.25s 容差会把 line[2] 算在内，line[3] 不算
        XCTAssertEqual(LRCParser.index(at: 2.3, in: lines), 2)
    }

    /// 时间戳精确等于某行 time → 应返回该行
    func testIndex_ExactMatch_ReturnsSameLine() {
        let lines = makeLines()
        XCTAssertEqual(LRCParser.index(at: 5.0, in: lines), 4)
    }

    // MARK: - 边界条件

    /// 空歌词数组 → 返回 nil（不能崩）
    func testIndex_EmptyLines_ReturnsNil() {
        XCTAssertNil(LRCParser.index(at: 3, in: []))
    }

    /// 单行歌词 → 不管什么时间都返回 0
    func testIndex_SingleLine_AlwaysReturnsZero() {
        let single = [LyricLine(time: 5, text: "Only")]
        XCTAssertEqual(LRCParser.index(at: 0, in: single), 0)
        XCTAssertEqual(LRCParser.index(at: 5, in: single), 0)
        XCTAssertEqual(LRCParser.index(at: 99, in: single), 0)
    }

    /// 负值时间戳 → 应返回 0（第一行 time=0 满足 time+0.25>=0）
    func testIndex_NegativeTime_ReturnsFirst() {
        let lines = makeLines()
        XCTAssertEqual(LRCParser.index(at: -10, in: lines), 0)
    }

    // MARK: - O(n) 性能 sanity check（不是严格 benchmark，只是防退化）

    /// 200 行歌词 + 200 次 index 查询 → 应能在 10ms 内完成。
    /// 如果有人把 index(at:in:) 改回 firstIndex(where:) O(n)，
    /// 200×200 = 40000 次比较会明显变慢。
    func testIndex_Performance_200x200_Under10ms() {
        let lines = makeLines(count: 200)
        let start = CFAbsoluteTimeGetCurrent()
        for t in stride(from: 0, to: 200, by: 1) {
            _ = LRCParser.index(at: t, in: lines)
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(elapsed, 10, "index(at:in:) 200×200 应在 10ms 内，实际 \(elapsed)s")
    }

    // MARK: - ParseResult 元数据剥离（歌词页修复的配套）

    /// LRC 里带 [ar:xxx] [ti:xxx] 头部 → 不应进入 lines
    func testParse_StripsLRCHeaders() {
        let lrc = """
        [ar:王杰]
        [ti:不浪漫罪名]
        [00:02]词：王杰
        [00:04]曲：王杰
        [00:10]没有花 这刹那被破坏吗
        [00:15]无野火都会温暖吗
        """
        let result = LRCParser.parse(lrc)
        // ar: / ti: 头部跳过；词/曲 0-1.5s 归入 metadata；只有正文歌词进入 lines
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines.first?.text, "没有花 这刹那被破坏吗")
        XCTAssertEqual(result.metadata["词"], "王杰")
        XCTAssertEqual(result.metadata["曲"], "王杰")
    }

    /// 普通 LRC 不夹带 metadata → 所有歌词都进 lines，metadata 空
    func testParse_NoMetadata_AllLines() {
        let lrc = """
        [00:05]第一句
        [00:10]第二句
        [00:15]第三句
        """
        let result = LRCParser.parse(lrc)
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertTrue(result.metadata.isEmpty)
    }

    /// 翻译合并：按 ±0.35s 时间戳对齐
    func testParse_WithTranslation_AlignsByTime() {
        let lrc = "[00:05]Hello\n[00:10]World"
        let tlyric = "[00:05]你好\n[00:10]世界"
        let result = LRCParser.parse(lrc, translation: tlyric)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].translation, "你好")
        XCTAssertEqual(result.lines[1].translation, "世界")
    }
}
