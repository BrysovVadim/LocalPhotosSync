import AppKit
import SwiftUI

struct CatalogPreviewActions {
    var toggleSelection: (PhoneCatalogAsset) -> Void = { _ in }
    var loadPreview: (PhoneCatalogAsset) -> Void = { _ in }
    var check: (PhoneCatalogAsset) -> Void = { _ in }
    var save: (PhoneCatalogAsset) -> Void = { _ in }
    var close: () -> Void = {}
}

/// A larger look at one card of the current page, with the same actions as its context menu.
struct CatalogPreviewSheet: View {
    let assets: [PhoneCatalogAsset]
    @Binding var index: Int
    let image: (Int64) -> NSImage?
    let isSelected: (Int64) -> Bool
    let availability: (Int64) -> PhoneAssetAvailabilityCheck?
    let canLoadPreview: (PhoneCatalogAsset) -> Bool
    let isBusy: Bool
    let actions: CatalogPreviewActions

    init(assets: [PhoneCatalogAsset], index: Binding<Int>, image: @escaping (Int64) -> NSImage?,
         isSelected: @escaping (Int64) -> Bool, availability: @escaping (Int64) -> PhoneAssetAvailabilityCheck?,
         canLoadPreview: @escaping (PhoneCatalogAsset) -> Bool, isBusy: Bool, actions: CatalogPreviewActions) {
        self.assets = assets
        _index = index
        self.image = image
        self.isSelected = isSelected
        self.availability = availability
        self.canLoadPreview = canLoadPreview
        self.isBusy = isBusy
        self.actions = actions
    }

    private var current: PhoneCatalogAsset? {
        assets.indices.contains(index) ? assets[index] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let asset = current {
                imageArea(asset)
                Divider()
                details(asset)
                    .padding(16)
                Spacer(minLength: 0)
            } else {
                ContentUnavailableView("Карточка недоступна", systemImage: "photo")
                Button("Закрыть") { actions.close() }
                    .keyboardShortcut(.cancelAction)
                    .padding(16)
            }
        }
        .frame(width: 640, height: 600)
    }

    private func imageArea(_ asset: PhoneCatalogAsset) -> some View {
        ZStack {
            Color.black.opacity(0.85)
            if let image = image(asset.id) {
                Image(nsImage: image).resizable().scaledToFit().padding(8)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: asset.mediaType == .video ? "video" : "photo").font(.system(size: 44))
                    Text("Превью не загружено").font(.callout)
                    if canLoadPreview(asset) {
                        Button("Загрузить превью") { actions.loadPreview(asset) }
                            .disabled(isBusy)
                    }
                }
                .foregroundStyle(.white.opacity(0.75))
            }
            HStack {
                navigationButton("chevron.left", enabled: index > 0, shortcut: .leftArrow, help: "Предыдущая (←)") {
                    index -= 1
                }
                Spacer()
                navigationButton("chevron.right", enabled: index < assets.count - 1, shortcut: .rightArrow, help: "Следующая (→)") {
                    index += 1
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 420)
    }

    private func navigationButton(_ symbol: String, enabled: Bool, shortcut: KeyEquivalent, help: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: [])
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(help)
    }

    private func details(_ asset: PhoneCatalogAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(asset.filename.isEmpty ? "Имя файла не указано" : asset.filename)
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Text("\(index + 1) из \(assets.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(summary(asset)).font(.callout).foregroundStyle(.secondary)
            if let check = availability(asset.id) {
                Text(availabilityText(check)).font(.callout).foregroundStyle(availabilityColor(check))
            }
            HStack(spacing: 10) {
                Button(isSelected(asset.id) ? "Снять выбор" : "Выбрать") { actions.toggleSelection(asset) }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!asset.isTransferable || isBusy)
                Button("Проверить") { actions.check(asset) }
                    .disabled(!asset.isTransferable || isBusy)
                Button("Сохранить этот файл…") { actions.save(asset) }
                    .disabled(!asset.isTransferable || isBusy)
                Spacer()
                Button("Закрыть") { actions.close() }
                    .keyboardShortcut(.cancelAction)
            }
            Text("Пробел — выбрать, ← и → — соседние карточки страницы, Esc — закрыть. Превью не подтверждает наличие оригинала.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func summary(_ asset: PhoneCatalogAsset) -> String {
        let kind = switch asset.mediaType {
        case .photo: "Фото"
        case .video: "Видео"
        case .other: "Другой тип"
        }
        var parts = [kind, asset.createdAt?.formatted(date: .long, time: .shortened) ?? "Дата не указана"]
        if asset.isHidden { parts.append("скрыто") }
        if asset.visibilityState != 0 { parts.append("дополнительная запись") }
        if isSelected(asset.id) { parts.append("выбрано") }
        return parts.joined(separator: " · ")
    }

    private func availabilityText(_ check: PhoneAssetAvailabilityCheck) -> String {
        let when = check.checkedAt.formatted(date: .omitted, time: .shortened)
        switch check.state {
        case .mainFileReadable(let bytes):
            return "Есть на iPhone · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) · проверено в \(when)"
        case .mainFileMissing:
            return "Файл не найден при проверке в \(when). Можно открыть снимок на iPhone, дождаться загрузки и проверить снова."
        case .exceedsCopyLimit(let bytes):
            return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) — больше лимита переноса · проверено в \(when)"
        case .failed:
            return "Проверка в \(when) завершилась ошибкой; это не означает, что файла нет."
        }
    }

    private func availabilityColor(_ check: PhoneAssetAvailabilityCheck) -> Color {
        switch check.state {
        case .mainFileReadable: .green
        case .mainFileMissing: .secondary
        case .exceedsCopyLimit, .failed: .orange
        }
    }
}
