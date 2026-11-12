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

    /// 🔴 2026-11-12 第三轮：吸顶行「新建歌单 / 排序 / 多选」三枚再改小一档。
    ///    线宽仍固定 1.5pt（约束文件硬要求），只缩墨迹画布；命中区 36 → 30。
    static let actionCanvas: CGFloat = 20
    static let actionHit: CGFloat = 30
    /// 固定线宽，不随画布缩小而变细（保持一排图标粗细统一）。
    static func actionStroke() -> StrokeStyle {
        StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
    }

    /// 🔴 2026-11-12：吸顶行三枚图标不再是近黑 `AppStyle.primaryText`，
    ///    改成酷狗同款「灰白」中性色。白底吸顶行上仍能看清，但不会有硬黑感。
    static let actionTint = Color(red: 0.63, green: 0.66, blue: 0.71)

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

/// 左↓右↑ 双箭头。🔴 2026-11-12：用户要求移除那个浅灰方形背景框，
///    现在与「新建歌单 / 多选」完全一样：24×24 画布、1.5pt 描边、36×36 命中区。
struct ImmersiveSortIcon: View {
    let color: Color

    var body: some View {
        SortDualArrowShape()
            .stroke(color, style: AppIconSpec.actionStroke())
            .frame(width: AppIconSpec.actionCanvas, height: AppIconSpec.actionCanvas)
            .frame(width: AppIconSpec.actionHit, height: AppIconSpec.actionHit)
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
            MultiSelectCheckShape().stroke(color, style: AppIconSpec.actionStroke())
            MultiSelectBarShape().stroke(color, style: AppIconSpec.actionStroke())
        }
        .frame(width: AppIconSpec.actionCanvas, height: AppIconSpec.actionCanvas)
        .frame(width: AppIconSpec.actionHit, height: AppIconSpec.actionHit)
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
                .stroke(color, style: AppIconSpec.actionStroke())
            NewPlaylistPlusShape()
                .stroke(color, style: AppIconSpec.actionStroke())
        }
        .frame(width: AppIconSpec.actionCanvas, height: AppIconSpec.actionCanvas)
        .frame(width: AppIconSpec.actionHit, height: AppIconSpec.actionHit)
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
                    .frame(width: AppIconSpec.actionHit, height: AppIconSpec.actionHit)
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

    /// scrollTo 的锚点 id。用 .top 会被吸顶行盖住，这里把目标放在可见区约 12% 处。
    /// 🔴 调用处**不包 withAnimation** —— 手指拖过字母时连续触发 scrollTo，
    ///    叠加动画会让列表来回抖（用户反馈的「滑动抖动」之一）。
    static let scrollAnchor = UnitPoint(x: 0.5, y: 0.12)

    static func anchorID(_ letter: String) -> String { "sort-sec-\(letter)" }
}

/// 🔴 2026-11-12 第三轮：字母条的展开态独立成一个只发布 Bool 的对象。
///    原来 overlay 直接订阅 `ImmersiveHeaderState`，而 `scrolled` 是滚动时逐帧
///    @Published，导致字母条 SwiftUI 视图每帧重算、updateUIView 每帧被调用 ——
///    大歌单上滑时这就是持续掉帧 / 抖动的来源之一。
///    现在 `apply()` 只在跨过阈值那一次写 `expanded`，滚动全程零刷新。
final class PlaylistLetterIndexMode: ObservableObject {
    @Published var expanded: Bool = false
}

/// 🔴 2026-11-13：当前高亮字母的持久状态。
///    字母条在展开/收起切换时会 `rebuildRoot()` 换掉 hosting 的 rootView，
///    若用 `@State` 存活动下标，重建后会被重置回 0（蓝圆跳回 A）。
///    把状态放在 Anchor（UIView，生命周期跨重建）持有的对象里即可保留。
final class PlaylistLetterIndexActive: ObservableObject {
    @Published var index: Int = 0
}

/// 把字母条挂到与大图同一层的 UIKit 浮层上。
///
/// 🔴 2026-11-12 真机截图量化：沉浸式大图是 UIKit 浮层（UINavigationController.view
///    下、navigationBar 之下），覆盖屏幕 0~350pt，层级【高于整个 SwiftUI 树】。
///    页面内 `.overlay` 会被大图盖住 A~F，所以字母条必须与大图【同层且 z 序更高】。
/// 🔴 双态：`expanded = false`（大图展开）行高 14pt 紧凑；吸顶后 21pt 展开。
struct PlaylistLetterIndexOverlay: View {
    let letters: [String]
    @ObservedObject var mode: PlaylistLetterIndexMode
    let onSelect: (String) -> Void

    var body: some View {
        PlaylistLetterIndexHost(letters: letters, expanded: mode.expanded, onSelect: onSelect)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }
}

private struct PlaylistLetterIndexHost: UIViewRepresentable {
    let letters: [String]
    let expanded: Bool
    let onSelect: (String) -> Void

    func makeUIView(context: Context) -> Anchor {
        let v = Anchor()
        v.letters = letters
        v.expanded = expanded
        v.onSelect = onSelect
        return v
    }

    func updateUIView(_ uiView: Anchor, context: Context) {
        let changed = uiView.letters != letters
        let modeChanged = uiView.expanded != expanded
        uiView.letters = letters
        uiView.expanded = expanded
        uiView.onSelect = onSelect
        // 字母数量变了（换排序 / 切歌单）时把高亮收敛到合法范围。
        if changed, uiView.active.index >= letters.count {
            uiView.active.index = max(0, letters.count - 1)
        }
        uiView.installIfNeeded()
        // 🔴 只在「数据 / 展开态」真的变化时才重建 + 重排图层。
        //    旧版每 0.2s 无条件 bringSubviewToFront，滚动时反复触发 UIKit
        //    layoutSubviews，是大歌单滑动抖动的直接来源之一。
        if changed || modeChanged {
            uiView.rebuildRoot()
            uiView.refresh()
        }
    }

    static func dismantleUIView(_ uiView: Anchor, coordinator: Void) {
        uiView.teardown()
    }

    final class Anchor: UIView {
        var letters: [String] = []
        var expanded: Bool = false
        var rowHeight: CGFloat = 14
        var onSelect: ((String) -> Void)?
        /// 跨 rootView 重建保留的高亮下标。
        let active = PlaylistLetterIndexActive()

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
            // 🔴 首帧大图浮层可能还没插入，0.15s 后补一次层级校正。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.ensureZOrder()
            }
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
            let expanded = self.expanded
            return AnyView(
                PlaylistLetterIndexBar(letters: letters,
                                       rowHeight: row,
                                       expanded: expanded,
                                       active: active) { [weak self] letter in
                    self?.onSelect?(letter)
                }
            )
        }

        func rebuildRoot() { hosting?.rootView = root() }

        /// 🔴 不能标 private：`UIViewRepresentable.updateUIView`（外层作用域）也要调它。
        func installIfNeeded() {
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
            let bottomReserved: CGFloat = 126
            let topReserved: CGFloat = 92
            let maxH = screen.height - bottomReserved - topReserved
            let count = max(1, CGFloat(letters.count))
            // 紧凑态回到早期 14pt；吸顶后展开到 21pt（上下更疏）；小屏按可用高度收敛。
            let targetRow = expanded ? 21 : 14
            let row = min(CGFloat(targetRow), maxH / count)
            if abs(row - rowHeight) > 0.01 {
                rowHeight = row
                rebuildRoot()
            }
            let h = min(count * row + 8, maxH)
            let w: CGFloat = 24
            let rect = CGRect(x: screen.width - w - 1,
                              y: screen.height - bottomReserved - h,
                              width: w, height: h)
            let newFrame = parent.convert(rect, from: win)
            if v.frame != newFrame { v.frame = newFrame }
            // 层级只在这里校正（安装 / 数据变化 / 展开态切换），滚动中不碰。
            ensureZOrder()
            let hidden = letters.isEmpty
                || !isHostOnTop
                || PlaylistSortOverlayState.shared.isPresented
            if v.isHidden != hidden { v.isHidden = hidden }
        }

        /// 🔴 字母条必须保持在 navigationBar 之下的**最上层**：沉浸式大图也是
        ///    insertSubview(belowSubview: navigationBar) 挂在同一层，而且可能比
        ///    字母条更晚安装（封面异步到达），一旦大图后插入就会重新盖住 A~F。
        ///    这里只在位置真的不对时才动 UIKit 层级，正常情况零操作。
        private func ensureZOrder() {
            guard let v = barView, let parent = container, let bar = navBar,
                  bar.superview === parent,
                  let barIdx = parent.subviews.firstIndex(where: { $0 === bar }),
                  barIdx > 0 else { return }
            if parent.subviews[barIdx - 1] === v { return }
            parent.insertSubview(v, belowSubview: bar)
        }

        /// 低频轮询（0.45s）：只在 push/pop、弹窗开关导致可见性变化时才动 UI。
        private func startMonitoring() {
            guard !monitoring else { return }
            monitoring = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.window != nil else { return }
                self.ensureZOrder()
                let hidden = self.letters.isEmpty
                    || !self.isHostOnTop
                    || PlaylistSortOverlayState.shared.isPresented
                if let v = self.barView, v.isHidden != hidden {
                    v.isHidden = hidden
                }
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

/// 🔴 2026-11-12 第三轮：按用户要求移除右侧「滑动条」外观 ——
///    去掉整条白色 Capsule 背景 + 描边，字母直接浮在列表上；
///    滑到哪个字母，那个字母出现【蓝色圆形背景 + 白字】高亮（iOS 通讯录同款）。
///    原来的左侧 68pt 放大气泡一并删除，避免两套提示同时出现。
/// 🔴 2026-11-13：用户要求「蓝色圆背景常显，不是按住英文字母才显示」——
///    活动字母改成非可选的持久状态（默认首个字母），松手后**保留**高亮，
///    下次按住/拖动才切换到新字母。字母条一出现就有蓝圆，全程不消失。
struct PlaylistLetterIndexBar: View {
    let letters: [String]
    var rowHeight: CGFloat
    let expanded: Bool
    /// 🔴 由 Anchor 持有，跨 rootView 重建不丢失当前高亮字母。
    @ObservedObject var active: PlaylistLetterIndexActive
    let onSelect: (String) -> Void

    private var safeIndex: Int {
        guard !letters.isEmpty else { return 0 }
        return max(0, min(letters.count - 1, active.index))
    }

    var body: some View {
        let current = safeIndex
        return VStack(spacing: 0) {
            ForEach(letters.indices, id: \.self) { i in
                let isActive = current == i
                Text(letters[i])
                    .font(.system(size: expanded ? 12 : 10,
                                  weight: isActive ? .bold : .semibold))
                    .foregroundStyle(isActive
                                     ? Color.white
                                     : Color(red: 0.32, green: 0.34, blue: 0.38))
                    .frame(width: 22, height: rowHeight)
                    .background {
                        if isActive {
                            // 🔴 常显：不依赖任何「按住中」的状态。
                            Circle()
                                .fill(Color(red: 0.12, green: 0.53, blue: 0.96))
                                .frame(width: min(20, rowHeight + 2),
                                       height: min(20, rowHeight + 2))
                        }
                    }
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // 🔴 统一用手势处理「点按 / 按住 / 上下拖动」：按下即定位 + 高亮，
        //    拖过字母连续定位；松手保留高亮（用户明确要求常显）。
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let raw = Int((value.location.y - 4) / max(1, rowHeight))
                    let idx = max(0, min(letters.count - 1, raw))
                    guard letters.indices.contains(idx), active.index != idx else { return }
                    active.index = idx
                    onSelect(letters[idx])
                    Haptics.light()
                }
        )
    }
}
