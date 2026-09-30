import SwiftUI

struct LocalPhotosSyncApp: App {
    @StateObject private var store = CameraStore()

    var body: some Scene {
        WindowGroup("Фото с iPhone") {
            LibraryView(store: store)
                .frame(minWidth: 820, minHeight: 580)
        }
        .defaultSize(width: 1060, height: 760)
    }
}

private struct LibraryView: View {
    @ObservedObject var store: CameraStore
    @State private var query = ""
    @State private var filter = "Все"

    private var visible: [MediaItem] {
        store.items.filter {
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) &&
            (filter == "Все" || (filter == "Видео" ? $0.isVideo : !$0.isVideo))
        }
    }

    private var selectedBytes: Int64 {
        store.items.filter { store.selected.contains($0.id) }.reduce(0) { $0 + max(0, $1.bytes) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Фото с iPhone").font(.largeTitle.bold())
                    Text("Первый перенос по USB · без установки на телефон").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Устройство", selection: Binding(get: { store.connectedID }, set: { store.connect($0) })) {
                    Text("Выберите iPhone").tag("")
                    ForEach(store.devices, id: \.self) { device in
                        Text(device.name ?? "Устройство").tag(store.deviceID(device))
                    }
                }
                .frame(width: 250)
                .disabled(store.importing)
            }

            Label(store.status, systemImage: store.ready ? "iphone.gen3" : "cable.connector")
                .textSelection(.enabled)
            HStack {
                Text("Состояние: \(store.connectionState.label)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Скопировать диагностику") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.diagnostics(), forType: .string)
                }
            }
            Text("Показаны файлы, доступные через USB. Снимки только в iCloud могут отсутствовать. Live Photo может отображаться отдельными фото и видео.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Picker("Тип", selection: $filter) {
                    Text("Все").tag("Все")
                    Text("Фото и другие файлы").tag("Фото")
                    Text("Видео").tag("Видео")
                }.pickerStyle(.segmented).frame(width: 380)
                TextField("Поиск по имени файла", text: $query).textFieldStyle(.roundedBorder)
                Button("Подключиться снова") { store.reconnect() }
                    .disabled(store.connectedID.isEmpty || store.importing)
            }

            HStack(spacing: 12) {
                Button("Выбрать показанные (\(visible.count))") { store.selectVisible(visible.map(\.id)) }
                    .disabled(!store.ready || visible.isEmpty || store.importing)
                if store.importing { ProgressView().controlSize(.small) }
                Text(store.importing ? "Перенесено: \(store.importedCount)" : "")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if store.items.isEmpty {
                ContentUnavailableView {
                    Label("Подключите iPhone", systemImage: "iphone.and.arrow.forward")
                } description: {
                    Text("1. Подключите кабель.\n2. Разблокируйте телефон.\n3. Нажмите «Доверять» на iPhone, если появится запрос.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                        ForEach(visible) { item in
                            MediaTile(item: item, selected: store.selected.contains(item.id), store: store, ready: store.ready) {
                                if store.selected.contains(item.id) { store.selected.remove(item.id) }
                                else { store.selected.insert(item.id) }
                            }
                        }
                    }.padding(3)
                }
                .disabled(store.importing || !store.ready)
            }

            Divider()
            HStack {
                Text("Выбрано: \(store.selected.count) · \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))")
                Button("Снять выбор") { store.selected = [] }
                    .disabled(store.selected.isEmpty || store.importing)
                Spacer()
                if let archive = store.lastArchive {
                    Button("Открыть папку") { NSWorkspace.shared.open(archive) }
                }
                Button("Проверить папку переноса…") { store.verifyArchiveFolder() }
                    .disabled(store.verifyingArchive || store.importing)
                if store.importing {
                    Button("Отменить перенос") { store.cancelImport() }
                }
                Button("Сохранить выбранные…") { store.importSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.ready || store.selected.isEmpty || store.importing)
            }
            if !store.results.isEmpty {
                ScrollView { Text(store.results).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 70)
            }
            if !store.verificationResults.isEmpty {
                ScrollView { Text(store.verificationResults).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 90)
                Text("Проверка сверяет сохранённые файлы с локальным отчётом; полноту iPhone или iCloud медиатеки и Live Photo она не подтверждает.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("После переноса фото остаются на iPhone. Этот прототип не удаляет снимки и не управляет iCloud.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

private struct MediaTile: View {
    let item: MediaItem
    let selected: Bool
    let store: CameraStore
    let ready: Bool
    let toggle: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08))
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().scaledToFit()
                        } else {
                            Image(systemName: item.isVideo ? "video" : "photo").font(.largeTitle).foregroundStyle(.secondary)
                        }
                    }.frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 8))
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2).symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary, .white)
                        .padding(6)
                }
                Text(item.name).lineLimit(1).font(.callout)
                HStack {
                    if item.isVideo { Image(systemName: "video.fill") }
                    Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary)
                if let date = item.date {
                    Text(date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .task(id: "\(item.id)-\(ready)") { thumbnail = await store.thumbnail(for: item) }
    }
}
