// SongRowEquatableTests.swift
// 单元测试：SongRow: Equatable — 卡顿修复中 7 处 SongRow 加 .equatable() 的基础依赖
//
// 为什么测 SongRow Equatable？
//   卡顿修复前 DiscoverView / PlaylistViews / LibraryView / QueueView / SearchView
//   共 7 处 SongRow 都没有 .equatable() —— SwiftUI 每次 body 重建都会重新
//   评估整个 ForEach 的 item identity，哪怕只有 store.isPlaying 变了（这是每
//   0.5s 节流刷新的），全部 Cell 都可能重建。
//   修复后 7 处都加了 .equatable()，依赖 Components.swift 里手写的 Equatable：
//     lhs.song.id == rhs.song.id  && isCurrent && isPlaying && showsCover
//   trailing 是 AnyView 不走等式比较（本身就是频繁变化信号）。
//
// 运行：见 LRCParserIndexTests.swift 头部注释。

import XCTest
@testable import AuroraMusic

final class SongRowEquatableTests: XCTestCase {

    // MARK: - 构造工具

    private func makeSong(id: String? = nil,
                          title: String = "Test Song") -> Song {
        Song(id: id,
             title: title,
             artist: "Test Artist",
             album: "Test Album",
             url: nil,
             duration: 180,
             artworkURL: nil,
             source: .kugou)
    }

    private func makeRow(song: Song,
                         isCurrent: Bool = false,
                         isPlaying: Bool = false,
                         showsCover: Bool = true) -> SongRow {
        SongRow(song: song,
                isCurrent: isCurrent,
                isPlaying: isPlaying,
                showsCover: showsCover)
    }

    // MARK: - 相等场景（Equatable == 预期返回 true）

    /// 完全相同 → 应相等
    func testEquatable_SameAllTrue() {
        let row1 = makeRow(song: makeSong())
        let row2 = makeRow(song: makeSong())
        XCTAssertTrue(row1 == row2, "同 song.id + 同布尔字段 → 应相等")
    }

    /// song.name 不同但 id 相同 + 其他相同 → 应相等（Equatable 只比 song.id）
    func testEquatable_SongNameIgnored() {
        let row1 = makeRow(song: makeSong(id: "same", title: "A"))
        let row2 = makeRow(song: makeSong(id: "same", title: "B"))
        XCTAssertTrue(row1 == row2, "song.name 不同但 id 相同 → Equatable 应返回 true（只比 song.id）")
    }

    /// isCurrent / isPlaying / showsCover 全部 false → 应相等
    func testEquatable_AllBooleansFalse() {
        let row1 = makeRow(song: makeSong(), isCurrent: false, isPlaying: false, showsCover: false)
        let row2 = makeRow(song: makeSong(), isCurrent: false, isPlaying: false, showsCover: false)
        XCTAssertTrue(row1 == row2)
    }

    // MARK: - 不等场景

    /// song.id 不同 → 不相等
    func testEquatable_SongIdDifferent_False() {
        let row1 = makeRow(song: makeSong(id: "A"))
        let row2 = makeRow(song: makeSong(id: "B"))
        XCTAssertFalse(row1 == row2)
    }

    /// isCurrent 一变 → 不相等（这就是 .equatable() 防 Cell 误重建的关键场景）
    func testEquatable_IsCurrentDifferent_False() {
        let song = makeSong()
        let row1 = makeRow(song: song, isCurrent: false)
        let row2 = makeRow(song: song, isCurrent: true)
        XCTAssertFalse(row1 == row2)
    }

    /// isPlaying 一变 → 不相等
    func testEquatable_IsPlayingDifferent_False() {
        let song = makeSong()
        let row1 = makeRow(song: song, isPlaying: false)
        let row2 = makeRow(song: song, isPlaying: true)
        XCTAssertFalse(row1 == row2)
    }

    /// showsCover 一变 → 不相等
    func testEquatable_ShowsCoverDifferent_False() {
        let song = makeSong()
        let row1 = makeRow(song: song, showsCover: true)
        let row2 = makeRow(song: song, showsCover: false)
        XCTAssertFalse(row1 == row2)
    }

    // MARK: - trailing AnyView 不走等式比较

    /// trailing 即使传不同 AnyView，只要四个关键字段相同 → 仍应相等。
    /// Equatable 实现里根本不看 trailing。这个测试防有人改 Equatable 实现时把 trailing 也算进去。
    func testEquatable_TrailingAnyView_NotConsidered() {
        let song = makeSong()
        let row1 = SongRow(song: song, trailing: AnyView(Text("A")))
        let row2 = SongRow(song: song, trailing: AnyView(Text("B")))
        XCTAssertTrue(row1 == row2, "trailing 不同但关键字段相同 → 应相等（.equatable() 不看 trailing）")
    }

    // MARK: - 7 处调用场景回归（防后续改动退化）

    /// 场景模拟：播放状态变了（store.isPlaying true→false），但 song 还是同一首 → 只有当前行 isPlaying 变
    /// Equatable 正确区分，.equatable() 只重建当前行 Cell，其他 99 行跳过。
    func testEquatable_ScrollJankRegression_PlayingToggle() {
        let sameSong = makeSong()

        // 模拟一个 10 行列表，只有第 3 行是当前播放
        var before: [SongRow] = []
        var after: [SongRow] = []
        for i in 0..<10 {
            let isCurrent = i == 3
            before.append(makeRow(song: makeSong(id: "id-\(i)"),
                                  isCurrent: isCurrent, isPlaying: false))
            after.append(makeRow(song: makeSong(id: "id-\(i)"),
                                 isCurrent: isCurrent, isPlaying: isCurrent)) // 只有当前行 playing 变 true
        }

        // before vs after 逐行比较
        for i in 0..<10 {
            if i == 3 {
                XCTAssertFalse(before[i] == after[i], "当前播放行 isPlaying 变了 → 应重建")
            } else {
                XCTAssertTrue(before[i] == after[i], "非当前行关键字段都没变 → .equatable() 会跳过重建")
            }
        }
    }
}
