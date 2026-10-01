import AppKit
import SwiftUI

struct UsbImportItem: Identifiable, Equatable {
    let id: String
    let name: String
    let date: Date?
    let bytes: Int64
    let isVideo: Bool
}

struct UsbImportDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

enum UsbImportTypeFilter: String, CaseIterable, Identifiable {
    case all = "Все"
    case photos = "Фото и другие файлы"
    case videos = "Видео"

    var id: String { rawValue }
}

enum UsbImportFiltering {
    static func visible(_ items: [UsbImportItem], query: String, filter: UsbImportTypeFilter) -> [UsbImportItem] {
        items.filter { item in
            let typeMatches: Bool
            switch filter {
            case .all: typeMatches = true
            case .photos: typeMatches = !item.isVideo
            case .videos: typeMatches = item.isVideo
            }
            return typeMatches && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query))
        }
    }

    /// Shift-click: ids between `anchor` and `target` (inclusive) in display order, or nil if either is not shown.
    static func range(in items: [UsbImportItem], from anchor: String, to target: String) -> [String]? {
        guard let start = items.firstIndex(where: { $0.id == anchor }),
              let end = items.firstIndex(where: { $0.id == target }) else { return nil }
        return items[min(start, end)...max(start, end)].map(\.id)
    }

    static func selectedBytes(_ items: [UsbImportItem], selected: Set<String>) -> Int64 {
        items.reduce(0) { selected.contains($1.id) ? $0 + max(0, $1.bytes) : $0 }
    }
}

/// Everything the USB import screen shows, decoupled from ImageCaptureCore so it can be rendered from fixtures.
struct UsbImportScreenState {
    var devices: [UsbImportDevice] = []
    var connectedID = ""
    var connectionState = CameraConnectionState.waiting
    var status = ""
    var ready = false
    var importing = false
    var importProcessed = 0
    var importTotal = 0
    var importedCount = 0
    var items: [UsbImportItem] = []
    var selected: Set<String> = []
    var results = ""
    var lastImportSucceeded: Bool?
    var lastArchive: URL?
    var verifyingArchive = false
    var verificationResults = ""
    var lastVerificationPassed: Bool?
}

struct UsbImportActions {
    var connect: (String) -> Void = { _ in }
    var reconnect: () -> Void = {}
    var copyDiagnostics: () -> Void = {}
    var setSelection: (Set<String>) -> Void = { _ in }
    var importSelected: () -> Void = {}
    var cancelImport: () -> Void = {}
    var verifyArchive: () -> Void = {}
    var openArchive: (URL) -> Void = { _ in }
    var thumbnail: @MainActor (String) async -> NSImage? = { _ in nil }
}

struct UsbImportScreen: View {
    let state: UsbImportScreenState
    let actions: UsbImportActions
    @State private var query = ""
    @State private var filter = UsbImportTypeFilter.all
    @State private var anchor: String?
    @AppStorage("usb.tileSize") private var tileSize = PhoneCatalogTileSize.standard

    init(state: UsbImportScreenState, actions: UsbImportActions) {
        self.state = state
        self.actions = actions
    }

    var body: some View {
        let visible = UsbImportFiltering.visible(state.items, query: query, filter: filter)
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
            statusStrip
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            if !state.items.isEmpty {
                filterBar(visible: visible)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            content(visible: visible)
            Divider()
            actionBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Импорт по USB").font(.title.bold())
                Text("Файлы, которые iPhone отдаёт стандартному импорту macOS · без установки на телефон")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Picker("Устройство", selection: Binding(get: { state.connectedID }, set: { actions.connect($0) })) {
                Text("Выберите iPhone").tag("")
                ForEach(state.devices) { device in Text(device.name).tag(device.id) }
            }
            .labelsHidden()
            .frame(width: 220)
            .disabled(state.importing)
            Button {
                actions.reconnect()
            } label: {
                Label("Подключиться снова", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(state.connectedID.isEmpty || state.importing)
            .help("Закрыть и заново открыть сессию с выбранным iPhone (⌘R).")
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(connectionColor).frame(width: 8, height: 8)
                Text(state.connectionState.label).font(.callout.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(connectionColor.opacity(0.12), in: Capsule())
            if !state.status.isEmpty {
                Text(state.status)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                actions.verifyArchive()
            } label: {
                Label(state.verifyingArchive ? "Проверка…" : "Проверить архив…", systemImage: "checkmark.shield")
            }
            .disabled(state.verifyingArchive || state.importing)
            .help("Сверить сохранённую папку переноса с её отчётом и контрольными суммами. Телефон для этого не нужен.")
            Button {
                actions.copyDiagnostics()
            } label: {
                Label("Диагностика", systemImage: "doc.on.clipboard")
            }
            .help("Скопировать версию macOS и приложения, состояние подключения и числовые показатели. Серийные номера и имена фотографий не включаются.")
        }
    }

    private var connectionColor: Color {
        switch state.connectionState {
        case .ready: .green
        case .catalog, .loading: .blue
        case .unlock: .orange
        case .error: .red
        case .waiting: .secondary
        }
    }

    // MARK: - Content

    private func filterBar(visible: [UsbImportItem]) -> some View {
        HStack(spacing: 12) {
            Picker("Тип", selection: $filter) {
                ForEach(UsbImportTypeFilter.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 300)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск по имени файла", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Очистить поиск")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            Button("Выбрать показанные (\(visible.count))") {
                actions.setSelection(state.selected.union(visible.map(\.id)))
            }
            .disabled(!state.ready || visible.isEmpty || state.importing)
            .help("Добавить к выбору все показанные файлы. Shift-щелчок по карточке выбирает диапазон от предыдущей.")
            ControlGroup {
                Button {
                    if let size = PhoneCatalogTileSize.smaller(than: tileSize) { tileSize = size }
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(PhoneCatalogTileSize.smaller(than: tileSize) == nil)
                .help("Мельче карточки (⌘−)")
                Button {
                    if let size = PhoneCatalogTileSize.larger(than: tileSize) { tileSize = size }
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(PhoneCatalogTileSize.larger(than: tileSize) == nil)
                .help("Крупнее карточки (⌘=)")
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private func content(visible: [UsbImportItem]) -> some View {
        if state.items.isEmpty {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            ContentUnavailableView {
                Label("Ничего не найдено", systemImage: "magnifyingglass")
            } description: {
                Text("Очистите поиск или измените выбранный тип файлов.")
            } actions: {
                Button("Сбросить поиск и тип") {
                    query = ""
                    filter = .all
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Снимки только в iCloud могут отсутствовать; Live Photo может отображаться отдельными фото и видео. Полная медиатека — во вкладке «Каталог iPhone».")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize), spacing: 12)], spacing: 12,
                              pinnedViews: [.sectionHeaders]) {
                        ForEach(Array(PhoneCatalogTimeline.sections(of: visible, date: \.date).enumerated()), id: \.offset) { _, section in
                            Section {
                                ForEach(section.items) { item in
                                    UsbImportTile(item: item,
                                                  selected: state.selected.contains(item.id),
                                                  ready: state.ready,
                                                  thumbnailHeight: (tileSize * 0.8).rounded(),
                                                  thumbnail: actions.thumbnail) {
                                        handleClick(item, visible: visible)
                                    }
                                }
                            } header: {
                                Text(PhoneCatalogTimeline.title(for: section.month))
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .background(Color(nsColor: .windowBackgroundColor))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
                .disabled(state.importing || !state.ready)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch state.connectionState {
        case .waiting:
            ContentUnavailableView {
                Label("Подключите iPhone", systemImage: "iphone.and.arrow.forward")
            } description: {
                Text(state.devices.isEmpty
                     ? "Подключите кабель. Разблокируйте телефон и нажмите «Доверять» на iPhone, если появится запрос."
                     : "Выберите iPhone в списке вверху справа.")
            }
        case .unlock:
            ContentUnavailableView {
                Label("Разблокируйте iPhone", systemImage: "lock.open")
            } description: {
                Text("Оставьте iPhone разблокированным, пока Mac подключается к нему.")
            }
        case .catalog, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Получаем список файлов с iPhone…").foregroundStyle(.secondary)
            }
        case .ready:
            ContentUnavailableView {
                Label("Доступных USB-файлов нет", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Для этого iPhone через кабель сейчас не удалось получить доступные файлы. Полный список медиатеки — во вкладке «Каталог iPhone».")
            }
        case .error:
            ContentUnavailableView {
                Label("Не удалось подключиться", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Проверьте кабель и доверие к Mac, затем нажмите «Подключиться снова». «Диагностика» копирует сведения для разбора.")
            } actions: {
                Button("Подключиться снова") { actions.reconnect() }
                    .disabled(state.connectedID.isEmpty)
            }
        }
    }

    /// A plain click toggles one file; Shift-click adds every shown file between the previous click and this one.
    private func handleClick(_ item: UsbImportItem, visible: [UsbImportItem]) {
        var selection = state.selected
        if NSEvent.modifierFlags.contains(.shift), let previous = anchor, previous != item.id,
           let range = UsbImportFiltering.range(in: visible, from: previous, to: item.id) {
            selection.formUnion(range)
        } else if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
        anchor = item.id
        actions.setSelection(selection)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if hasFiles {
                    Text(selectionSummary)
                        .font(.callout.weight(.medium).monospacedDigit())
                    Button("Снять выбор") { actions.setSelection([]) }
                        .disabled(state.selected.isEmpty || state.importing)
                }
                Spacer(minLength: 8)
                if state.importing {
                    ProgressView(value: Double(state.importProcessed), total: Double(max(1, state.importTotal)))
                        .frame(width: 120)
                    Text("\(state.importProcessed) из \(state.importTotal)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Отменить перенос", role: .cancel) { actions.cancelImport() }
                } else if let archive = state.lastArchive {
                    Button {
                        actions.openArchive(archive)
                    } label: {
                        Label("Открыть папку", systemImage: "folder")
                    }
                }
                if hasFiles {
                    Button {
                        actions.importSelected()
                    } label: {
                        Label("Сохранить выбранные…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!state.ready || state.selected.isEmpty || state.importing)
                    .help("Сохранить выбранные файлы в новую папку с отчётом и контрольными суммами (⌘S).")
                }
            }
            ForEach(statusLines) { line in
                StatusMessageRow(symbol: line.symbol, text: line.text, tone: line.tone)
            }
            Text("После переноса фото остаются на iPhone. Прототип не удаляет снимки и не управляет iCloud. Проверка архива сверяет файлы с локальным отчётом, а не с iPhone.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var hasFiles: Bool { !state.items.isEmpty || state.importing }

    private var selectionSummary: String {
        guard !state.selected.isEmpty else { return "Ничего не выбрано" }
        let bytes = UsbImportFiltering.selectedBytes(state.items, selected: state.selected)
        return "Выбрано: \(state.selected.count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private struct StatusLine: Identifiable {
        let id: String
        let symbol: String
        let text: String
        let tone: StatusTone
    }

    private var statusLines: [StatusLine] {
        var lines: [StatusLine] = []
        if !state.results.isEmpty {
            let tone: StatusTone = state.lastImportSucceeded == true ? .success : (state.lastImportSucceeded == false ? .warning : .neutral)
            let symbol = state.lastImportSucceeded == true ? "checkmark.circle" : (state.lastImportSucceeded == false ? "exclamationmark.triangle" : "info.circle")
            lines.append(StatusLine(id: "import", symbol: symbol, text: state.results, tone: tone))
        }
        if !state.verificationResults.isEmpty {
            let tone: StatusTone = state.lastVerificationPassed == true ? .success : (state.lastVerificationPassed == false ? .warning : .neutral)
            lines.append(StatusLine(id: "verify", symbol: "checkmark.shield", text: state.verificationResults, tone: tone))
        }
        if state.ready && state.selected.isEmpty && !state.items.isEmpty && !state.importing {
            lines.append(StatusLine(id: "hint", symbol: "info.circle",
                                    text: "Выберите файлы на карточках и нажмите «Сохранить выбранные…».", tone: .neutral))
        }
        return lines
    }
}

private struct UsbImportTile: View {
    let item: UsbImportItem
    let selected: Bool
    let ready: Bool
    let thumbnailHeight: CGFloat
    let thumbnail: @MainActor (String) async -> NSImage?
    let toggle: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 5) {
                Color.secondary.opacity(0.1)
                    .frame(maxWidth: .infinity)
                    .frame(height: thumbnailHeight)
                    .overlay {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            Image(systemName: item.isVideo ? "video" : "photo")
                                .font(.title).foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selected ? Color.accentColor : Color.black.opacity(0.18))
                            .shadow(color: .black.opacity(selected ? 0 : 0.35), radius: 2)
                            .padding(6)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if item.isVideo {
                            Image(systemName: "video.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.55), in: Capsule())
                                .padding(6)
                        }
                    }
                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(7)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.name), \(details)")
        .accessibilityValue(selected ? "Выбрано" : "Не выбрано")
        .task(id: "\(item.id)-\(ready)") { image = await thumbnail(item.id) }
    }

    private var details: String {
        let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        guard let date = item.date else { return size }
        return "\(size) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}
