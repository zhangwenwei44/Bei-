import SwiftUI

private struct QueueSheetModifier: ViewModifier {
    @EnvironmentObject private var store: PlayerStore

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $store.isQueuePresented) {
                if #available(iOS 16.0, *) {
                    QueueView()
                        .environmentObject(store)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                } else {
                    QueueView()
                        .environmentObject(store)
                }
            }
    }
}

extension View {
    func queueSheet() -> some View { modifier(QueueSheetModifier()) }
}
