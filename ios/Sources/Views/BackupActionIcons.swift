import SwiftUI

// MARK: - 下载页顶栏「备份 / 从备份恢复」图标（🔴 2026-11-16 按用户给的两张图 1:1 组合）
//
// 不直接用 `doc.badge.plus` / `folder.badge.arrow.up`：这两个 SF Symbol 是 iOS 16+
// 才有的，App 还要兼容 iOS 15，缺符号时 `Image(systemName:)` 会静默渲染空白。
// 用 iOS 15 就有的基础符号叠加，形状与用户截图一致，且任何系统版本都不空白。

/// 「备份」——带折角与横线的文档 + 右下角加号（用户图 3「存档加」）。
struct BackupDocumentPlusIcon: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "doc.text")
                .font(.system(size: 20, weight: .medium))
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .heavy))
                .offset(x: 5, y: 3)
        }
        .foregroundStyle(AppStyle.accent)
        .frame(width: 27, height: 26)
    }
}

/// 「从备份恢复」——文件夹里一个向上箭头（用户图 4「导出备份」）。
struct ExportFolderArrowIcon: View {
    var body: some View {
        ZStack {
            Image(systemName: "folder")
                .font(.system(size: 21, weight: .medium))
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .heavy))
                .offset(y: 1)
        }
        .foregroundStyle(AppStyle.accent)
        .frame(width: 27, height: 26)
    }
}
