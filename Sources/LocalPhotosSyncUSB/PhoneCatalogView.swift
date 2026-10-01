import SwiftUI

struct PhoneCatalogView: View {
    @StateObject private var reader = PhoneCatalogReader()
    @StateObject private var thumbnails = PhoneThumbnailLoader()
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
                .disabled(reader.isRefreshing || reader.isLoadingSnapshot || thumbnails.isLoading)
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
                    .disabled(thumbnails.isLoading || reader.isRefreshing || !thumbnails.canLoad(pageAssets))
                    Text("До 12 файлов за раз").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("Выбрано: \(selected.count)").monospacedDigit()
                    Button("Снять выбор") { selected.removeAll() }.disabled(selected.isEmpty)
                }
                if let message = thumbnails.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
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
                    Text("Перенос выбранных записей пока не подключён").font(.caption).foregroundStyle(.secondary)
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
        .accessibilityLabel("\(asset.filename), \(rowDetails(for: asset))")
        .accessibilityValue(selected.contains(asset.id) ? "Выбрано" : "Не выбрано")
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
