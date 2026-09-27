import SwiftUI

struct LyricsView: View {
    let lyrics: [LyricLine]
    let currentIndex: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if lyrics.isEmpty {
                        Text("纯音乐 · 暂无歌词")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    } else {
                        ForEach(lyrics) { line in
                            Text(line.text)
                                .font(.system(size: line.id == activeId ? 15 : 12,
                                              weight: line.id == activeId ? .semibold : .regular))
                                .foregroundStyle(line.id == activeId ? .white : .white.opacity(0.55))
                                .multilineTextAlignment(.center)
                                .lineSpacing(2)
                                .frame(maxWidth: .infinity)
                                .id(line.id)
                        }
                    }
                }
                .padding(.vertical, 60)
            }
            .mask(LinearGradient(colors: [.clear, .black.opacity(0.85), .black, .black.opacity(0.85), .clear],
                                startPoint: .top,
                                endPoint: .bottom))
            .onChange(of: currentIndex) { _ in
                guard let id = activeId else { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: lyrics) { _ in proxy.scrollTo(0, anchor: .center) }
        }
    }

    private var activeId: UUID? {
        guard let index = currentIndex, lyrics.indices.contains(index) else { return nil }
        return lyrics[index].id
    }
}
