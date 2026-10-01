import AppKit
import SwiftUI

struct PhoneCatalogView: View {
    @StateObject private var reader: PhoneCatalogReader
    @StateObject private var thumbnails = PhoneThumbnailLoader()
    @ObservedObject var exporter: PhoneAssetExporter
    @AppStorage("catalog.autoLoadPreviews") private var autoLoadPreviews = false
    @AppStorage("catalog.tileSize") private var tileSize = PhoneCatalogTileSize.standard
    @Environment(\.isEnabled) private var isEnabled
    @State private var selectionAnchor: Int64?
    @State private var showOnlySelected = false
    @AppStorage("catalog.oldestFirst") private var oldestFirst = false
    @State private var previewIndex: Int?
    @AppStorage("catalog.category") private var category = PhoneCatalogCategory.mediaLibrary
    @AppStorage("catalog.type") private var type = PhoneCatalogTypeFilter.all
    @State private var search = ""
    @State private var selected: Set<Int64>
    @State private var page = 0
    private let pageSize = 24

    init(exporter: PhoneAssetExporter, reader: PhoneCatalogReader? = nil, selected: Set<Int64> = []) {
        self.exporter = exporter
        _reader = StateObject(wrappedValue: reader ?? PhoneCatalogReader())
        _selected = State(initialValue: selected)
    }

    private var isBusy: Bool {
        exporter.isExporting || thumbnails.isLoading || reader.isRefreshing || reader.isLoadingSnapshot
    }

    private var visibleAssets: [PhoneCatalogAsset] {
        reader.snapshot.map { filteredAssets(in: $0) } ?? []
    }

    private func filteredAssets(in snapshot: PhoneCatalogSnapshot) -> [PhoneCatalogAsset] {
        let assets = DisplayOrder.apply(snapshot.assets(category: category, type: type, search: search),
                                        oldestFirst: oldestFirst)
        return showOnlySelected ? assets.filter { selected.contains($0.id) } : assets
    }

    private var currentPageAssets: [PhoneCatalogAsset] {
        PhoneCatalogPaging.page(visibleAssets, index: page, pageSize: pageSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
            if let error = reader.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            if let snapshot = reader.snapshot {
                catalog(snapshot)
            } else if reader.isRefreshing || reader.isLoadingSnapshot {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text(reader.isRefreshing ? String("Получаем каталог с iPhone…") : String("Читаем сохранённый каталог телефона."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Каталог пока не загружен", systemImage: "iphone")
                } description: {
                    Text("Подключите и разблокируйте iPhone, затем нажмите «Обновить с iPhone». Читается только список файлов и дат, фотографии не переносятся.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .onChange(of: category) { _, _ in page = 0; selectionAnchor = nil; thumbnails.supersede() }
        .onChange(of: type) { _, _ in page = 0; selectionAnchor = nil; thumbnails.supersede() }
        .onChange(of: search) { _, _ in page = 0; selectionAnchor = nil; thumbnails.supersede() }
        .onChange(of: page) { _, _ in thumbnails.supersede() }
        .onChange(of: selected) { _, selection in
            if selection.isEmpty { showOnlySelected = false }
        }
        .onChange(of: showOnlySelected) { _, _ in page = 0; selectionAnchor = nil }
        .onChange(of: oldestFirst) { _, _ in page = 0; selectionAnchor = nil; thumbnails.supersede() }
        .onChange(of: reader.snapshot?.sourceFolder) { _, _ in
            page = 0
            selected.removeAll()
            selectionAnchor = nil
            thumbnails.reset()
        }
        .sheet(isPresented: Binding(get: { previewIndex != nil }, set: { if !$0 { previewIndex = nil } })) {
            previewSheet
        }
        .task(id: autoLoadKey) {
            // One debounced trigger: typing, fast paging and batch hand-offs coalesce into a single load.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            autoLoadIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Каталог iPhone").font(.title.bold())
                if let snapshot = reader.snapshot {
                    Text("Снимок от \(snapshot.snapshotDate.formatted(date: .abbreviated, time: .shortened)) · доступность оригиналов проверяется отдельно")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Список фото и видео самого телефона по USB")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if let snapshot = reader.snapshot {
                statChip(.mediaLibrary, counts: snapshot.counts(in: .mediaLibrary))
                statChip(.allRecords, counts: snapshot.counts(in: .allRecords))
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reader.diagnostics(thumbnailsLoaded: thumbnails.images.count,
                                                                  autoLoadPreviews: autoLoadPreviews), forType: .string)
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .help("Скопировать диагностику каталога: версии, наличие AFC runtime, снимки, счётчики и последнюю ошибку. Имена файлов и идентификаторы телефона не включаются.")
            .accessibilityLabel("Скопировать диагностику каталога")
            Button {
                reader.refresh()
            } label: {
                if reader.isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Обновление…")
                    }
                } else {
                    Label("Обновить с iPhone", systemImage: "arrow.clockwise")
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Получить новый снимок каталога с подключённого iPhone (⌘R). Прежний каталог сохраняется при ошибке.")
            .disabled(isBusy)
        }
    }

    private func statChip(_ chipCategory: PhoneCatalogCategory, counts: (photos: Int, videos: Int)) -> some View {
        let active = category == chipCategory
        return Button {
            category = chipCategory
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(chipCategory.rawValue).font(.caption).foregroundStyle(.secondary)
                Text("\(counts.photos) фото · \(counts.videos) видео")
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(active ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(active ? Color.accentColor.opacity(0.6) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(chipHelp(chipCategory))
        .accessibilityValue(active ? "Показано" : "")
    }

    private func chipHelp(_ chipCategory: PhoneCatalogCategory) -> String {
        chipCategory == .mediaLibrary
            ? "Основная видимая медиатека телефона. Нажмите, чтобы показать её."
            : "Все записи без корзины, шире видимого списка. Нажмите, чтобы показать их."
    }

    // MARK: - Catalog

    @ViewBuilder
    private func catalog(_ snapshot: PhoneCatalogSnapshot) -> some View {
        let visible = filteredAssets(in: snapshot)
        let pageCount = PhoneCatalogPaging.pageCount(total: visible.count, pageSize: pageSize)
        let currentPage = PhoneCatalogPaging.clamp(page, total: visible.count, pageSize: pageSize)
        let pageAssets = PhoneCatalogPaging.page(visible, index: currentPage, pageSize: pageSize)
        let selectedAssets = snapshot.assets.filter { selected.contains($0.id) }
        let actions = PhoneCatalogActionState(selected: selectedAssets, busy: isBusy)
        let months = PhoneCatalogTimeline.months(of: visible)

        VStack(alignment: .leading, spacing: 8) {
            filterBar(months: months, pageAssets: pageAssets)
            Text(categoryNote)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)

        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize), spacing: 12)], spacing: 12,
                      pinnedViews: [.sectionHeaders]) {
                ForEach(Array(PhoneCatalogTimeline.sections(of: pageAssets).enumerated()), id: \.offset) { _, section in
                    Section {
                        ForEach(section.assets) { asset in card(for: asset, snapshot: snapshot) }
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
        .id("\(category.rawValue)-\(type.rawValue)-\(currentPage)")
        .overlay {
            if visible.isEmpty {
                emptyResults
            }
        }

        pageBar(pageAssets: pageAssets, snapshot: snapshot, currentPage: currentPage,
                pageCount: pageCount, total: visible.count)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

        Divider()
        actionBar(snapshot: snapshot, selectedAssets: selectedAssets, actions: actions)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
    }

    private func filterBar(months: [PhoneCatalogMonth], pageAssets: [PhoneCatalogAsset]) -> some View {
        HStack(spacing: 12) {
            Picker("Категория", selection: $category) {
                ForEach(PhoneCatalogCategory.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .labelsHidden()
            .frame(width: 200)
            Picker("Тип", selection: $type) {
                ForEach(PhoneCatalogTypeFilter.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск по имени файла", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
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
            SortOrderButton(oldestFirst: $oldestFirst)
            Menu {
                ForEach(months, id: \.firstIndex) { month in
                    Button("\(PhoneCatalogTimeline.title(for: month.start)) · \(month.count)") {
                        page = PhoneCatalogTimeline.page(containing: month.firstIndex, pageSize: pageSize)
                    }
                }
            } label: {
                Label(currentMonthTitle(pageAssets), systemImage: "calendar")
            }
            .fixedSize()
            .disabled(months.count < 2)
            .help("Перейти к месяцу. Число — записей за месяц с учётом категории, типа и поиска.")
        }
    }

    private func currentMonthTitle(_ pageAssets: [PhoneCatalogAsset]) -> String {
        guard let first = pageAssets.first else { return "Месяц" }
        return PhoneCatalogTimeline.title(for: first.createdAt.map { PhoneCatalogTimeline.monthStart($0, calendar: .current) })
    }

    private var emptyResults: some View {
        let title: String = search.isEmpty ? "Записей нет" : "Ничего не найдено"
        let detail: String = search.isEmpty
            ? "В этой категории и типе записей нет."
            : "Нет файлов, имя которых содержит «\(search)»."
        return ContentUnavailableView {
            Label(title, systemImage: search.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass")
        } description: {
            Text(detail)
        } actions: {
            if !search.isEmpty || type != .all || category != .mediaLibrary {
                Button("Сбросить фильтры") {
                    search = ""
                    type = .all
                    category = .mediaLibrary
                }
            }
        }
    }

    private func pageBar(pageAssets: [PhoneCatalogAsset], snapshot: PhoneCatalogSnapshot,
                         currentPage: Int, pageCount: Int, total: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                thumbnails.load(pageAssets, snapshot: snapshot)
            } label: {
                if thumbnails.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Загрузка превью…")
                    }
                } else {
                    Label("Загрузить превью", systemImage: "photo.on.rectangle")
                }
            }
            .disabled(isBusy || !thumbnails.canLoad(pageAssets))
            .help("Загружает превью этой страницы с iPhone, до 12 фото и видео за раз.")
            Toggle("Автоматически", isOn: $autoLoadPreviews)
                .toggleStyle(.checkbox)
                .help("Загружать превью при открытии страницы. После ошибки подключения автозагрузка ждёт ручного повтора.")
            Spacer(minLength: 8)
            Button("Выбрать на странице") {
                selected = PhoneCatalogSelection.adding(pageAssets, to: selected,
                                                        limit: PhoneCatalogActionState.selectionLimit)
            }
            .disabled(exporter.isExporting || selected.count >= PhoneCatalogActionState.selectionLimit ||
                      !pageAssets.contains { $0.isTransferable && !selected.contains($0.id) })
            .help("Добавляет к выбору фото и видео этой страницы, пока выбрано не больше \(PhoneCatalogActionState.selectionLimit). Shift-щелчок по карточке выбирает диапазон от предыдущей.")
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
            Divider().frame(height: 16)
            Button {
                page = max(0, currentPage - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(currentPage == 0)
            .help("Предыдущая страница (⌘[)")
            Text("\(currentPage + 1) из \(pageCount) · \(total) записей")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                page = min(pageCount - 1, currentPage + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(currentPage >= pageCount - 1)
            .help("Следующая страница (⌘])")
        }
    }

    // MARK: - Action bar

    private func actionBar(snapshot: PhoneCatalogSnapshot, selectedAssets: [PhoneCatalogAsset],
                           actions: PhoneCatalogActionState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle(isOn: $showOnlySelected) {
                    Text(selectionSummary(actions.selectedCount))
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(actions.selectedCount > PhoneCatalogActionState.selectionLimit ? Color.orange : Color.primary)
                }
                .toggleStyle(.button)
                .disabled(selected.isEmpty && !showOnlySelected)
                .help(showOnlySelected ? "Показаны только выбранные карточки. Нажмите, чтобы вернуть все." : "Показать только выбранные карточки, со всех страниц.")
                Button("Снять выбор") { selected.removeAll(); selectionAnchor = nil }
                    .disabled(selected.isEmpty || exporter.isExporting)
                Spacer(minLength: 8)
                if exporter.isExporting {
                    ProgressView().controlSize(.small)
                    Button("Остановить", role: .cancel) { exporter.cancel() }
                } else if let folder = exporter.outputFolder {
                    Button {
                        NSWorkspace.shared.open(folder)
                    } label: {
                        Label("Открыть папку", systemImage: "folder")
                    }
                }
                Button {
                    exporter.checkAvailability(assets: selectedAssets, snapshot: snapshot)
                } label: {
                    Label("Проверить", systemImage: "checklist")
                }
                .disabled(!actions.canCheck)
                .help("Проверяет, читается ли основной файл каждой выбранной карточки на iPhone сейчас. Архив не создаётся.")
                Button {
                    chooseExportFolder(assets: selectedAssets, snapshot: snapshot, livePhoto: true)
                } label: {
                    Label("Live Photo…", systemImage: "livephoto")
                }
                .disabled(!actions.canSaveLivePhoto)
                .help("Выберите одну Live Photo. Сохраняются доступные фото и видео неотредактированного снимка; каждый файл до 32 МБ.")
                Button {
                    chooseExportFolder(assets: selectedAssets, snapshot: snapshot)
                } label: {
                    Label("Сохранить выбранные…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!actions.canSave)
                .help("Сохранить выбранные файлы в новую папку с отчётом проверки (⌘S).")
            }
            ForEach(statusLines(actions: actions)) { line in
                StatusMessageRow(symbol: line.symbol, text: line.text, tone: line.tone)
            }
            followUpButtons(snapshot: snapshot)
            Text("За раз: до \(PhoneCatalogActionState.selectionLimit) файлов, каждый до 32 МБ; Live Photo — одно фото с видео. Полнота оригиналов и данных правок пока не подтверждена.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func followUpButtons(snapshot: PhoneCatalogSnapshot) -> some View {
        let followUps = PhoneCatalogFollowUps(
            selection: selected, checks: exporter.availabilityResults, checksFolder: exporter.availabilitySourceFolder,
            failed: exporter.failedAssetIDs, exportFolder: exporter.sourceFolder, snapshot: snapshot, isBusy: isBusy)
        if !followUps.notReadable.isEmpty || !followUps.unsaved.isEmpty {
            HStack(spacing: 8) {
                if !followUps.notReadable.isEmpty {
                    Button("Убрать недоступные (\(followUps.notReadable.count))") {
                        selected.subtract(followUps.notReadable)
                    }
                    .help("Снять выбор с карточек, у которых последняя проверка не нашла файл, нашла его слишком большим или завершилась ошибкой. Непроверенные остаются.")
                }
                if !followUps.unsaved.isEmpty && followUps.unsaved != selected {
                    Button("Выбрать несохранённые (\(followUps.unsaved.count))") {
                        selected = followUps.unsaved
                        selectionAnchor = nil
                    }
                    .help("Заменить выбор файлами последнего переноса, которые не сохранились, чтобы повторить попытку.")
                }
            }
            .controlSize(.small)
        }
    }

    private func selectionSummary(_ count: Int) -> String {
        count == 0 ? "Ничего не выбрано" : "Выбрано: \(count) из \(PhoneCatalogActionState.selectionLimit)"
    }

    private struct StatusLine: Identifiable {
        let id: String
        let symbol: String
        let text: String
        let tone: StatusTone
    }

    private func statusLines(actions: PhoneCatalogActionState) -> [StatusLine] {
        var lines: [StatusLine] = []
        if let message = exporter.message {
            var tone = StatusTone.neutral
            var symbol = "info.circle"
            if exporter.isExporting {
                symbol = "arrow.down.circle"
            } else if exporter.failedCount > 0 {
                tone = .warning
                symbol = "exclamationmark.triangle"
            } else if exporter.exportedCount > 0 {
                tone = .success
                symbol = "checkmark.circle"
            }
            lines.append(StatusLine(id: "export", symbol: symbol, text: message, tone: tone))
        }
        if let message = exporter.availabilityMessage {
            lines.append(StatusLine(id: "availability", symbol: "checklist", text: message, tone: .neutral))
        }
        if let message = thumbnails.message {
            lines.append(StatusLine(id: "thumbnails", symbol: "photo",
                                    text: message, tone: thumbnails.lastBatchFailed ? .warning : .neutral))
        }
        if let hint = actions.hint {
            lines.append(StatusLine(id: "hint", symbol: "info.circle", text: hint,
                                    tone: actions.selectedCount > PhoneCatalogActionState.selectionLimit ? .warning : .neutral))
        }
        return lines
    }

    // MARK: - Cards

    private func card(for asset: PhoneCatalogAsset, snapshot: PhoneCatalogSnapshot) -> some View {
        let isSelected = selected.contains(asset.id)
        return Button {
            handleClick(asset)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                thumbnail(for: asset)
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(6)
                        } else if asset.isTransferable {
                            Image(systemName: "circle")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .background(Circle().fill(Color.black.opacity(0.18)))
                                .shadow(color: .black.opacity(0.35), radius: 2)
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if asset.mediaType == .video {
                            Image(systemName: "video.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.55), in: Capsule())
                                .padding(6)
                        }
                    }
                Text(asset.filename.isEmpty ? "Имя файла не указано" : asset.filename)
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                Text(rowDetails(for: asset)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if exporter.availabilitySourceFolder == snapshot.sourceFolder,
                   let check = exporter.availabilityResults[asset.id],
                   check.sourceFolder == snapshot.sourceFolder {
                    availabilityLabel(for: check)
                }
                if exporter.sourceFolder == snapshot.sourceFolder {
                    if exporter.savedAssetIDs.contains(asset.id) {
                        Label("Файл сохранён", systemImage: "checkmark.circle")
                            .font(.caption2).foregroundStyle(.green)
                    } else if exporter.failedAssetIDs.contains(asset.id) {
                        Label("Не сохранён", systemImage: "exclamationmark.circle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                if asset.isHidden || asset.visibilityState != 0 {
                    Text(asset.isHidden ? "Скрыто" : "Дополнительная запись")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(7)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Просмотр…") {
                previewIndex = currentPageAssets.firstIndex { $0.id == asset.id }
            }
            Button(isSelected ? "Снять выбор" : "Выбрать") { toggle(asset) }
            Divider()
            Button("Проверить этот файл") {
                exporter.checkAvailability(assets: [asset], snapshot: snapshot)
            }
            .disabled(isBusy)
            Button("Сохранить этот файл…") {
                chooseExportFolder(assets: [asset], snapshot: snapshot)
            }
            .disabled(isBusy)
            if asset.mediaType == .photo {
                Button("Сохранить как Live Photo…") {
                    chooseExportFolder(assets: [asset], snapshot: snapshot, livePhoto: true)
                }
                .disabled(isBusy)
            }
        }
        .disabled(exporter.isExporting || !asset.isTransferable)
        .accessibilityLabel("\(asset.filename), \(rowDetails(for: asset))")
        .accessibilityValue(isSelected ? "Выбрано" : "Не выбрано")
    }

    private func thumbnail(for asset: PhoneCatalogAsset) -> some View {
        Color.secondary.opacity(0.1)
            .frame(maxWidth: .infinity)
            .frame(height: (tileSize * 0.9).rounded())
            .overlay {
                if let image = thumbnails.images[asset.id] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: asset.mediaType == .video ? "video" : "photo").font(.title)
                        Text(thumbnails.unavailable.contains(asset.id) ? "Превью недоступно" : "Без превью")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    /// A plain click toggles one card; Shift-click adds the range from the previous click (within the limit).
    private func handleClick(_ asset: PhoneCatalogAsset) {
        if NSEvent.modifierFlags.contains(.shift), let anchor = selectionAnchor, anchor != asset.id,
           let range = PhoneCatalogSelection.addingRange(in: visibleAssets, from: anchor, to: asset.id, to: selected,
                                                        limit: PhoneCatalogActionState.selectionLimit) {
            selected = range
        } else {
            toggle(asset)
        }
        selectionAnchor = asset.id
    }

    private func toggle(_ asset: PhoneCatalogAsset) {
        if selected.contains(asset.id) { selected.remove(asset.id) } else { selected.insert(asset.id) }
    }

    private func availabilityLabel(for check: PhoneAssetAvailabilityCheck) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch check.state {
            case .mainFileReadable(let bytes):
                Label("Есть на iPhone · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))", systemImage: "iphone")
                    .foregroundStyle(.green)
            case .mainFileMissing:
                Label("Файл не найден", systemImage: "questionmark.folder")
                    .foregroundStyle(.secondary)
            case .exceedsCopyLimit(let bytes):
                Label("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) · больше лимита переноса", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            case .failed:
                Label("Ошибка проверки", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            Text("Проверено \(check.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                .foregroundStyle(.secondary)
        }
        .font(.caption2).lineLimit(2)
        .help("Результат последней проверки наличия основного файла. Он может измениться; целостность и пара Live Photo проверяются при переносе. Если файл не найден, можно попробовать открыть снимок на iPhone, дождаться загрузки и повторить проверку.")
    }

    private var categoryNote: String {
        switch category {
        case .mediaLibrary:
            return "Основная категория телефона с обычной видимостью. Скрытые, удалённые и записи других категорий здесь не показаны."
        case .allRecords:
            return "Все активные записи, включая дополнительные категории, скрытые элементы и серии. Превью загружаются для основной видимой медиатеки."
        case .otherRecords:
            return "Дополнительные записи телефона. Превью этой категории пока не подключены."
        case .unknownScope:
            return "Записи, для которых категория каталога не распознана. Превью этой категории пока не подключены."
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var previewSheet: some View {
        if let snapshot = reader.snapshot {
            CatalogPreviewSheet(
                assets: currentPageAssets,
                index: Binding(get: { previewIndex ?? 0 }, set: { previewIndex = $0 }),
                image: { thumbnails.images[$0] },
                isSelected: { selected.contains($0) },
                availability: { id in
                    guard exporter.availabilitySourceFolder == snapshot.sourceFolder,
                          let check = exporter.availabilityResults[id],
                          check.sourceFolder == snapshot.sourceFolder else { return nil }
                    return check
                },
                canLoadPreview: { thumbnails.canLoad([$0]) },
                isBusy: isBusy,
                actions: CatalogPreviewActions(
                    toggleSelection: { toggle($0) },
                    loadPreview: { thumbnails.load([$0], snapshot: snapshot) },
                    check: { exporter.checkAvailability(assets: [$0], snapshot: snapshot) },
                    save: { asset in
                        previewIndex = nil
                        DispatchQueue.main.async { chooseExportFolder(assets: [asset], snapshot: snapshot) }
                    },
                    close: { previewIndex = nil }))
        }
    }

    /// Everything that can make an automatic preview load possible or necessary.
    private var autoLoadKey: String {
        [String(page), category.rawValue, type.rawValue, search, String(showOnlySelected), String(oldestFirst), String(autoLoadPreviews), String(isEnabled),
         String(thumbnails.isLoading), String(exporter.isExporting), String(reader.isRefreshing),
         String(reader.isLoadingSnapshot), reader.snapshot?.sourceFolder.path ?? ""].joined(separator: "|")
    }

    private func autoLoadIfNeeded() {
        guard autoLoadPreviews, isEnabled, !thumbnails.lastBatchFailed, !isBusy, let snapshot = reader.snapshot else { return }
        let assets = currentPageAssets
        guard thumbnails.canLoad(assets) else { return }
        thumbnails.load(assets, snapshot: snapshot)
    }

    private func chooseExportFolder(assets: [PhoneCatalogAsset], snapshot: PhoneCatalogSnapshot, livePhoto: Bool = false) {
        guard !assets.isEmpty else { return }
        guard !livePhoto || (assets.count == 1 && assets[0].isTransferable && assets[0].mediaType == .photo) else { return }
        let panel = NSOpenPanel()
        panel.title = livePhoto ? "Сохранить Live Photo с iPhone" : "Сохранить доступные файлы с iPhone"
        panel.message = "Для независимого архива выберите папку вне iCloud Drive."
        panel.prompt = "Сохранить сюда"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if livePhoto {
            exporter.exportLivePhoto(asset: assets[0], snapshot: snapshot, destination: destination)
        } else {
            exporter.export(assets: assets, snapshot: snapshot, destination: destination)
        }
    }

    private func rowDetails(for asset: PhoneCatalogAsset) -> String {
        let kind = switch asset.mediaType {
        case .photo: "Фото"
        case .video: "Видео"
        case .other: "Другой тип"
        }
        let date = asset.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "Дата не указана"
        return "\(kind) · \(date)"
    }
}
