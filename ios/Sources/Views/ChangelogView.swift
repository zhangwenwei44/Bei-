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
                        .foregroundStyle(AppStyle.onAccent)
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
        Entry(version: "1.9.2", date: "", items: [
            "锁屏控制：上一首/下一首回归（±15 秒快进退与切歌键位互斥，已禁用 ±15）",
            "播放页布局改为确定性尺寸：封面固定为「屏宽-88 与 42% 屏高取小」，任何机型歌名/标签/按钮/进度条都完整",
        ]),
        Entry(version: "1.9.1", date: "", items: [
            "修复播放页分辨率/布局适配：任何机型下歌名、歌手、按钮、进度条都完整显示，封面自动让位不再顶满屏幕",
        ]),
        Entry(version: "1.9.0", date: "", items: [
            "修复「播放几秒就自动停」：缓冲卡顿不再被误判为播放失败，不再拉黑域名、不再把音源打熔断；音源熔断改为 60 秒自动解封",
            "播放页重新排版（酷狗式）：大专辑封面卡片 + 封面取色渐变背景，歌名/歌手/进度/按钮各归其位，窄屏小机不再错乱",
            "歌手写真方案下线，按反馈改为封面大图展示",
            "歌词不再显示 [ar:] [hash:] 等元数据标签行",
            "发现页新增「猜你喜欢」（可换一批）和「热门歌手」板块",
            "搜索页新增热门搜索标签，历史记录改为标签流",
            "底部「发现」「设置」图标重新设计",
            "检查更新：进页面自动弹窗提示新版本，下载完成后自动弹出安装器选择（越狱安装）",
        ]),
        Entry(version: "1.8.0", date: "", items: [
            "修复歌单里歌曲封面仍不显示：根因是设备上 ATS 强制拦截所有 http 请求，专辑接口所在的 mobilecdn 域名不支持 https，已整体迁到支持 https 的 mobiles 域名",
            "修复「解析成功却播放失败」：音源返回的 http 播放地址会自动探测并升级为 https 再交给播放器",
            "歌词接口同步迁到 https，修复歌词加载不出来",
            "歌手写真优先用正式歌手头像，不再拿 MV 抽帧的怼脸截图当背景",
            "音源导入精简为「从文件导入」，并新增「从网址导入」（填直链自动下载识别）",
            "底部「我的」改名「设置」；迷你播放条不再盖住设置页的运行日志等最后几行",
            "窄屏设备播放页操作栏改为可横向滑动，六个按钮不再被裁掉",
        ]),
        Entry(version: "1.7.0", date: "", items: [
            "修复歌曲封面还是不显示：榜单详情页现在会按专辑 id 并发把整页封面主动拉齐，边拉边刷；所有封面请求失败后自动换 https 重试",
            "修复歌手写真不显示：小众歌手的写真字段藏在返回数据的 extra 里，之前只读了顶层字段所以拿不到；歌手名搜不到时再用歌名搜一次兜底",
            "修复「从文件导入」点开选择器后没反应：文件选择器改为直接挂在窗口根控制器上弹出（不再嵌在 sheet 里被 iOS 16 吞掉），选中的文件自动拷进 App 再读取，不再报无权限",
            "播放页新增全屏歌词页：点歌词区或「歌词」按钮进入大字滚动歌词，页内可直接开关翻译，下滑或点箭头返回",
            "播放页移除「铃声」按钮",
        ]),
        Entry(version: "1.6.0", date: "", items: [
            "修复榜单歌曲全部不显示专辑封面：酷狗榜单页的曲目数据里压根没有图片字段，只有专辑 id，现在会按专辑自动补齐封面，榜单、播放页、锁屏都用得上",
            "发现页改版成酷狗风格：榜单改为三列大封面宫格，直接看图找榜",
            "迷你播放条不再让音源名挤占歌名：音源名挪到歌手一行显示，太长时自动截尾，歌名永远完整",
            "播放页背景改为当前歌手的写真大图，清晰不模糊；拿不到写真时自动退回原来的封面取色背景",
        ]),
        Entry(version: "1.5.9", date: "", items: [
            "修复内置音源一直解析失败：脚本回传结果时把回调对象当函数调用，JavaScriptCore 抛出的异常在 Promise 里被静默吞掉，每次解析都拖到超时。现在脚本音源能真正拿到播放地址",
            "安装包不再内置音源：墨澜 / 星海 / 独家会在启动时自动清理。装好新版后到「我的 → 第三方音源」用「从文件导入」或「从剪贴板导入」加入长青SVIP脚本即可（手动导入的音源不受影响，会原样保留）",
            "修复下载完安装包后点「选择软件安装」没反应：下载完成关掉页面再重开时，包路径状态丢失，按钮静默失败。现在进入页面会补齐状态，按钮不再失效",
            "下载完安装包现在会自动弹出分享面板，选 AppSync / Zebra / Filza 直接安装，不用再手动点按钮",
            "脚本执行排队改为队列：之前同一时刻只有一个请求能被处理，第二个脚本请求会被静默丢弃",
            "运行日志改为独立队列即时落盘，闪退 / 卡死前的日志不再丢失",
        ]),
        Entry(version: "1.5.8", date: "", items: [
            "修复第三方音源脚本网络请求的方法名被设成字符串 \"undefined\"：JSValue.toString() 对 undefined 返回 \"undefined\" 而不是 nil，?? \"GET\" 兜底永远不触发，导致 nginx 返回 400 Bad Request，「长青SVIP音源」等脚本类音源一直解析失败",
            "为酷狗 /v5/url 接口加进程内熔断：该接口自 v1.3.0 起就一直返回 85 字节错误体，每次切歌都白白试 3 个 quality 再失败、再交给第三方音源，用户多等 1 秒。连续失败 3 次后本次运行期直接跳过，第三方音源兜住解析",
            "修复音乐接口失败日志的字段读取：实际字段是 errcode/errmsg，代码读的是 error/msg，导致 reason 永远落到 fallback 的「响应里没有地址字段」，看不出真正错在哪。现在直接打印 errcode 和 errmsg",
            "脚本音源的 HTTP method 现在 uppercase（HTTP method 大小写敏感）",
        ]),
        Entry(version: "1.5.6", date: "", items: [
            "修复榜单曲目数全部显示成 3 首：之前误把接口里的推荐位数量当成了曲目数",
            "曲目数改为从榜单页的真实总数读取，取不到时不再显示错误数字",
            "封面加载全程写入日志，之前失败时完全没有记录",
            "补齐音源开关状态、脚本请求与超时的日志，播放失败可定位到具体环节",
            "脚本调用超时从 12 秒缩短到 8 秒，失败时更快给出反馈",
        ]),
        Entry(version: "1.5.5", date: "", items: [
            "修复播放器准备播放时的并发变量捕获问题（Swift 6 语言模式下会直接报错）",
            "修复日志列表每次刷新都被当成全新内容重建",
            "摘要算法改为内置实现，构建不再产生弃用警告；CI 会用标准测试向量校验其正确性",
            "清理全部编译警告，之后构建出现警告会直接中止",
        ]),
        Entry(version: "1.5.4", date: "", items: [
            "修复播放闪退：传给脚本的歌曲信息里有 4 个键被重复写入，运行时直接崩溃",
            "构建流程现在会在出现编译警告时中止，避免警告被无声忽略",
        ]),
        Entry(version: "1.5.3", date: "", items: [
            "修复播放闪退：同一个脚本上下文此前被两个线程同时访问。脚本的加载、求值、调用现在全部在同一条线程上执行",
            "崩溃日志里的调用栈之前在部分环境抓不到，现在改用可靠的方式记录",
        ]),
        Entry(version: "1.5.2", date: "", items: [
            "修复播放闪退：脚本改用 16MB 专用线程执行。系统线程池只有 512KB 栈，聚合音源做签名解密时递归过深会撞栈",
            "调用解析接口时若出现异常，立刻作废该脚本运行时并从缓存剔除，不再复用状态不确定的上下文",
            "崩溃日志现在会记录原生调用栈，如果还有闪退可以直接看出崩在哪个库",
        ]),
        Entry(version: "1.5.1", date: "", items: [
            "修复播放闪退：脚本日志函数之前被注册成对象，脚本按函数调用时抛异常，JavaScriptCore 随即崩溃",
            "脚本求值期间一旦出现异常就丢弃该运行时，不再继续使用状态不确定的上下文",
            "修复更新安装不弹选择面板：改为在顶层界面直接呈现分享面板，绕开嵌套弹窗",
            "安装面板弹出失败时给出明确路径指引；文件 App 跳转的相对路径也算对了",
        ]),
        Entry(version: "1.5.0", date: "", items: [
            "界面全面重做：主色改为酷狗蓝，浅色模式下蓝白配色，深色模式同步适配",
            "新增外观设置，可跟随系统或手动选择浅色/深色",
            "修复播放闪退：脚本桥的函数参数全部改为可选，避免 JavaScriptCore 桥接 undefined 时抛异常",
            "修复播放闪退：音源改为串行解析，不再同时开多个脚本运行时，内存峰值大幅下降",
            "新增崩溃现场记录，之后再闪退可以直接从运行日志看到崩在哪",
            "脚本运行时常驻缓存从 8 降到 3，收到内存警告时自动释放",
            "音源连续失败 3 次会暂时跳过，不再每首歌都白等一次超时",
            "预先创建音源导入目录，文件 App 里可以直接看到并放入音源文件",
            "音乐接口失败时把服务端原因写进日志，不再只看到字节数",
        ]),
        Entry(version: "1.4.4", date: "", items: [
            "修复内置音源一个都装不上：资源写在 project.yml 顶层 resources 键里被静默忽略，打出来的安装包里没有任何脚本文件",
            "构建流程新增强制校验，安装包里缺少内置音源脚本时直接构建失败，不再悄悄发出坏包",
            "修复点从文件导入没反应：iOS 16 上同一页面挂多个 sheet 只有一个生效，已合并为单一入口",
            "文件导入改用系统文档选择器，并新增从 App 目录导入和从文件 App 分享过来两条路径",
            "音源列表为空时直说原因，并提供一键添加全部内置音源",
            "脚本文件兼容 UTF-8 BOM 与 UTF-16 编码，重复导入同名音源改为覆盖而非堆积",
            "修复 App 内更新点了没反应：我的页并列挂了三个弹窗入口，iOS 16 下只有最后一个生效，已合并为单一入口",
            "下载后校验文件头，避免 GitHub 限流时把一段错误页面当成安装包存下来",
            "触发限流时提示具体剩余时间并引导到发布页；更新全流程写入运行日志",
        ]),
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
