import SwiftUI

/// 更新日志：内置历次改动 + 抓取 GitHub 最新 Release 的说明。
struct ChangelogView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var updater = AppUpdater.shared
    @State private var remoteNotes: [String] = []
    @State private var remoteVersion: String?
    @State private var isLoadingRemote = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    latestSection
                    ForEach(Changelog.entries, id: \.version) { entry in
                        entrySection(entry)
                    }
                }
                .padding(20)
            }
            .background(AppStyle.background)
            .navigationTitle("更新日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await loadRemote() }
        }
    }

    // MARK: 最新版本

    @ViewBuilder
    private var latestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("最新版本")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppStyle.primaryText)
                if let remoteVersion {
                    TagChip(text: remoteVersion, isSelected: true)
                }
            }

            if isLoadingRemote {
                HStack(spacing: 8) {
                    ProgressView().tint(AppStyle.accent)
                    Text("正在读取 Release…")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.secondaryText)
                }
            } else if remoteNotes.isEmpty {
                Text("没有读到线上说明，可能是网络或限流。下面是内置记录。")
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.tertiaryText)
            } else {
                ForEach(Array(remoteNotes.enumerated()), id: \.offset) { _, line in
                    bullet(line)
                }
            }
        }
    }

    private func entrySection(_ entry: Changelog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(entry.version)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppStyle.accent)
                if entry.date.isEmpty {
                    EmptyView()
                } else {
                    Text(entry.date)
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                if entry.version == updater.versionText {
                    Text("当前")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(AppStyle.accent, in: Capsule())
                }
            }
            ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                bullet(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(AppStyle.accent.opacity(0.7))
                .frame(width: 4, height: 4)
                .padding(.top, 7)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(AppStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadRemote() async {
        isLoadingRemote = true
        defer { isLoadingRemote = false }
        await updater.check(force: true)
        if case let .available(release) = updater.phase {
            remoteVersion = release.tag_name
            remoteNotes = AppUpdater.notes(from: release.body, limit: 12)
        } else if case let .upToDate(current) = updater.phase {
            remoteVersion = current
        }
    }
}

/// 内置更新日志。新版本加在最前面。
enum Changelog {
    struct Entry {
        var version: String
        var date: String
        var items: [String]
    }

    static let entries: [Entry] = [
        Entry(version: "1.4.3", date: "", items: [
            "修复运行日志导出后显示 0 条：日志本身一直有写入，是读取时的解析器把每一行都判为无效",
            "原因是用右方括号加空格来切分行，级别后面的右方括号被当成分隔符吃掉，导致找不到配对的括号",
            "日志改用 | 分隔；解析结果为空时不再清空内存里的条目",
            "导出报告末尾附原始日志文件内容，解析器再出问题也不会丢证据",
        ]),
        Entry(version: "1.4.2", date: "", items: [
            "修复榜单/歌单空白：解析器从开括号之后开始找下一个 [，跳过了 5714 个字符切出垃圾，导致永远返回空数组",
            "歌单加载失败不再伪装成「歌单里还没有歌曲」，改为显示真实原因",
            "修复自建歌单加不进歌：没有歌单时「添加到歌单」整个入口被隐藏",
            "歌单里的歌曲 ID 解析不出来时自动从历史/收藏/本地补回",
            "榜单封面字段修正为 img_9，曲目数回退到 songinfo 计数",
            "新增运行日志：我的 → 运行日志，可按级别筛选、搜索、导出成文件发出来分析",
            "日志覆盖网络请求、音源导入、脚本执行、解析解析等所有原先静默失败的点",
            "音源与曲库落盘失败不再静默丢弃（之前 try? 会让音源只留在内存里，重启就没）",
        ]),
        Entry(version: "1.4.1", date: "", items: [
            "修复榜单歌单空白：榜单取歌接口已失效，改为解析榜单页的 JS 数组（URL 用 rankid 而非 id）",
            "修复播放页歌手名显示成 <em>周杰伦</em>：搜索结果里的高亮标签现在会剥干净，专辑名同样处理",
            "播放页控制键改为居中并整体上提，移除控制行右下的队列按钮（队列入口仍在图标行）",
            "修复更新包下载后不弹安装：主路径改为系统分享面板选 AppSync / Zebra / Filza，直唤降为辅助",
            "修复本地音乐导入：放开可选文件类型，补加载态与失败原因提示",
        ]),
        Entry(version: "1.4.0", date: "", items: [
            "音源改为内置：洛雪脚本随包发布，音源页一键添加，不用再选文件",
            "内置墨澜聚合音源 v2.3.3（MIT，作者白姬9527），随仓库分发",
            "没有 license 声明的音源（如长青 SVIP）走本地槽位：你的包里有，仓库里没有",
            "新增「从剪贴板导入」，作为文件选择器的兜底",
            "关于页列出内置音源的署名与许可",
        ]),
        Entry(version: "1.3.0", date: "", items: [
            "只保留酷狗接口并设为默认：搜索 / 排行榜 / 歌词直连，封面用酷狗专辑图",
            "第三方音源支持洛雪（lx-music）脚本：补齐 EVENT_NAMES、console、require",
            "修复 lx.request 回调签名：洛雪约定是 (err, resp)，之前只传一个参数，脚本会直接 reject",
            "修复音源文件导入「选完没反应」：结果改用页内横幅，并放开文件类型限制",
            "粘贴导入也支持整段 JS 脚本，名称从 /*! @name */ 里读取",
        ]),
        Entry(version: "1.2.0", date: "", items: [
            "新增 App 图标",
            "第三方音源支持从文件导入，修掉选完文件没反应的问题",
            "适配洛雪（lx-music）音源脚本：补齐 lx.utils 全套（md5 / AES 加解密 / base64 / hex / 时间格式化 / 随机数等）",
            "歌曲封面补拉：搜索和列表里缺图的歌会自动去接口取回，不再一片兜底渐变",
            "检查更新下载完成后会把安装包落到公共下载目录，唤起 AppSync 弹安装确认；失败可用分享面板手动打开",
            "新增更新日志页面（内置记录 + 线上 Release 说明）",
        ]),
        Entry(version: "1.1.0", date: "", items: [
            "我的音乐重新设计：顶部数据磁贴 + 最近播放横滑带 + 分组标题行",
            "第三方音源新增从文件导入（JSON / JS / txt）",
            "新增应用内检查更新，下载 IPA 后可直接唤起安装",
            "封面回退：歌单 / 歌手 / 专辑缺图时用关联歌曲的专辑图顶上",
            "本地导入抽内嵌封面，没有就按歌名生成",
            "播放页音质徽标移到歌手后面，播放模式按钮移到图标行",
        ]),
        Entry(version: "1.0.0", date: "", items: [
            "首个可用版本：在线播放、搜索、下载、收藏、歌单",
            "第三方音源解析（接口模板 + JS 脚本）",
            "酷狗风格播放页：封面取色渐变背景、歌词逐行高亮",
        ]),
    ]
}
