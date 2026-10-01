import AppKit
import SwiftUI

struct PhoneCatalogView: View {
    @StateObject private var reader = PhoneCatalogReader()
    @StateObject private var thumbnails = PhoneThumbnailLoader()
    @ObservedObject var exporter: PhoneAssetExporter
    @State private var category = PhoneCatalogCategory.mediaLibrary
    @State private var type = PhoneCatalogTypeFilter.all
    @State private var search = ""
    @State private var selected: Set<Int64> = []
    @State private var page = 0
    private let pageSize = 24

    private var visibleAssets: [PhoneCatalogAsset] {
        reader.snapshot?.assets(category: category, type: type, search: search) ?? []
    }

    private var pageCount: Int { max(1, (visibleAssets.count + pageSize - 1) / pageSize) }
    private var pageAssets: [PhoneCatalogAsset] {
        Array(visibleAssets.dropFirst(min(page, pageCount - 1) * pageSize).prefix(pageSize))
    }
    private var selectedAssets: [PhoneCatalogAsset] {
        reader.snapshot?.assets.filter { selected.contains($0.id) } ?? []
    }
    private var canExportLivePhoto: Bool {
        selectedAssets.count == 1 && selectedAssets[0].isVisibleLibraryItem && selectedAssets[0].mediaType == .photo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Каталог iPhone").font(.largeTitle.bold())
                    Text("Каталог телефона; доступность оригиналов ещё не проверена")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    reader.refresh()
                } label: {
                    if reader.isRefreshing {
                        ProgressView().controlSize(.small).padding(.trailing, 5)
                        Text("Обновление…")
                    } else {
                        Label("Обновить с iPhone", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(reader.isRefreshing || reader.isLoadingSnapshot || thumbnails.isLoading || exporter.isExporting)
            }

            if let error = reader.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let snapshot = reader.snapshot {
                let libraryCounts = snapshot.counts(in: .mediaLibrary)
                let allCounts = snapshot.counts(in: .allRecords)
                HStack(spacing: 12) {
                    countCard(title: "Медиатека", detail: "Фото и видео", photos: libraryCounts.photos, videos: libraryCounts.videos)
                    countCard(title: "Все записи", detail: "Без корзины; шире видимого списка", photos: allCounts.photos, videos: allCounts.videos)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Снимок каталога").font(.caption).foregroundStyle(.secondary)
                        Text(snapshot.snapshotDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }

                HStack(spacing: 12) {
                    Picker("Категория", selection: $category) {
                        ForEach(PhoneCatalogCategory.allCases) { item in Text(item.rawValue).tag(item) }
                    }
                    .frame(width: 230)
                    Picker("Тип", selection: $type) {
                        ForEach(PhoneCatalogTypeFilter.allCases) { item in Text(item.rawValue).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    TextField("Поиск по имени файла", text: $search)
                        .textFieldStyle(.roundedBorder)
                }

                Text(categoryNote)
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button {
                        thumbnails.load(pageAssets, snapshot: snapshot)
                    } label: {
                        Label(thumbnails.isLoading ? "Загрузка превью…" : "Загрузить превью", systemImage: "photo")
                    }
                    .disabled(thumbnails.isLoading || reader.isRefreshing || exporter.isExporting || !thumbnails.canLoad(pageAssets))
                    Text("До 12 файлов за раз").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("Выбрано: \(selected.count)").monospacedDigit()
                    Button("Снять выбор") { selected.removeAll() }.disabled(selected.isEmpty || exporter.isExporting)
                }
                if let message = thumbnails.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        chooseExportFolder(for: snapshot)
                    } label: {
                        Label("Сохранить выбранные файлы…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(selectedAssets.isEmpty || selectedAssets.count > 12 || exporter.isExporting || thumbnails.isLoading || reader.isRefreshing || reader.isLoadingSnapshot)
                    Button("Сохранить Live Photo…") {
                        chooseExportFolder(for: snapshot, livePhoto: true)
                    }
                    .disabled(!canExportLivePhoto || exporter.isExporting || thumbnails.isLoading || reader.isRefreshing || reader.isLoadingSnapshot)
                    .help("Выберите одну Live Photo. Сохраняются доступные фото и видео неотредактированного снимка; каждый файл до 32 МБ.")
                    if exporter.isExporting {
                        Button("Остановить") { exporter.cancel() }
                    }
                    Spacer()
                    if let folder = exporter.outputFolder {
                        Button("Открыть папку") { NSWorkspace.shared.open(folder) }
                    }
                }
                Text("Файлы: до 12, каждый до 32 МБ. Live Photo: один снимок вместе с его видео.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button {
                        exporter.checkAvailability(assets: selectedAssets, snapshot: snapshot)
                    } label: {
                        Label("Проверить файлы", systemImage: "magnifyingglass")
                    }
                    .disabled(selectedAssets.isEmpty || selectedAssets.count > 12 || exporter.isExporting || thumbnails.isLoading || reader.isRefreshing || reader.isLoadingSnapshot)
                    Text("До 12 карточек. Для Live Photo проверяется фото; видео проверяется при переносе пары.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if let message = exporter.availabilityMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let message = exporter.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12)], spacing: 12) {
                        ForEach(pageAssets) { asset in card(for: asset) }
                    }
                    .padding(2)
                }
                .overlay {
                    if visibleAssets.isEmpty {
                        ContentUnavailableView("Записей нет", systemImage: "photo.on.rectangle.angled")
                    }
                }
                HStack {
                    Button("Предыдущая") { page = max(0, page - 1) }.disabled(page == 0)
                    Text("Страница \(min(page, pageCount - 1) + 1) из \(pageCount) · \(visibleAssets.count) записей")
                        .font(.caption).monospacedDigit()
                    Button("Следующая") { page = min(pageCount - 1, page + 1) }.disabled(page >= pageCount - 1)
                    Spacer()
                    Text("Полнота оригиналов и данных правок пока не подтверждена.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if reader.isRefreshing || reader.isLoadingSnapshot {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text("Читаем сохранённый каталог телефона.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Каталог пока не загружен", systemImage: "iphone")
                } description: {
                    Text("Подключите iPhone и обновите каталог. Это чтение списка файлов и дат, без переноса фотографий.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 540)
        .onChange(of: category) { _, _ in page = 0 }
        .onChange(of: type) { _, _ in page = 0 }
        .onChange(of: search) { _, _ in page = 0 }
        .onChange(of: reader.snapshot?.sourceFolder) { _, _ in
            page = 0
            selected.removeAll()
            thumbnails.reset()
        }
    }

    private func card(for asset: PhoneCatalogAsset) -> some View {
        Button {
            if selected.contains(asset.id) { selected.remove(asset.id) } else { selected.insert(asset.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    if let image = thumbnails.images[asset.id] {
                        Image(nsImage: image).resizable().scaledToFit().padding(3)
                    } else {
                        VStack(spacing: 7) {
                            Image(systemName: asset.mediaType == .video ? "video" : "photo").font(.largeTitle)
                            Text(thumbnails.unavailable.contains(asset.id) ? "Превью недоступно" : "Без превью")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary)
                    }
                    if selected.contains(asset.id) {
                        Image(systemName: "checkmark.circle.fill").font(.title2)
                            .foregroundStyle(.white, Color.accentColor).padding(6)
                    }
                }
                .frame(height: 160)
                Text(asset.filename.isEmpty ? "Имя файла не указано" : asset.filename)
                    .font(.callout).lineLimit(1)
                Text(rowDetails(for: asset)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if exporter.availabilitySourceFolder == reader.snapshot?.sourceFolder,
                   let check = exporter.availabilityResults[asset.id],
                   check.sourceFolder == reader.snapshot?.sourceFolder {
                    availabilityLabel(for: check)
                }
                if exporter.sourceFolder == reader.snapshot?.sourceFolder {
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
            .padding(8)
            .background(selected.contains(asset.id) ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected.contains(asset.id) ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(exporter.isExporting || !asset.isVisibleLibraryItem || (asset.mediaType != .photo && asset.mediaType != .video))
        .accessibilityLabel("\(asset.filename), \(rowDetails(for: asset))")
        .accessibilityValue(selected.contains(asset.id) ? "Выбрано" : "Не выбрано")
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

    private func chooseExportFolder(for snapshot: PhoneCatalogSnapshot, livePhoto: Bool = false) {
        let assets = selectedAssets
        guard !livePhoto || (assets.count == 1 && assets[0].isVisibleLibraryItem && assets[0].mediaType == .photo) else { return }
        let panel = NSOpenPanel()
        panel.title = livePhoto ? "Сохранить Live Photo с iPhone" : "Сохранить доступные файлы с iPhone"
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

    private func countCard(title: String, detail: String, photos: Int, videos: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text("\(photos) фото · \(videos) видео").font(.title3.monospacedDigit())
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
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
