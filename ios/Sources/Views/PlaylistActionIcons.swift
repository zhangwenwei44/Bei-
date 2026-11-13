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
    /// 🔴 2026-11-14：右侧快速定位条【所有 7 种排序方式常驻】。
    ///    A–Z 排序 = 字母索引条；其余 5 种 = 真正的滑动条。
    static func isActive(_ mode: PlaylistSortMode) -> Bool { return true }

    /// 只有这两种排序用 A–Z 字母刻度。
    static func isAZ(_ mode: PlaylistSortMode) -> Bool {
        mode == .titleAZ || mode == .artistAZ
    }

    /// 🔴 2026-11-14 定稿：用户明确「我要的是滑动条不是数字」。
    ///    非 A–Z 排序右侧是一根细轨道 + 可拖动的蓝色滑块，
    ///    没有任何数字 / 字母 / 放大气泡；滑块直接驱动 UIScrollView.contentOffset。
    static func isSlider(_ mode: PlaylistSortMode) -> Bool { !isAZ(mode) }

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
        guard isAZ(mode) else {
            // 🔴 2026-11-14：滑动条模式【不生成任何刻度 / 锚点】。
            //    滑动条是纯 UIKit 视图，按 contentOffset 比例直接定位列表，
            //    不需要字母条那套分组锚点，也不往 LazyVStack 里插 0 高度 Color.clear。
            //    letters 非空只是让外层 `if !letters.isEmpty` 判定「该显示浮层」。
            guard songs.count >= 2 else {
                return (letters: [String](), anchors: [String: String]())
            }
            return (letters: ["__slider__"], anchors: [String: String]())
        }
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

    /// 🔴 每一行对应的刻度标签（与排序结果同序），仅 A–Z 字母条使用。
    ///    滑动条模式直接读 UIScrollView.contentOffset，不需要逐行标签 → 返回空数组，
    ///    大歌单（574 首）也就不必在每次排序缓存时分配一整份字符串数组。
    static func rowLabels(_ songs: [Song], mode: PlaylistSortMode,
                          letters: [String]) -> [String] {
        guard isAZ(mode) else { return [String]() }
        return songs.map { letter(for: key($0, mode: mode)) }
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

    /// 🔴 2026-11-13：蓝圆高亮对象由 Mode 持有，容器滚动回调与字母条共用同一个，
    ///    这样「滚动到哪首歌 → 蓝圆跳到那个字母」不需要经过页面 @State。
    let active = PlaylistLetterIndexActive()

    /// 由页面在 A–Z 排序时注入：字母表 + 每一行对应的首字母（与 displaySongs 对齐）。
    var letters: [String] = []
    var rowLetters: [String] = []
    /// SongRow 固定行高（Components.swift 里 .frame(height: 64)）。
    var rowHeight: CGFloat = 64

    func configure(letters: [String], rowLetters: [String]) {
        self.letters = letters
        self.rowLetters = rowLetters
        if active.index >= letters.count {
            active.index = max(0, letters.count - 1)
        }
    }

    /// 🔴 修「移动歌曲蓝色圆不会根据当前歌曲名跳转」。
    ///    contentY = 吸顶头下沿在「滚动内容坐标系」里的 y，listStart = 列表第一行的内容 y。
    ///    两者都由容器实测值算出，不依赖 GeometryReader 的全球坐标换算。
    ///    只在字母跨组时写 active.index —— 只有 UIKit hosting 的字母条订阅它，
    ///    不会触发整页 / 几百行列表重算。
    func syncVisible(contentY: CGFloat, listStart: CGFloat) {
        guard expanded, !rowLetters.isEmpty, !letters.isEmpty,
              !active.isHoldingSelection else { return }
        let offset = max(0, contentY - listStart)
        let raw = Int((offset / max(1, rowHeight)).rounded(.down))
        let idx = max(0, min(rowLetters.count - 1, raw))
        let letter = rowLetters[idx]
        guard let target = letters.firstIndex(of: letter), active.index != target else { return }
        active.index = target
    }
}

/// 🔴 2026-11-13：当前高亮字母的持久状态。
///    字母条在展开/收起切换时会 `rebuildRoot()` 换掉 hosting 的 rootView，
///    若用 `@State` 存活动下标，重建后会被重置回 0（蓝圆跳回 A）。
///    把状态放在 Anchor（UIView，生命周期跨重建）持有的对象里即可保留。
final class PlaylistLetterIndexActive: ObservableObject {
    @Published var index: Int = 0

    /// 用户刚按住/点过字母后短暂锁定高亮，避免 scrollTo 的滚动回调立刻把蓝圆
    /// 改写成邻近字母（点 A 却跳到 # 那种跳变）。普通属性，不触发视图刷新。
    private var holdUntil: Date = .distantPast
    func holdSelection(seconds: TimeInterval = 1.2) {
        holdUntil = Date().addingTimeInterval(seconds)
    }
    var isHoldingSelection: Bool { Date() < holdUntil }
}

// MARK: - 🔴 2026-11-14 定稿：非 A–Z 排序的「真滑动条」（纯 UIKit）

/// 用户明确「我要的是滑动条不是数字」：右侧 = 一根细轨道 + 蓝色圆角滑块，
///   · 滑块高度按「可视区 / 内容高度」比例（最短 32pt），位置按 contentOffset 实时跟随；
///   · 按住 / 上下拖动直接改 UIScrollView.contentOffset，等价于拖着整份歌单快速定位；
///   · 没有数字、没有字母、没有白色 Capsule 底板、没有放大气泡。
/// 🔴 全程只改 UIView.frame：不写 @Published、不重建 SwiftUI 树 —— 574 首大歌单
///    滚动时不会触发整页 body 重算（项目「大歌单掉帧」红线）。
final class PlaylistScrollSliderView: UIView {

    private let track = UIView()
    private let thumb = UIView()

    private weak var scrollView: UIScrollView?
    private weak var searchRoot: UIView?
    private var offsetObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var dragging = false
    /// 已绑定到「真正可滚动的长列表」：此后不再遍历视图树。
    private var locked = false

    private let trackWidth: CGFloat = 3
    private let thumbWidth: CGFloat = 9
    private let minThumbHeight: CGFloat = 32
    private let edgeY: CGFloat = 6

    private static let blue = UIColor(red: 0.12, green: 0.53, blue: 0.96, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        isMultipleTouchEnabled = false

        track.backgroundColor = PlaylistScrollSliderView.blue.withAlphaComponent(0.16)
        track.layer.cornerRadius = trackWidth / 2
        track.isUserInteractionEnabled = false
        addSubview(track)

        thumb.backgroundColor = PlaylistScrollSliderView.blue
        thumb.layer.cornerRadius = thumbWidth / 2
        thumb.isUserInteractionEnabled = false
        thumb.layer.shadowColor = PlaylistScrollSliderView.blue.withAlphaComponent(0.45).cgColor
        thumb.layer.shadowRadius = 3
        thumb.layer.shadowOpacity = 0.5
        thumb.layer.shadowOffset = .zero
        addSubview(thumb)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let usable = max(0, bounds.height - edgeY * 2)
        track.frame = CGRect(x: (bounds.width - trackWidth) / 2,
                             y: edgeY, width: trackWidth, height: usable)
        syncThumb()
    }

    /// 从宿主页面视图树里找「真正承载歌曲列表」的 UIScrollView（contentSize 最高那个）。
    /// 首帧 SwiftUI 的 ScrollView 可能还没装好 → 由 Anchor 的轮询反复调用，找到即锁住。
    func attachIfNeeded(from root: UIView?) {
        if let r = root { searchRoot = r }
        // 🔴 已经锁定「真正可滚动的长列表」后直接同步，不再每 0.15s 遍历整棵视图树
        //    （大歌单视图树很大，重复 walk 会掉帧 —— 项目「大歌单性能」红线）。
        if locked {
            syncThumb()
            return
        }
        guard let r = searchRoot ?? root else { return }
        var best: UIScrollView?
        func walk(_ v: UIView) {
            if let sv = v as? UIScrollView {
                if let cur = best {
                    if sv.contentSize.height > cur.contentSize.height { best = sv }
                } else {
                    best = sv
                }
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(r)
        guard let sv = best else { return }
        // 🔴 只认「内容明显高于可视区」的竖向列表，绝不误绑到横滑卡片 /
        //    导航栈里别的页面的小 ScrollView（window 级兜底会带来这个风险）。
        let isLongList = sv.contentSize.height > sv.bounds.height + 40
        if let old = scrollView, old !== sv, old.contentSize.height >= sv.contentSize.height {
            syncThumb()
            return
        }
        if scrollView !== sv {
            offsetObservation?.invalidate()
            sizeObservation?.invalidate()
            scrollView = sv
            offsetObservation = sv.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
                self?.syncThumb()
            }
            sizeObservation = sv.observe(\.contentSize, options: [.initial, .new]) { [weak self] _, _ in
                self?.syncThumb()
            }
        }
        if isLongList { locked = true }
        syncThumb()
    }

    private func metrics() -> (minY: CGFloat, maxY: CGFloat, progress: CGFloat,
                               thumbHeight: CGFloat, usable: CGFloat) {
        let usable = max(1, bounds.height - edgeY * 2)
        guard let sv = scrollView else {
            return (0, 1, 0, min(usable, minThumbHeight), usable)
        }
        let ins = sv.adjustedContentInset
        let minY = -ins.top
        let maxY = max(minY, sv.contentSize.height + ins.bottom - sv.bounds.height)
        let span = max(1, maxY - minY)
        let progress = min(1, max(0, (sv.contentOffset.y - minY) / span))
        let ratio: CGFloat = sv.contentSize.height > 0
            ? min(1, sv.bounds.height / sv.contentSize.height) : 1
        let thumbHeight = min(usable, max(min(usable, minThumbHeight), usable * ratio))
        return (minY, maxY, progress, thumbHeight, usable)
    }

    private func setThumb(y: CGFloat, height: CGFloat) {
        thumb.frame = CGRect(x: (bounds.width - thumbWidth) / 2,
                             y: y, width: thumbWidth, height: height)
    }

    /// 🔴 只让靠近轨道的窄条接收触摸，两侧边缘事件穿透回歌曲行，
    ///    否则这根 24pt 宽、几百 pt 高的浮层会挡住列表行尾的三点菜单 / 收藏按钮。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        return abs(point.x - bounds.width / 2) <= 9
    }

    /// 滚动位置 → 滑块位置。拖动中不跑，避免和手指抢位置。
    private func syncThumb() {
        guard !dragging else { return }
        let m = metrics()
        let travel = max(1, m.usable - m.thumbHeight)
        setThumb(y: edgeY + travel * m.progress, height: m.thumbHeight)
    }

    /// 手指位置 → 列表位置。
    private func seek(toY: CGFloat) {
        guard let sv = scrollView else { return }
        let m = metrics()
        let travel = max(1, m.usable - m.thumbHeight)
        let p = min(1, max(0, (toY - edgeY - m.thumbHeight / 2) / travel))
        setThumb(y: edgeY + travel * p, height: m.thumbHeight)
        let targetY = m.minY + p * (m.maxY - m.minY)
        if abs(sv.contentOffset.y - targetY) > 0.5 {
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: targetY), animated: false)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        dragging = true
        thumb.backgroundColor = PlaylistScrollSliderView.blue.withAlphaComponent(0.82)
        Haptics.light()
        seek(toY: t.location(in: self).y)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        seek(toY: t.location(in: self).y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish() }

    private func finish() {
        dragging = false
        thumb.backgroundColor = PlaylistScrollSliderView.blue
        syncThumb()
    }

    func detach() {
        offsetObservation?.invalidate()
        sizeObservation?.invalidate()
        offsetObservation = nil
        sizeObservation = nil
        scrollView = nil
    }
}

/// 把字母条 / 滑动条挂到与大图同一层的 UIKit 浮层上。
///
/// 🔴 2026-11-12 真机截图量化：沉浸式大图是 UIKit 浮层（UINavigationController.view
///    下、navigationBar 之下），覆盖屏幕 0~350pt，层级【高于整个 SwiftUI 树】。
///    页面内 `.overlay` 会被大图盖住 A~F，所以字母条必须与大图【同层且 z 序更高】。
/// 🔴 双态：`expanded = false`（大图展开）行高 14pt 紧凑；吸顶后 21pt 展开。
struct PlaylistLetterIndexOverlay: View {
    let letters: [String]
    /// 与字母表一一对应的「每一行首字母」，供蓝圆随滚动自动跳转。
    var rowLetters: [String] = []
    /// 🔴 2026-11-14：true = 安装纯 UIKit 滑动条；false = A–Z 字母索引条。
    var isSlider: Bool = false
    @ObservedObject var mode: PlaylistLetterIndexMode
    let onSelect: (String) -> Void

    var body: some View {
        PlaylistLetterIndexHost(letters: letters, mode: mode,
                                isSlider: isSlider, onSelect: onSelect)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            // 数据注入只写普通属性，不发布 → 不会让页面 body 重算。
            .onAppear { mode.configure(letters: letters, rowLetters: rowLetters) }
            .onChange(of: rowLetters) { newValue in
                mode.configure(letters: letters, rowLetters: newValue)
            }
            .onChange(of: letters) { newValue in
                mode.configure(letters: newValue, rowLetters: rowLetters)
            }
    }
}

private struct PlaylistLetterIndexHost: UIViewRepresentable {
    let letters: [String]
    @ObservedObject var mode: PlaylistLetterIndexMode
    var isSlider: Bool = false
    let onSelect: (String) -> Void

    func makeUIView(context: Context) -> Anchor {
        let v = Anchor()
        v.letters = letters
        v.expanded = mode.expanded
        v.active = mode.active
        v.isSlider = isSlider
        v.onSelect = onSelect
        return v
    }

    func updateUIView(_ uiView: Anchor, context: Context) {
        // 🔴 A–Z ↔ 其它排序切换：浮层形态不同，必须先拆旧视图再装新的。
        if uiView.isSlider != isSlider {
            uiView.switchMode(to: isSlider)
        }
        let changed = uiView.letters != letters
        let modeChanged = uiView.expanded != mode.expanded
        uiView.letters = letters
        uiView.expanded = mode.expanded
        uiView.active = mode.active
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
        /// 🔴 2026-11-14：true = 纯 UIKit 滑动条；false = A–Z 字母索引条。
        var isSlider: Bool = false
        /// 跨 rootView 重建保留的高亮下标（由 Mode 持有，滚动回调也能改）。
        var active = PlaylistLetterIndexActive()

        private var hosting: UIHostingController<AnyView>?
        private var sliderView: PlaylistScrollSliderView?
        private var barView: UIView?
        private weak var container: UIView?
        private weak var navBar: UINavigationBar?
        private weak var hostVC: UIViewController?
        /// 🔴 同大图浮层：hostVC 是 weak，pop 后会变 nil，必须另记 nav。
        private weak var navController: UINavigationController?
        private var retry = 0
        private var monitoring = false
        /// 缩起态下可用高度太小（小屏）→ 整条隐藏，避免字母挤成一团。
        private var compactClipped = false

        private var shouldHide: Bool {
            letters.isEmpty || !isHostOnTop
                || PlaylistSortOverlayState.shared.isPresented || compactClipped
        }

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
            guard let nav = navController else { return true }
            if let host = hostVC, nav.viewControllers.contains(where: { $0 === host }),
               nav.topViewController === host { return true }
            // 🔴 2026-11-14：本页已被 pop 时字母条必须立刻隐藏（与大图浮层同一套判断）。
            guard let topView = nav.topViewController?.view else { return true }
            return isDescendant(of: topView)
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

        func rebuildRoot() {
            guard !isSlider else { return }
            hosting?.rootView = root()
        }

        /// A–Z ↔ 其它排序：浮层是两种完全不同的视图，拆掉重装（含 KVO）。
        func switchMode(to slider: Bool) {
            isSlider = slider
            barView?.removeFromSuperview()
            barView = nil
            hosting = nil
            sliderView?.detach()
            sliderView = nil
            retry = 0
            installIfNeeded()
            refresh()
        }

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
            let v: UIView
            if isSlider {
                let slider = PlaylistScrollSliderView()
                sliderView = slider
                v = slider
            } else {
                let host = UIHostingController(rootView: root())
                let hv = host.view!
                hv.backgroundColor = .clear
                hv.clipsToBounds = true
                hosting = host
                v = hv
            }
            v.backgroundColor = .clear
            v.clipsToBounds = true
            barView = v
            container = parent
            navBar = bar
            hostVC = pageHost
            navController = pageHost.navigationController
            parent.addSubview(v)
            parent.bringSubviewToFront(bar)
            // 滑动条要拿到承载歌曲列表的 UIScrollView；首帧可能还没建好，轮询里会重试。
            sliderView?.attachIfNeeded(from: pageHost.view)
            refresh()
        }

        func refresh() {
            guard let v = barView, let parent = container, let win = window else { return }
            let screen = UIScreen.main.bounds
            let bottomReserved: CGFloat = 126
            // 🔴 2026-11-13：修「刚打开歌单、英文排序缩起时字母显示在图片上」。
            //    缩起态（大图展开）把字母条整条压进【大图 350 + 吸顶头 74 + 8】
            //    以下的列表区域，绝不再浮到沉浸式大图上；吸顶后恢复原 92pt 上限。
            let topReserved: CGFloat = expanded ? 92 : 432
            let maxH = screen.height - bottomReserved - topReserved
            // 字母条在缩起态挤不下会糊成一团才隐藏；滑动条是滚动指示器，
            // 只要还留得下一根轨道就必须常显（小屏大图展开时也别整条消失）。
            compactClipped = !expanded && maxH < (isSlider ? 60 : 180)
            if compactClipped {
                if !v.isHidden { v.isHidden = true }
                return
            }
            let h: CGFloat
            let w: CGFloat
            if isSlider {
                // 🔴 滑动条 = 一整根轨道占满列表可视区，宽度给足手指命中区（28pt），
                //    轨道本身只有 3pt 居中绘制。不再按「刻度行数」算高度。
                h = maxH
                w = 24
            } else {
                let count = max(1, CGFloat(letters.count))
                // 紧凑态回到早期 14pt；吸顶后展开到 21pt（上下更疏）；小屏按可用高度收敛。
                let targetRow = expanded ? 21 : 14
                let row = min(CGFloat(targetRow), maxH / count)
                if abs(row - rowHeight) > 0.01 {
                    rowHeight = row
                    rebuildRoot()
                }
                h = min(count * row + 8, maxH)
                w = 24
            }
            let rect = CGRect(x: screen.width - w - 1,
                              y: screen.height - bottomReserved - h,
                              width: w, height: h)
            let newFrame = parent.convert(rect, from: win)
            if v.frame != newFrame { v.frame = newFrame }
            // 层级只在这里校正（安装 / 数据变化 / 展开态切换），滚动中不碰。
            ensureZOrder()
            // 列表 UIScrollView 可能比浮层晚建好，这里顺手补一次绑定。
            sliderView?.attachIfNeeded(from: hostVC?.view)
            let hidden = shouldHide
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

        /// 低频轮询：只在 push/pop、弹窗开关导致可见性变化时才动 UI。
        private func startMonitoring() {
            guard !monitoring else { return }
            monitoring = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let anchor = self, anchor.window != nil else {
                    self?.monitoring = false
                    return
                }
                let target = anchor
                target.ensureZOrder()
                // 滑动条首次可能还没找到列表 UIScrollView（LazyVStack 异步装载），补绑。
                target.sliderView?.attachIfNeeded(from: target.hostVC?.view)
                let hidden = target.shouldHide
                if let v = target.barView, v.isHidden != hidden {
                    v.isHidden = hidden
                }
                target.monitoring = false
                target.startMonitoring()
            }
        }

        func teardown() {
            sliderView?.detach()
            sliderView = nil
            barView?.removeFromSuperview()
            barView = nil
            hosting = nil
            container = nil
            navBar = nil
            monitoring = false
            retry = 0
        }
    }
}

/// 🔴 A–Z 排序专用字母索引条（非 A–Z 排序现在用 `PlaylistScrollSliderView` 真滑动条）。
///    2026-11-12 第三轮：去掉整条白色 Capsule 背景 + 描边，字母直接浮在列表上；
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
                    active.holdSelection()
                    active.index = idx
                    onSelect(letters[idx])
                    Haptics.light()
                }
        )
    }
}
