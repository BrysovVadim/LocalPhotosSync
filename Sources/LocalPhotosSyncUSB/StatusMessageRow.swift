import SwiftUI

enum StatusTone {
    case neutral, success, warning

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .success: .green
        case .warning: .orange
        }
    }
}

enum StatusText {
    static let inlineLineLimit = 3

    /// Keeps short messages intact; longer reports show their first lines and how many are hidden.
    static func summary(of text: String) -> (headline: String, isTruncated: Bool) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > inlineLineLimit else { return (lines.joined(separator: "\n"), false) }
        return (lines.prefix(inlineLineLimit - 1).joined(separator: "\n") + "\n…ещё строк: \(lines.count - inlineLineLimit + 1)", true)
    }
}

/// One line of status in an action bar. Long multi-line reports show their first line
/// and open in full, selectable, from a "Подробнее" popover.
struct StatusMessageRow: View {
    let symbol: String
    let text: String
    let tone: StatusTone
    @State private var showsDetails = false

    init(symbol: String, text: String, tone: StatusTone = .neutral) {
        self.symbol = symbol
        self.text = text
        self.tone = tone
    }

    var body: some View {
        let summary = StatusText.summary(of: text)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
            Text(summary.headline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if summary.isTruncated {
                Button("Подробнее") { showsDetails = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $showsDetails, arrowEdge: .top) {
                        ScrollView {
                            Text(text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        }
                        .frame(width: 460, height: 260)
                    }
            }
        }
        .font(.caption)
        .foregroundStyle(tone.color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
