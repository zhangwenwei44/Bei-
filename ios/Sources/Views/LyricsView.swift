import SwiftUI

struct LyricsView: View {
    let lyrics: [LyricLine]
    let currentIndex: Int?
    var showsTranslation = false

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
                            VStack(spacing: 3) {
                                Text(line.text)
                                    .font(.system(size: isActive(line) ? 15 : 12,
                                                  weight: isActive(line) ? .semibold : .regular))
                                    .foregroundStyle(isActive(line) ? .white : .white.opacity(0.55))
                                    .multilineTextAlignment(.center)
                                if showsTranslation, let translation = line.translation, !translation.isEmpty {
                                    Text(translation)
                                        .font(.system(size: isActive(line) ? 12 : 10))
                                        .foregroundStyle(isActive(line) ? .white.opacity(0.75) : .white.opacity(0.4))
                                        .multilineTextAlignment(.center)
                                }
                            }
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
            .onChange(of: lyrics) { _ in proxy.scrollTo(lyrics.first?.id, anchor: .center) }
        }
    }

    private func isActive(_ line: LyricLine) -> Bool {
        line.id == activeId
    }

    private var activeId: UUID? {
        guard let index = currentIndex, lyrics.indices.contains(index) else { return nil }
        return lyrics[index].id
    }
}
