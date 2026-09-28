import SwiftUI

/// 运行日志页。看得到、能筛选、能导出成文件发出来分析。
struct DiagnosticsView: View {
    @StateObject private var logs = LogStore.shared
    @State private var levelFilter: Log.Level = .debug
    @State private var searchText = ""
    @State private var isSharePresented = false
    @State private var reportURL: URL?
    @State private var didCopy = false

    private var filtered: [Log.Entry] {
        logs.entries.filter { entry in
            guard entry.level >= levelFilter else { return false }
            guard !searchText.isEmpty else { return true }
            let needle = searchText.lowercased()
            return entry.message.lowercased().contains(needle)
                || entry.category.lowercased().contains(needle)
        }
    }

    private var counts: [Log.Level: Int] {
        var result: [Log.Level: Int] = [:]
        for entry in logs.entries { result[entry.level, default: 0] += 1 }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            if filtered.isEmpty {
                EmptyStateView(icon: "doc.text.magnifyingglass",
                               title: "没有匹配的日志",
                               message: "切换一下级别或清空搜索词")
            } else {
                logList
            }
        }
        .background(AppStyle.background)
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        export()
                    } label: {
                        Label("导出日志文件", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = logs.entries
                            .map { "\($0.timeText) [\($0.level.rawValue)] [\($0.category)] \($0.message)" }
                            .joined(separator: "\n")
                        didCopy = true
                    } label: {
                        Label("复制到剪贴板", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        logs.clear()
                    } label: {
                        Label("清空日志", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isSharePresented) {
            if let reportURL { ShareSheet(items: [reportURL]) }
        }
        .onAppear { logs.reloadFromDisk() }
        .overlay(alignment: .bottom) {
            if didCopy {
                Text("已复制到剪贴板")
                    .font(.system(size: 12))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AppStyle.surfaceHigh, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Log.Level.allCases, id: \.self) { level in
                    let count = counts[level] ?? 0
                    let active = level == levelFilter
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { levelFilter = level }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: level.symbol).font(.system(size: 10))
                            Text("\(count)").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(active ? .black : AppStyle.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(active ? levelColor(level) : AppStyle.surfaceHigh,
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.tertiaryText)
                TextField("搜索日志内容", text: $searchText)
                    .font(.system(size: 12))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppStyle.surfaceHigh, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Text("共 \(logs.entries.count) 条，显示 \(filtered.count) 条")
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
                Spacer()
                Text("点右上角 ··· 导出")
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var logList: some View {
        List(filtered.reversed()) { entry in
            HStack(alignment: .top, spacing: 8) {
                Text(entry.timeText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .frame(width: 74, alignment: .leading)
                Text(entry.level.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(levelColor(entry.level))
                    .frame(width: 42, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.category)
                        .font(.system(size: 10))
                        .foregroundStyle(AppStyle.tertiaryText)
                    Text(entry.message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppStyle.primaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 3)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func levelColor(_ level: Log.Level) -> Color {
        switch level {
        case .debug: return AppStyle.tertiaryText
        case .info: return AppStyle.accent
        case .warn: return AppStyle.gold
        case .error: return AppStyle.like
        }
    }

    private func export() {
        guard let url = logs.exportReport() else { return }
        reportURL = url
        isSharePresented = true
    }
}
