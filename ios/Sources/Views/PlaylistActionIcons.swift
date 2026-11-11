import SwiftUI
import UIKit
import Foundation

// MARK: - 全局图标规格（《酷狗音乐 UI 设计规范》四·3，2026-11-12 严格执行）
//
// 用户给的约束文件 `酷狗音乐 UI 设计规范 · DESIGN.md.txt`：
//   「### 3. 图标系统 —— 风格：线性简约、粗细统一 1.5px；主图标色：酷狗蓝 / 纯白；
//     次要图标：灰色系；无复杂渐变、无厚重写实」
// 项目落地口径：**24×24 画布 / 1.5pt 线宽 / 圆头圆角 / 墨迹统一 20×20pt**。
// 🔴 任何一排并列图标（歌单吸顶行 / 竖屏播放器动作行）都必须共用这里的值。
//    不允许再出现 0.95 / 2.0 / 2.3 / 0.85× 这类各自为政的线宽与尺寸。
enum AppIconSpec {
    /// 标准画布（pt）
    static let canvas: CGFloat = 24
    /// 规范规定的统一线宽（pt，在 24pt 画布下）
    static let strokeWidth: CGFloat = 1.5
    /// 所有图标的墨迹包围盒（pt）
    static let ink: CGFloat = 20

    /// 按显示尺寸等比换算线宽：size=24 时正好 1.5pt。
    static func stroke(for size: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: strokeWidth * size / canvas,
                    lineCap: .round, lineJoin: .round)
    }
}

// MARK: - 歌曲列表吸顶行图标（2026-11-12 按约束文件统一重绘）
//
// 三枚图标原来各画各的：排序 30×30 灰底里塞 11×10 的 0.95pt 箭头、
// 多选 22×18.5 用 2.3pt 勾 + 实心短横、新建歌单 22×22 用 2pt 方框 + 实心加号
// → 一排看过去大小不一、粗细不一。
// 现在全部：**同一个 24×24 画布 / 同一条 1.5pt 描边 / 墨迹统一 20×20 / 圆头圆角**。
// 🔴 全部自绘：不依赖任何 SF Symbol（项目红线：不存在的符号名会静默渲染空白）。

// MARK: 排序按钮

/// 浅灰圆角方块（截图里按钮自身的底色，按规范「小按钮圆角 8px」）+ 左↓右↑ 双箭头。
struct ImmersiveSortIcon: View {
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 228 / 255, green: 228 / 255, blue: 233 / 255))
                .frame(width: 30, height: 30)
            SortDualArrowShape()
                .stroke(color, style: AppIconSpec.stroke(for: AppIconSpec.canvas))
                .frame(width: AppIconSpec.canvas, height: AppIconSpec.canvas)
        }
        .frame(width: 36, height: 36)
    }
}

/// 24×24 画布、墨迹 2..22：两支**细线箭头**，箭头头是 V 形（不是实心三角）。
private struct SortDualArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / AppIconSpec.canvas
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var p = Path()
        // 左 ↓：竖杆 + 人字形 V 头
        p.move(to: P(7, 2)); p.addLine(to: P(7, 22))
        p.move(to: P(2, 17)); p.addLine(to: P(7, 22)); p.addLine(to: P(12, 17))
        // 右 ↑：竖杆 + 人字形 ^ 头
        p.move(to: P(17, 22)); p.addLine(to: P(17, 2))
        p.move(to: P(12, 7)); p.addLine(to: P(17, 2)); p.addLine(to: P(22, 7))
        return p
    }
}

// MARK: 多选按钮

/// 两个勾 + 三条短横（「部分勾选的列表」）。勾和横都用同一条 1.5pt 描边，
/// 不再出现「勾是描边、横是实心矩形」的粗细差。
struct ImmersiveMultiSelectIcon: View {
    let color: Color

    var body: some View {
        ZStack {
            MultiSelectCheckShape().stroke(color, style: AppIconSpec.stroke(for: AppIconSpec.canvas))
            MultiSelectBarShape().stroke(color, style: AppIconSpec.stroke(for: AppIconSpec.canvas))
        }
        .frame(width: AppIconSpec.canvas, height: AppIconSpec.canvas)
    }
}

/// 三条短横（y = 4 / 12 / 20，x = 12..22），全部走描边。
private struct MultiSelectBarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / AppIconSpec.canvas
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var p = Path()
        for y in [CGFloat(4), 12, 20] {
            p.move(to: P(12, y)); p.addLine(to: P(22, y))
        }
        return p
    }
}

/// 两个勾，24×24 画布里落在 x 2..9、y 3..20.5。
private struct MultiSelectCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / AppIconSpec.canvas
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var p = Path()
        p.move(to: P(2, 6)); p.addLine(to: P(4.5, 8.5)); p.addLine(to: P(9, 3))
        p.move(to: P(2, 18)); p.addLine(to: P(4.5, 20.5)); p.addLine(to: P(9, 15))
        return p
    }
}

// MARK: 新建歌单按钮

/// 20×20 圆角方框 + 居中的加号，全部 1.5pt 描边。
struct ImmersiveNewPlaylistIcon: View {
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .inset(by: 2)
                .stroke(color, style: AppIconSpec.stroke(for: AppIconSpec.canvas))
            NewPlaylistPlusShape()
                .stroke(color, style: AppIconSpec.stroke(for: AppIconSpec.canvas))
        }
        .frame(width: AppIconSpec.canvas, height: AppIconSpec.canvas)
    }
}

private struct NewPlaylistPlusShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / AppIconSpec.canvas
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var p = Path()
        p.move(to: P(7.5, 12)); p.addLine(to: P(16.5, 12))
        p.move(to: P(12, 7.5)); p.addLine(to: P(12, 16.5))
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

/// 把字母条挂到与大图同一层的 UIKit 浮层上。
///
/// 🔴 2026-11-12 真机截图量化：沉浸式大图是 UIKit 浮层（UINavigationController.view
///    下、navigationBar 之下），覆盖屏幕 0~350pt，层级【高于整个 SwiftUI 树】。
///    旧版字母条是页面内 `.overlay`，行高 14.6pt、顶边约 275pt → A~F 六行正好
///    落进大图区被盖住，所以截图里只从 G 开始。
/// 🔴 只调 SwiftUI 的 zIndex / 可用高度都无解：27 个字母 × 加大后的行高必然
///    超过「大图底边 ~ 迷你播放条上沿」这段可用区（约 390pt），压下去就得把
///    行高缩得比原来还小。正解是让字母条与大图【同层且 z 序更高】。
///    这里用 0 尺寸 UIViewRepresentable 锚点，把 UIHostingController 的 view
///    加到同一个 nav.view 上（仅低于 navigationBar），随页面出现/消失自动装卸。
struct PlaylistLetterIndexOverlay: View {
    let letters: [String]
    let onSelect: (String) -> Void

    var body: some View {
        PlaylistLetterIndexHost(letters: letters, onSelect: onSelect)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }
}

/// 稳定的回调持有者：滚动时父视图 body 会反复重算，但 rootView 不必跟着重建。
final class PlaylistLetterIndexAction {
    var handler: ((String) -> Void)?
}

private struct PlaylistLetterIndexHost: UIViewRepresentable {
    let letters: [String]
    let onSelect: (String) -> Void

    func makeUIView(context: Context) -> Anchor {
        let v = Anchor()
        v.letters = letters
        v.action.handler = onSelect
        return v
    }

    func updateUIView(_ uiView: Anchor, context: Context) {
        let changed = uiView.letters != letters
        uiView.letters = letters
        uiView.action.handler = onSelect
        uiView.installIfNeeded()
        if changed { uiView.rebuildRoot() }
        uiView.refresh()
    }

    static func dismantleUIView(_ uiView: Anchor, coordinator: Void) {
        uiView.teardown()
    }

    final class Anchor: UIView {
        var letters: [String] = []
        var rowHeight: CGFloat = 17
        let action = PlaylistLetterIndexAction()

        private var hosting: UIHostingController<AnyView>?
        private var barView: UIView?
        private weak var container: UIView?
        private weak var navBar: UINavigationBar?
        private weak var hostVC: UIViewController?
        private var retry = 0
        private var monitoring = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { teardown(); return }
            installIfNeeded()
            refresh()
            startMonitoring()
        }

        private func resolveNavContext() -> (UINavigationBar, UIViewController)? {
            var node: UIResponder? = self
            while let cur = node {
                if let vc = cur as? UIViewController, let nav = vc.navigationController {
                    return (nav.navigationBar, vc)
                }
                node = cur.next
            }
            return nil
        }

        /// 浮层挂在 nav.view 上、整条栈共用 → push 到普通页时必须隐藏。
        private var isHostOnTop: Bool {
            guard let host = hostVC, let nav = host.navigationController else { return true }
            guard nav.viewControllers.contains(where: { $0 === host }) else { return true }
            return nav.topViewController === host
        }

        private func root() -> AnyView {
            let letters = self.letters
            let row = self.rowHeight
            let action = self.action
            return AnyView(
                PlaylistLetterIndexBar(letters: letters, rowHeight: row) { action.handler?($0) }
            )
        }

        func rebuildRoot() { hosting?.rootView = root() }

        private func installIfNeeded() {
            guard barView == nil else { return }
            // 首帧响应链可能还没连上导航控制器，重试几次；绝不 fallback 到 rootView。
            guard let (bar, pageHost) = resolveNavContext(), let parent = bar.superview else {
                if retry < 8 {
                    retry += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.installIfNeeded()
                    }
                }
                return
            }
            let host = UIHostingController(rootView: root())
            let v = host.view!
            v.backgroundColor = .clear
            v.clipsToBounds = true
            hosting = host
            barView = v
            container = parent
            navBar = bar
            hostVC = pageHost
            parent.addSubview(v)
            parent.bringSubviewToFront(bar)
            refresh()
        }

        func refresh() {
            guard let v = barView, let parent = container, let win = window else { return }
            let screen = UIScreen.main.bounds
            // 底边贴住迷你播放条上沿（实测约 718pt），再往上才不会被播放条压住。
            let bottomReserved: CGFloat = 126
            let topReserved: CGFloat = 92       // 状态栏 + 导航栏
            let maxH = screen.height - bottomReserved - topReserved
            // 小屏（SE 等）放不下 27×17pt 时按可用高度收敛行高，保证 A–Z 一个不裁。
            let row = min(PlaylistLetterIndexBar.defaultRowHeight,
                          maxH / max(1, CGFloat(letters.count)))
            if abs(row - rowHeight) > 0.01 {
                rowHeight = row
                rebuildRoot()
            }
            let h = min(CGFloat(letters.count) * row + 8, maxH)
            let w: CGFloat = 22
            let rect = CGRect(x: screen.width - w - 1,
                              y: screen.height - bottomReserved - h,
                              width: w, height: h)
            v.frame = parent.convert(rect, from: win)
            // 🔴 每次都重申 z 序：大图浮层偶发重建时会重新 insert 到 bar 之下，
            //    不重申就会重新把字母条盖住。
            parent.bringSubviewToFront(v)
            if let bar = navBar, bar.superview === parent { parent.bringSubviewToFront(bar) }
            v.isHidden = letters.isEmpty
                || !isHostOnTop
                || PlaylistSortOverlayState.shared.isPresented
        }

        /// 低频轮询（0.2s）：push/pop、弹窗开关后及时恢复 / 隐藏。
        private func startMonitoring() {
            guard !monitoring else { return }
            monitoring = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.window != nil else { return }
                self.refresh()
                self.monitoring = false
                self.startMonitoring()
            }
        }

        func teardown() {
            barView?.removeFromSuperview()
            barView = nil
            hosting = nil
            container = nil
            navBar = nil
        }
    }
}

struct PlaylistLetterIndexBar: View {
    let letters: [String]
    /// 🔴 2026-11-12：从原来的 14pt 加到 17pt（截图实测 14.6pt），
    ///    27 个字母在一条里明显更疏朗，不再挤成一坨；小屏由外层按可用高度收敛。
    static let defaultRowHeight: CGFloat = 17
    var rowHeight: CGFloat = 17
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Button {
                    onSelect(letter)
                    Haptics.light()
                } label: {
                    Text(letter)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.30, green: 0.32, blue: 0.36))
                        .frame(width: 18, height: rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(height: rowHeight)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .background(Capsule().fill(Color.white.opacity(0.78)))
        .overlay(Capsule().stroke(Color.black.opacity(0.05), lineWidth: 0.5))
    }
}
