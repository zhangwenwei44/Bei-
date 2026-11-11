import SwiftUI
import Foundation

// MARK: - 歌曲列表吸顶行图标（2026-11-12 用户给的三张截图 1:1 自绘）
//
// 三张图连通域量化的结果（深墨色统一 #3C3C43 = 60,60,67）：
//   ① 排序：浅灰圆角方块 (228,228,233) 内 24×22 的两支细线箭头，
//      左箭头 ↓（x=0..11）、右箭头 ↑（x=12..23），竖杆 2px、V 形（人字）箭头头。
//   ② 多选：24×20，两个勾 (9×7) + 三条 12×2 短横（不是两个方框）。
//   ③ 新建歌单：24×24 圆角方框（2px 描边）+ 居中的 12×2 加号。
// 🔴 全部自绘：不依赖任何 SF Symbol（项目红线：不存在的符号名会静默渲染空白）。

// MARK: 排序按钮

/// 浅灰圆角方块 + 左↓右↑ 双箭头。方块是截图里按钮自身的底色，一并还原。
struct ImmersiveSortIcon: View {
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 228 / 255, green: 228 / 255, blue: 233 / 255))
            // 原图箭头占方块 34%×31%（24×22 / 70×70），按同一比例缩到 30pt 按钮里。
            SortDualArrowShape()
                .stroke(color, style: StrokeStyle(lineWidth: 0.95, lineCap: .round, lineJoin: .round))
                .frame(width: 11, height: 10)
        }
        .frame(width: 30, height: 30)
    }
}

/// 原图 24×22：两支**细线箭头**，箭头头是 V 形（不是实心三角），
/// 竖杆 / 斜线都是 2px 宽。18 倍像素放大确认过形状。
private struct SortDualArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: rect.width / 24, dy: rect.height / 22)
        let sx = r.width / 24, sy = r.height / 22
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + x * sx, y: r.minY + y * sy)
        }
        var p = Path()
        // 左 ↓：竖杆 + 人字形 V 头
        p.move(to: P(5.5, 0)); p.addLine(to: P(5.5, 21))
        p.move(to: P(0, 14)); p.addLine(to: P(5.5, 21)); p.addLine(to: P(11, 14))
        // 右 ↑：竖杆 + 人字形 ^ 头
        p.move(to: P(17.5, 21)); p.addLine(to: P(17.5, 0))
        p.move(to: P(12, 6)); p.addLine(to: P(17.5, 0)); p.addLine(to: P(23, 6))
        return p
    }
}

// MARK: 多选按钮

/// 两个勾 + 三条短横（原图是「部分勾选的列表」，不是两个空心方框）。
struct ImmersiveMultiSelectIcon: View {
    let color: Color

    var body: some View {
        ZStack {
            MultiSelectBarShape().fill(color)
            MultiSelectCheckShape()
                .stroke(color, style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 22, height: 18.5)
    }
}

/// 三条 12×2 短横，原图 y = 0 / 9 / 18，x = 12..24。
private struct MultiSelectBarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24, sy = rect.height / 20
        var p = Path()
        for y in [CGFloat(0), 9, 18] {
            p.addRect(CGRect(x: rect.minX + 12 * sx,
                             y: rect.minY + y * sy,
                             width: 12 * sx, height: 2 * sy))
        }
        return p
    }
}

/// 两个勾，原图折线 (0,3.5)→(3,6.5)→(8,0.5) 与 (0,16.5)→(3,19.5)→(8,13.5)。
private struct MultiSelectCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24, sy = rect.height / 20
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var p = Path()
        p.move(to: P(0.5, 3.5)); p.addLine(to: P(3, 6.5)); p.addLine(to: P(8, 0.5))
        p.move(to: P(0.5, 16.5)); p.addLine(to: P(3, 19.5)); p.addLine(to: P(8, 13.5))
        return p
    }
}

// MARK: 新建歌单按钮

/// 圆角方框 + 加号（原图 24×24）。
struct ImmersiveNewPlaylistIcon: View {
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(color, lineWidth: 2)
                .padding(1)
            NewPlaylistPlusShape().fill(color)
        }
        .frame(width: 22, height: 22)
    }
}

private struct NewPlaylistPlusShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        var p = Path()
        p.addRect(CGRect(x: rect.minX + 6 * s, y: rect.minY + 11 * s,
                         width: 12 * s, height: 2 * s))
        p.addRect(CGRect(x: rect.minX + 11 * s, y: rect.minY + 6 * s,
                         width: 2 * s, height: 12 * s))
        return p
    }
}

/// 吸顶行的「新建歌单」按钮：自带输入弹窗 + 酷狗云歌单创建 + 刷新通知。
/// 🔴 两个 alert 挂在【不同节点】：iOS 15 同一视图链式叠多个 .alert 只有最后一个生效。
struct PlaylistCreateButton: View {
    let color: Color

    @ObservedObject private var auth = KugouAuth.shared
    @State private var showCreate = false
    @State private var newName = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        ZStack {
            Button {
                newName = ""
                if auth.isLoggedIn {
                    showCreate = true
                } else {
                    errorMessage = "请先登录酷狗账号，再新建歌单"
                }
                Haptics.light()
            } label: {
                ImmersiveNewPlaylistIcon(color: color)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            // 失败/未登录提示挂在按钮节点，输入弹窗挂在外层 ZStack —— 两个不同节点，
            // 避免 iOS 15 同一视图链式叠多个 .alert 只有最后一个生效。
            .alert("新建歌单",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .alert("新建歌单", isPresented: $showCreate) {
            TextField("歌单名称", text: $newName)
            Button("创建") { Task { await submit() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("在你的酷狗账号下创建一个新的云歌单")
        }
    }

    private func submit() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await KugouClient.shared.createPlaylist(name: name)
            newName = ""
            Haptics.light()
            NotificationCenter.default.post(name: .auroraKugouPlaylistChanged, object: nil)
        } catch {
            errorMessage = error.localizedDescription
            Log.error("酷狗", "新建歌单失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 字母快速索引

/// 「按歌曲名/歌手名 A–Z 排序」时右侧的 A–Z 条。
/// 中文按拼音首字母归组（与 DownloadsList.makeGroups 完全同一套规则），
/// 所以中文歌单也有可用的字母索引。
enum PlaylistLetterIndex {
    static func isActive(_ mode: PlaylistSortMode) -> Bool {
        mode == .titleAZ || mode == .artistAZ
    }

    static func key(_ song: Song, mode: PlaylistSortMode) -> String {
        mode == .artistAZ ? song.artist : song.cleanTitle
    }

    static func letter(for text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return "#" }
        let s = String(first).uppercased()
        if s >= "A" && s <= "Z" { return s }
        let mutable = NSMutableString(string: t) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let latin = (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
        if let pf = latin.first {
            let ps = String(pf).uppercased()
            if ps >= "A" && ps <= "Z" { return ps }
        }
        return "#"
    }

    /// 返回：① 实际出现的字母（A–Z 顺序，# 放最后）；② 每组第一首歌 id → 字母，供 .id() 锚点。
    /// 🔴 入参必须是【已排好序】的数组，这样同一字母的歌天然连续。
    static func build(_ songs: [Song], mode: PlaylistSortMode) -> (letters: [String], anchors: [String: String]) {
        var firstOfGroup: [String: String] = [:]
        var present = Set<String>()
        for song in songs {
            let l = letter(for: key(song, mode: mode))
            present.insert(l)
            if firstOfGroup[l] == nil { firstOfGroup[l] = song.id }
        }
        let aToZ = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map { String($0) }
        var letters = aToZ.filter { present.contains($0) }
        if present.contains("#") { letters.append("#") }
        var anchors: [String: String] = [:]
        for (letter, id) in firstOfGroup { anchors[id] = letter }
        return (letters, anchors)
    }

    /// scrollTo 的锚点 id。用 .top 会被吸顶行盖住，这里把目标放在可见区约 12% 处
    /// （正好落在吸顶行下方），不改动任何列表布局。
    static let scrollAnchor = UnitPoint(x: 0.5, y: 0.12)

    static func anchorID(_ letter: String) -> String { "sort-sec-\(letter)" }
}

struct PlaylistLetterIndexBar: View {
    let letters: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(letters, id: \.self) { letter in
                Button {
                    onSelect(letter)
                    Haptics.light()
                } label: {
                    Text(letter)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.30, green: 0.32, blue: 0.36))
                        .frame(width: 18, height: 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
        .background(Capsule().fill(Color.white.opacity(0.74)))
        .overlay(Capsule().stroke(Color.black.opacity(0.05), lineWidth: 0.5))
        .padding(.trailing, 2)
    }
}
