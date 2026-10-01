import AppKit
import SwiftUI

/// Thumbnail area shared by catalog cards and USB import tiles: fills its width, shows a placeholder until an
/// image arrives, and overlays the selection marker and a video badge.
struct MediaThumbnail: View {
    let image: NSImage?
    let isVideo: Bool
    let placeholderText: String?
    let height: CGFloat
    let selected: Bool
    let selectable: Bool

    init(image: NSImage?, isVideo: Bool, placeholderText: String? = nil, height: CGFloat,
         selected: Bool, selectable: Bool = true) {
        self.image = image
        self.isVideo = isVideo
        self.placeholderText = placeholderText
        self.height = height
        self.selected = selected
        self.selectable = selectable
    }

    var body: some View {
        Color.secondary.opacity(0.1)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: isVideo ? "video" : "photo").font(.title)
                        if let placeholderText { Text(placeholderText).font(.caption) }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                } else if selectable {
                    Image(systemName: "circle")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .background(Circle().fill(Color.black.opacity(0.18)))
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isVideo {
                    Image(systemName: "video.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(6)
                }
            }
    }
}

/// Card padding, selected background, outline and a light hover highlight shared by both grids.
private struct MediaTileChrome: ViewModifier {
    let selected: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(7)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(hovering ? 0.35 : 0.15),
                        lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovering = $0 }
    }

    private var background: Color {
        if selected { return Color.accentColor.opacity(0.12) }
        return hovering ? Color.secondary.opacity(0.06) : Color.clear
    }
}

extension View {
    func mediaTileChrome(selected: Bool) -> some View {
        modifier(MediaTileChrome(selected: selected))
    }
}
