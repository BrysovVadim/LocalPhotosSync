import AppKit

/// Chooses where a transfer folder is created: remembers the last choice and warns about iCloud Drive.
enum ArchiveDestination {
    static let lastFolderKey = "archive.lastDestination"

    /// True for iCloud Drive (`~/Library/Mobile Documents`) and any other location macOS syncs with iCloud,
    /// such as Desktop and Documents when "Desktop & Documents Folders" is on.
    static func isInICloudDrive(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let mobileDocuments = home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        if path == mobileDocuments || path.hasPrefix(mobileDocuments + "/") { return true }
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem == true {
            return true
        }
        return false
    }

    /// Shows a folder picker starting at the last used folder. Returns nil if the user cancels.
    @MainActor
    static func choose(title: String, prompt: String, defaults: UserDefaults = .standard) -> URL? {
        while true {
            let panel = NSOpenPanel()
            panel.title = title
            panel.message = "Для независимого архива выберите папку вне iCloud Drive."
            panel.prompt = prompt
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            if let last = defaults.string(forKey: lastFolderKey), FileManager.default.fileExists(atPath: last) {
                panel.directoryURL = URL(fileURLWithPath: last, isDirectory: true)
            }
            guard panel.runModal() == .OK, let folder = panel.url else { return nil }
            if isInICloudDrive(folder) && !confirmICloudDrive(folder) { continue }
            defaults.set(folder.path, forKey: lastFolderKey)
            return folder
        }
    }

    @MainActor
    private static func confirmICloudDrive(_ folder: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "«\(folder.lastPathComponent)» синхронизируется с iCloud"
        alert.informativeText = "Такой архив не независим от iCloud: при оптимизации хранения macOS может выгрузить файлы с этого Mac, а изменения в iCloud затронут и их. Для независимого архива выберите папку на этом Mac вне iCloud Drive или внешний диск."
        alert.addButton(withTitle: "Выбрать другую папку")
        alert.addButton(withTitle: "Сохранить сюда всё равно")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
