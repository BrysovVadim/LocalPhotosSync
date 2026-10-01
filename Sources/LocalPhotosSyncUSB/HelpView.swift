import SwiftUI

struct HelpTopic: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let paragraphs: [String]
}

enum HelpContent {
    static let topics: [HelpTopic] = [
        HelpTopic(id: "start", title: "С чего начать", symbol: "play.circle", paragraphs: [
            "Подключите iPhone кабелем, разблокируйте его и подтвердите «Доверять этому компьютеру». На iPhone ничего устанавливать не нужно.",
            "«Каталог iPhone» показывает всю медиатеку телефона: нажмите «Обновить с iPhone». «Импорт по USB» показывает только файлы, которые телефон отдаёт стандартному импорту macOS.",
            "Сохраняйте архив в папку на этом Mac или на внешнем диске, вне iCloud Drive. Каждый перенос создаёт отдельную папку с отчётом и контрольными суммами.",
        ]),
        HelpTopic(id: "catalog", title: "Каталог iPhone", symbol: "iphone", paragraphs: [
            "Выбирайте карточки щелчком; Shift-щелчок выбирает диапазон. За один перенос — до 12 файлов, каждый до 32 МБ.",
            "«Проверить» показывает, читается ли файл на телефоне сейчас. После проверки «Убрать недоступные» оставит только то, что можно сохранить. После частичного переноса «Выбрать несохранённые» выберет то, что не сохранилось.",
            "«Live Photo…» сохраняет одну неотредактированную Live Photo вместе с видео. Правый щелчок по карточке открывает «Просмотр…» и действия для одной карточки.",
            "Меню месяца и стрелка порядка помогают найти нужные снимки; ⌘[ и ⌘] листают страницы, ⌘− и ⌘= меняют размер карточек.",
        ]),
        HelpTopic(id: "usb", title: "Импорт по USB", symbol: "cable.connector", paragraphs: [
            "Выберите iPhone в списке вверху. Если подключение не удалось, разблокируйте телефон и нажмите «Подключиться снова» (⌘R).",
            "Здесь нет лимита в 12 файлов; ход переноса виден на полосе прогресса и на значке в Dock. «Отменить перенос» оставляет незавершённый отчёт, а не готовый архив.",
            "Снимки, которые хранятся только в iCloud, в этой вкладке могут отсутствовать. Полный список медиатеки — во вкладке «Каталог iPhone».",
        ]),
        HelpTopic(id: "archives", title: "Архивы", symbol: "archivebox", paragraphs: [
            "Каждая созданная папка переноса попадает в список. «Проверить все» сверяет файлы с отчётами без телефона и находит изменённые, пропавшие или незавершённые архивы.",
            "Нажмите на счётчик «Проблемы», чтобы оставить только папки с расхождениями. В «Настройках» можно включить проверку при запуске.",
            "«Убрать из списка» не удаляет папку с диска. Приложение хранит только пути к папкам, даты и итог последней проверки.",
        ]),
        HelpTopic(id: "limits", title: "Ограничения", symbol: "exclamationmark.triangle", paragraphs: [
            "Приложение не удаляет фотографии с iPhone и не изменяет iCloud.",
            "Оригиналы, которые хранятся только в iCloud, через USB получить пока нельзя. Наличие карточки или превью не означает, что файл можно перенести.",
            "Полнота данных правок и всех ресурсов Live Photo пока не подтверждена.",
        ]),
    ]
}

/// The Help window (Справка, ⌘?): a short guide to the three tabs and the app's limits.
struct HelpView: View {
    @State private var selection: String? = HelpContent.topics.first?.id

    init() {}

    var body: some View {
        NavigationSplitView {
            List(HelpContent.topics, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            if let topic = HelpContent.topics.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(topic.title, systemImage: topic.symbol).font(.title2.bold())
                        ForEach(Array(topic.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            } else {
                ContentUnavailableView("Выберите раздел", systemImage: "questionmark.circle")
            }
        }
        .frame(minWidth: 620, minHeight: 400)
    }
}
