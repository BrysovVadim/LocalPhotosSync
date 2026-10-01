import AppKit
import Combine

enum TransferBadge {
    /// Dock badge while a transfer runs: USB import progress as "done/total", a catalog save as an arrow.
    static func label(catalogExporting: Bool, usbImporting: Bool, processed: Int, total: Int) -> String? {
        if usbImporting { return total > 0 ? "\(min(processed, total))/\(total)" : "↓" }
        if catalogExporting { return "↓" }
        return nil
    }
}

/// Shows transfer progress on the Dock icon and bounces it once when a transfer ends while the app is in the background.
@MainActor
final class TransferAttention {
    private var subscriptions: Set<AnyCancellable> = []
    private var wasBusy = false

    func observe(exporter: PhoneAssetExporter, camera: CameraStore) {
        guard subscriptions.isEmpty else { return }
        Publishers.CombineLatest4(exporter.$isTransferring, camera.$importing, camera.$importProcessed, camera.$importTotal)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] exporting, importing, processed, total in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.update(catalogExporting: exporting, usbImporting: importing, processed: processed, total: total)
                }
            }
            .store(in: &subscriptions)
    }

    private func update(catalogExporting: Bool, usbImporting: Bool, processed: Int, total: Int) {
        let label = TransferBadge.label(catalogExporting: catalogExporting, usbImporting: usbImporting,
                                        processed: processed, total: total)
        NSApp?.dockTile.badgeLabel = label
        let busy = label != nil
        if wasBusy && !busy, let app = NSApp, !app.isActive {
            app.requestUserAttention(.informationalRequest)
        }
        wasBusy = busy
    }
}
