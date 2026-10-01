import AppKit
import SwiftUI

struct ArchiveHistoryActions {
    var verifyAll: () -> Void = {}
    var verify: (UUID) -> Void = { _ in }
    var addFolder: () -> Void = {}
    var reveal: (URL) -> Void = { _ in }
    var openReport: (URL) -> Void = { _ in }
    var addDropped: ([URL]) -> Void = { _ in }
    var remove: (UUID) -> Void = { _ in }
}

struct ArchiveHistorySummary: Equatable {
    let total: Int
    let passed: Int
    let problems: Int
    let unchecked: Int

    static func isProblem(_ state: ArchiveCheckState?, last: ArchiveLastCheck?) -> Bool {
        switch state ?? .unchecked {
        case .failed, .missing: return true
        case .passed: return false
        case .checking, .unchecked: return last?.outcome == .failed || last?.outcome == .missing
        }
    }

    init(records: [ArchiveRecord], checks: [UUID: ArchiveCheckState]) {
        total = records.count
        var passed = 0, problems = 0, unchecked = 0
        for record in records {
            switch checks[record.id] ?? .unchecked {
            case .passed: passed += 1
            case .failed, .missing: problems += 1
            case .checking: unchecked += 1
            case .unchecked:
                switch record.lastCheck?.outcome {
                case .passed: passed += 1
                case .failed, .missing: problems += 1
                case nil: unchecked += 1
                }
            }
        }
        self.passed = passed
        self.problems = problems
        self.unchecked = unchecked
    }
}

struct ArchiveHistoryScreen: View {
    let records: [ArchiveRecord]
    let checks: [UUID: ArchiveCheckState]
    let isChecking: Bool
    let message: String?
    let summaries: [UUID: ArchiveReportSummary]
    let actions: ArchiveHistoryActions
    @State private var onlyProblems = false

    init(records: [ArchiveRecord], checks: [UUID: ArchiveCheckState], isChecking: Bool, message: String?,
         summaries: [UUID: ArchiveReportSummary] = [:], actions: ArchiveHistoryActions) {
        self.records = records
        self.checks = checks
        self.summaries = summaries
        self.isChecking = isChecking
        self.message = message
        self.actions = actions
    }

    var body: some View {
        let summary = ArchiveHistorySummary(records: records, checks: checks)
        VStack(alignment: .leading, spacing: 0) {
            header(summary)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
            if let message {
                StatusMessageRow(symbol: "exclamationmark.triangle", text: message, tone: .warning)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            if records.isEmpty {
                ContentUnavailableView {
                    Label("Архивов пока нет", systemImage: "archivebox")
                } description: {
                    Text("Папки появятся здесь после сохранения файлов в любой вкладке. Можно добавить существующую папку переноса.")
                } actions: {
                    Button("Добавить папку…") { actions.addFolder() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if onlyProblems && shown.isEmpty {
                ContentUnavailableView {
                    Label("Проблем не найдено", systemImage: "checkmark.seal")
                } description: {
                    Text("Ни одна папка не помечена расхождениями или как ненайденная. Непроверенные папки здесь не показаны.")
                } actions: {
                    Button("Показать все") { onlyProblems = false }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { record in
                            row(record)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            Divider()
            Text("Проверка сверяет файлы папки с её отчётом import-report.json; телефон для этого не нужен. «Убрать из списка» не удаляет папку с диска. Приложение помнит только пути к папкам, даты и итог последней проверки.")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
        }
        .frame(minWidth: 760, minHeight: 540)
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            actions.addDropped(folders)
            return true
        }
    }

    private func header(_ summary: ArchiveHistorySummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Архивы").font(.title.bold())
                Text(Self.totalsLine(records: records, summaries: summaries))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if summary.total > 0 {
                countChip("Всего", value: summary.total, tint: .secondary)
                countChip("В порядке", value: summary.passed, tint: .green)
                Toggle(isOn: $onlyProblems) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Проблемы").font(.caption).foregroundStyle(.secondary)
                        Text("\(summary.problems)").font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(summary.problems > 0 ? Color.orange : Color.secondary)
                    }
                }
                .toggleStyle(.button)
                .help(onlyProblems ? "Показаны только папки с расхождениями или ненайденные. Нажмите, чтобы показать все." :
                                     "Показать только папки с расхождениями или ненайденные.")
            }
            Button {
                actions.addFolder()
            } label: {
                Label("Добавить папку…", systemImage: "folder.badge.plus")
            }
            .disabled(isChecking)
            Button {
                actions.verifyAll()
            } label: {
                if isChecking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Проверка…")
                    }
                } else {
                    Label("Проверить все", systemImage: "checkmark.shield")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isChecking || records.isEmpty)
            .help("Проверить все папки по их отчётам (⌘R).")
        }
    }

    /// Records shown under the current filter; "problems" uses this session's result, else the stored one.
    private var shown: [ArchiveRecord] {
        guard onlyProblems else { return records }
        return records.filter { ArchiveHistorySummary.isProblem(checks[$0.id], last: $0.lastCheck) }
    }

    /// "Папки переноса, созданные на этом Mac" plus totals from the reports that have been read.
    static func totalsLine(records: [ArchiveRecord], summaries: [UUID: ArchiveReportSummary]) -> String {
        let base = "Папки переноса на этом Mac. Перетащите сюда папку из Finder, чтобы добавить её."
        let known = records.compactMap { summaries[$0.id] }
        guard !known.isEmpty else { return base }
        let files = known.reduce(0) { $0 + $1.files }
        let bytes = known.reduce(Int64(0)) { $0 + $1.bytes }
        let partial = known.count < records.count ? " (по \(known.count) из \(records.count) отчётов)" : ""
        return "Всего файлов: \(files), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))\(partial). Перетащите сюда папку из Finder, чтобы добавить её."
    }

    private func countChip(_ title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ record: ArchiveRecord) -> some View {
        let state = checks[record.id] ?? .unchecked
        let missing: Bool = { if case .missing = state { return true } else { return false } }()
        return HStack(alignment: .top, spacing: 12) {
            stateIcon(state, last: record.lastCheck)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(record.parentPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Text(rowDetails(record))
                    .font(.caption).foregroundStyle(.secondary)
                if case .unchecked = state, let last = record.lastCheck {
                    lastCheckDetail(last)
                } else {
                    stateDetail(state)
                }
            }
            Spacer(minLength: 8)
            Button("Проверить") { actions.verify(record.id) }
                .disabled(isChecking)
            Button {
                actions.reveal(record.url)
            } label: {
                Image(systemName: "folder")
            }
            .help("Показать в Finder")
            .disabled(missing)
            Menu {
                Button("Открыть отчёт") { actions.openReport(record.url.appendingPathComponent("import-report.json")) }
                    .disabled(missing)
                Divider()
                Button("Убрать из списка", role: .destructive) { actions.remove(record.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Убрать из списка (папка на диске остаётся)")
        }
        .padding(.vertical, 10)
    }

    private func rowDetails(_ record: ArchiveRecord) -> String {
        var parts = [record.source.label, "добавлена \(record.recordedAt.formatted(date: .abbreviated, time: .shortened))"]
        if let summary = summaries[record.id] {
            parts.append("файлов: \(summary.files), \(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file))")
            if !summary.completed { parts.append("отчёт не завершён") }
        }
        return parts.joined(separator: " · ")
    }

    private func lastCheckDetail(_ last: ArchiveLastCheck) -> some View {
        let when = last.at.formatted(.relative(presentation: .named))
        let text: String
        let color: Color
        switch last.outcome {
        case .passed:
            text = "Последняя проверка \(when): в порядке" + (last.verifiedFiles.map { ", файлов: \($0)" } ?? "")
            color = .green
        case .failed:
            text = "Последняя проверка \(when): расхождения" + (last.problems.map { " (\($0))" } ?? "") + ". Проверьте снова, чтобы увидеть подробности."
            color = .orange
        case .missing:
            text = "Последняя проверка \(when): папка не найдена"
            color = .red
        }
        return Text(text).font(.caption).foregroundStyle(color.opacity(0.85))
    }

    @ViewBuilder
    private func stateIcon(_ state: ArchiveCheckState, last: ArchiveLastCheck? = nil) -> some View {
        switch state {
        case .unchecked:
            switch last?.outcome {
            case .passed: Image(systemName: "checkmark.seal").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            case .missing: Image(systemName: "questionmark.folder").foregroundStyle(.red)
            case nil: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            }
        case .checking:
            ProgressView().controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .missing:
            Image(systemName: "questionmark.folder.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func stateDetail(_ state: ArchiveCheckState) -> some View {
        switch state {
        case .unchecked:
            Text("Не проверялась в этом сеансе").font(.caption).foregroundStyle(.secondary)
        case .checking:
            Text("Проверка файлов и контрольных сумм…").font(.caption).foregroundStyle(.secondary)
        case .passed(let files, let date):
            Text("Проверка пройдена \(date.formatted(date: .omitted, time: .shortened)) · файлов: \(files)")
                .font(.caption).foregroundStyle(.green)
        case .failed(let details, _):
            StatusMessageRow(symbol: "exclamationmark.triangle", text: details, tone: .warning)
        case .missing:
            Text("Папка не найдена: перемещена, удалена или диск не подключён").font(.caption).foregroundStyle(.red)
        }
    }
}
