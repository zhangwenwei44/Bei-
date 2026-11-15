import SwiftUI

// MARK: - 下载页顶栏图标：直接取自工作区 lucide-icons 矢量仓库的 SVG path
//
// 备份 = icons/file-plus-corner.svg（Lucide 别名 file-plus-2）+ file-text 的文档横线；
// 恢复 = icons/folder-up.svg。下面每一条 move/addLine/addCurve 都由 SVG 的
// d 属性（含 A 圆弧 → 三次贝塞尔）离线转换生成，24×24 坐标系原样保留，
// 运行时按 rect 缩放，是真正的矢量，不是 SF Symbol 拼图。

/// 文档 + 右下角加号（备份）
struct LucideBackupIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var p = Path()
        p.move(to: CGPoint(x: 11.35, y: 22))
        p.addLine(to: CGPoint(x: 6, y: 22))
        p.addCurve(to: CGPoint(x: 4, y: 20), control1: CGPoint(x: 4.895, y: 22), control2: CGPoint(x: 4, y: 21.105))
        p.addLine(to: CGPoint(x: 4, y: 4))
        p.addCurve(to: CGPoint(x: 6, y: 2), control1: CGPoint(x: 4, y: 2.895), control2: CGPoint(x: 4.895, y: 2))
        p.addLine(to: CGPoint(x: 14, y: 2))
        p.addCurve(to: CGPoint(x: 15.706, y: 2.706), control1: CGPoint(x: 14.64, y: 1.998), control2: CGPoint(x: 15.254, y: 2.253))
        p.addLine(to: CGPoint(x: 19.294, y: 6.294))
        p.addCurve(to: CGPoint(x: 20, y: 8), control1: CGPoint(x: 19.747, y: 6.746), control2: CGPoint(x: 20.002, y: 7.36))
        p.addLine(to: CGPoint(x: 20, y: 13.35))
        p.move(to: CGPoint(x: 14, y: 2))
        p.addLine(to: CGPoint(x: 14, y: 7))
        p.addCurve(to: CGPoint(x: 15, y: 8), control1: CGPoint(x: 14, y: 7.552), control2: CGPoint(x: 14.448, y: 8))
        p.addLine(to: CGPoint(x: 20, y: 8))
        p.move(to: CGPoint(x: 14, y: 19))
        p.addLine(to: CGPoint(x: 20, y: 19))
        p.move(to: CGPoint(x: 17, y: 16))
        p.addLine(to: CGPoint(x: 17, y: 22))
        p.move(to: CGPoint(x: 8, y: 12))
        p.addLine(to: CGPoint(x: 13, y: 12))
        p.move(to: CGPoint(x: 8, y: 16))
        p.addLine(to: CGPoint(x: 12, y: 16))
        return p.applying(CGAffineTransform(scaleX: s, y: s))
    }
}

/// 文件夹 + 向上箭头（从备份恢复）
struct LucideRestoreIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var p = Path()
        p.move(to: CGPoint(x: 20, y: 20))
        p.addCurve(to: CGPoint(x: 22, y: 18), control1: CGPoint(x: 21.105, y: 20), control2: CGPoint(x: 22, y: 19.105))
        p.addLine(to: CGPoint(x: 22, y: 8))
        p.addCurve(to: CGPoint(x: 20, y: 6), control1: CGPoint(x: 22, y: 6.895), control2: CGPoint(x: 21.105, y: 6))
        p.addLine(to: CGPoint(x: 12.1, y: 6))
        p.addCurve(to: CGPoint(x: 10.41, y: 5.1), control1: CGPoint(x: 11.42, y: 6.007), control2: CGPoint(x: 10.784, y: 5.668))
        p.addLine(to: CGPoint(x: 9.6, y: 3.9))
        p.addCurve(to: CGPoint(x: 7.93, y: 3), control1: CGPoint(x: 9.23, y: 3.338), control2: CGPoint(x: 8.603, y: 3))
        p.addLine(to: CGPoint(x: 4, y: 3))
        p.addCurve(to: CGPoint(x: 2, y: 5), control1: CGPoint(x: 2.895, y: 3), control2: CGPoint(x: 2, y: 3.895))
        p.addLine(to: CGPoint(x: 2, y: 18))
        p.addCurve(to: CGPoint(x: 4, y: 20), control1: CGPoint(x: 2, y: 19.105), control2: CGPoint(x: 2.895, y: 20))
        p.closeSubpath()
        p.move(to: CGPoint(x: 12, y: 10))
        p.addLine(to: CGPoint(x: 12, y: 16))
        p.move(to: CGPoint(x: 9, y: 13))
        p.addLine(to: CGPoint(x: 12, y: 10))
        p.addLine(to: CGPoint(x: 15, y: 13))
        return p.applying(CGAffineTransform(scaleX: s, y: s))
    }
}

// MARK: - 顶栏按钮外观（沿用旧 struct 名，调用方无需改）

private let lucideStroke = StrokeStyle(lineWidth: 2.15, lineCap: .round, lineJoin: .round)

struct BackupDocumentPlusIcon: View {
    var body: some View {
        LucideBackupIcon()
            .stroke(AppStyle.accent, style: lucideStroke)
            .frame(width: 25, height: 25)
            .contentShape(Rectangle())
    }
}

struct ExportFolderArrowIcon: View {
    var body: some View {
        LucideRestoreIcon()
            .stroke(AppStyle.accent, style: lucideStroke)
            .frame(width: 25, height: 25)
            .contentShape(Rectangle())
    }
}
