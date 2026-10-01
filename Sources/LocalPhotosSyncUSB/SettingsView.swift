import SwiftUI

enum SettingsKeys {
    static let autoVerifyArchives = "archives.verifyAtLaunch"
    static let autoVerifyDays = "archives.verifyAtLaunchDays"
}

/// The app's Settings window (⌘,). Every value here is also reachable from the tabs themselves.
struct SettingsView: View {
    @AppStorage("catalog.autoLoadPreviews") private var autoLoadPreviews = false
    @AppStorage("catalog.oldestFirst") private var catalogOldestFirst = false
    @AppStorage("usb.oldestFirst") private var usbOldestFirst = false
    @AppStorage("catalog.tileSize") private var catalogTileSize = PhoneCatalogTileSize.standard
    @AppStorage("usb.tileSize") private var usbTileSize = PhoneCatalogTileSize.standard
    @AppStorage(SettingsKeys.autoVerifyArchives) private var autoVerifyArchives = false
    @AppStorage(SettingsKeys.autoVerifyDays) private var autoVerifyDays = 7
    @AppStorage(ArchiveDestination.lastFolderKey) private var lastFolder = ""

    init() {}

    var body: some View {
        Form {
            Section("Каталог iPhone") {
                Toggle("Загружать превью страницы автоматически", isOn: $autoLoadPreviews)
                Toggle("Сначала старые снимки", isOn: $catalogOldestFirst)
                Picker("Размер карточек", selection: $catalogTileSize) { sizeOptions }
            }
            Section("Импорт по USB") {
                Toggle("Сначала старые файлы", isOn: $usbOldestFirst)
                Picker("Размер карточек", selection: $usbTileSize) { sizeOptions }
            }
            Section("Архивы") {
                Toggle("Проверять архивы при запуске", isOn: $autoVerifyArchives)
                Stepper(value: $autoVerifyDays, in: 1...90) {
                    Text("Если с последней проверки прошло больше \(autoVerifyDays) дн.")
                }
                .disabled(!autoVerifyArchives)
                Text("Проверка идёт в фоне и читает все файлы архива; телефон не нужен. Отключённые диски помечаются как «папка не найдена».")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Папка для сохранения") {
                LabeledContent("Последняя") {
                    Text(lastFolder.isEmpty ? "не выбрана" : lastFolder)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Забыть последнюю папку") { lastFolder = "" }
                    .disabled(lastFolder.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var sizeOptions: some View {
        Text("Мелкие").tag(PhoneCatalogTileSize.steps[0])
        Text("Обычные").tag(PhoneCatalogTileSize.steps[1])
        Text("Крупные").tag(PhoneCatalogTileSize.steps[2])
    }
}
