import SwiftUI

struct PhoneCatalogView: View {
    @StateObject private var reader = PhoneCatalogReader()
    @State private var category = PhoneCatalogCategory.mediaLibrary
    @State private var type = PhoneCatalogTypeFilter.all
    @State private var search = ""

    private var visibleAssets: [PhoneCatalogAsset] {
        reader.snapshot?.assets(category: category, type: type, search: search) ?? []
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
                .disabled(reader.isRefreshing || reader.isLoadingSnapshot)
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

                List(visibleAssets) { asset in
                    HStack(spacing: 12) {
                        Image(systemName: asset.mediaType == .video ? "video" : "photo")
                            .foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(asset.filename.isEmpty ? "Имя файла не указано" : asset.filename)
                                .lineLimit(1).textSelection(.enabled)
                            Text(rowDetails(for: asset))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if asset.isHidden || asset.visibilityState != 0 {
                            Text(asset.isHidden ? "Скрыто" : "Состояние (asset.visibilityState)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
                .overlay {
                    if visibleAssets.isEmpty {
                        ContentUnavailableView("Записей нет", systemImage: "photo.on.rectangle.angled")
                    }
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
    }

    private var categoryNote: String {
        switch category {
        case .mediaLibrary:
            return "Основная категория телефона с обычной видимостью. Скрытые, удалённые и записи других категорий здесь не показаны."
        case .allRecords:
            return "Все активные записи каталога, включая дополнительные категории, скрытые элементы и записи серий. Это не точный счётчик приложения «Фото»."
        case .otherRecords:
            return "Дополнительные записи телефона. Их состав зависит от версии iOS и истории синхронизации."
        case .unknownScope:
            return "Записи, для которых категория каталога не распознана."
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
