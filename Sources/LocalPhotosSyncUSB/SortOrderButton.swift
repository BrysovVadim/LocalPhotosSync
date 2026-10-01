import SwiftUI

enum DisplayOrder {
    /// Sources list newest first; oldest-first is the exact reverse, so month runs stay contiguous.
    static func apply<Item>(_ items: [Item], oldestFirst: Bool) -> [Item] {
        oldestFirst ? Array(items.reversed()) : items
    }
}

/// Toggles between newest-first and oldest-first order.
struct SortOrderButton: View {
    @Binding var oldestFirst: Bool

    init(oldestFirst: Binding<Bool>) {
        _oldestFirst = oldestFirst
    }

    var body: some View {
        Button {
            oldestFirst.toggle()
        } label: {
            Label(oldestFirst ? "Сначала старые" : "Сначала новые",
                  systemImage: oldestFirst ? "arrow.up" : "arrow.down")
                .labelStyle(.iconOnly)
        }
        .help(oldestFirst ? "Сначала старые. Нажмите, чтобы показывать сначала новые." :
                            "Сначала новые. Нажмите, чтобы показывать сначала старые.")
        .accessibilityLabel(oldestFirst ? "Порядок: сначала старые" : "Порядок: сначала новые")
    }
}
