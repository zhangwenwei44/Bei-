import SwiftUI

struct LyricsView: View {
    let lyrics: [LyricLine]
    let currentIndex: Int?
    let title: String
    let artist: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    hero
                        .padding(.top, 90)
                        .padding(.bottom, 24)

                    if lyrics.isEmpty {
                        Text("纯音乐 · 暂无歌词")
                            .font(.system(size: 19))
                            .foregroundStyle(.white.opacity(0.55))
                    } else {
                        ForEach(lyrics) { line in
                            Text(line.text)
                                .font(.system(size: line.id == activeId ? 22 : 19, weight: line.id == activeId ? .bold : .regular))
                                .foregroundStyle(line.id == activeId ? .white : .white.opacity(0.55))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .id(line.id)
                        }
                    }
                }
                .padding(.bottom, 30)
            }
            .mask(LinearGradient(colors: [.clear, .black.opacity(0.9), .black, .clear],
                                startPoint: .top,
                                endPoint: .bottom)
                .frame(height: 420)
                .clipped())
            .onChange(of: currentIndex) { index in
                guard let id = activeId else { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var activeId: UUID? {
        guard let index = currentIndex, lyrics.indices.contains(index) else { return nil }
        return lyrics[index].id
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 40, weight: .heavy))
                .tracking(6)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(artist)
                .font(.system(size: 20, weight: .semibold))
                .tracking(3)
                .opacity(0.92)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
        .opacity(currentIndex == nil ? 1 : 0)
        .offset(y: currentIndex == nil ? 0 : -30)
        .animation(.easeInOut(duration: 0.4), value: currentIndex == nil)
    }
}
