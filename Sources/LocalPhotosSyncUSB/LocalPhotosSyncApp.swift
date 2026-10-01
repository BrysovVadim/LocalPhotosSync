import SwiftUI

struct LocalPhotosSyncApp: App {
    @StateObject private var store = CameraStore()
    @StateObject private var exporter = PhoneAssetExporter()

    var body: some Scene {
        WindowGroup("Фото с iPhone") {
            TabView {
                PhoneCatalogView(exporter: exporter)
                    .disabled(store.importing)
                    .tabItem { Label("Каталог iPhone", systemImage: "iphone") }
                LibraryView(store: store)
                    .disabled(exporter.isExporting)
                    .tabItem { Label("Импорт по USB", systemImage: "cable.connector") }
            }
            .frame(minWidth: 820, minHeight: 580)
        }
        .defaultSize(width: 1060, height: 760)
    }
}

/// Adapts the live ImageCaptureCore store to the fixture-renderable USB import screen.
private struct LibraryView: View {
    @ObservedObject var store: CameraStore

    var body: some View {
        UsbImportScreen(state: state, actions: actions)
    }

    private var state: UsbImportScreenState {
        UsbImportScreenState(
            devices: store.devices.map { UsbImportDevice(id: store.deviceID($0), name: $0.name ?? "Устройство") },
            connectedID: store.connectedID,
            connectionState: store.connectionState,
            status: store.status,
            ready: store.ready,
            importing: store.importing,
            importProcessed: store.importProcessed,
            importTotal: store.importTotal,
            importedCount: store.importedCount,
            items: store.items.map { UsbImportItem(id: $0.id, name: $0.name, date: $0.date, bytes: $0.bytes, isVideo: $0.isVideo) },
            selected: store.selected,
            results: store.results,
            lastImportSucceeded: store.lastImportSucceeded,
            lastArchive: store.lastArchive,
            verifyingArchive: store.verifyingArchive,
            verificationResults: store.verificationResults,
            lastVerificationPassed: store.lastVerificationPassed)
    }

    private var actions: UsbImportActions {
        let store = store
        return UsbImportActions(
            connect: { store.connect($0) },
            reconnect: { store.reconnect() },
            copyDiagnostics: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.diagnostics(), forType: .string)
            },
            setSelection: { selection in
                guard !store.importing else { return }
                store.selected = selection
            },
            importSelected: { store.importSelected() },
            cancelImport: { store.cancelImport() },
            verifyArchive: { store.verifyArchiveFolder() },
            openArchive: { NSWorkspace.shared.open($0) },
            thumbnail: { await store.thumbnail(forID: $0) })
    }
}
