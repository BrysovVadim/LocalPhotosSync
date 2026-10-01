import AppKit
import SwiftUI

struct ArchiveHistoryActions {
    var verifyAll: () -> Void = {}
    var verify: (UUID) -> Void = { _ in }
    var addFolder: () -> Void = {}
    var reveal: (URL) -> Void = { _ in }
    var remove: (UUID) -> Void = { _ in }
}

struct ArchiveHistorySummary: Equatable {
    let total: Int
    let passed: Int
    let problems: Int
    let unchecked: Int

    init(records: [ArchiveRecord], checks: [UUID: ArchiveCheckState]) {
        total = records.count
        var passed = 0, problems = 0, unchecked = 0
        for record in records {
            switch checks[record.id] ?? .unchecked {
            case .passed: passed += 1
            case .failed, .missing: problems += 1
            case .unchecked, .checking: unchecked += 1
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
    let actions: ArchiveHistoryActions

    init(records: [ArchiveRecord], checks: [UUID: ArchiveCheckState], isChecking: Bool, message: String?,
         actions: ArchiveHistoryActions) {
        self.records = records
        self.checks = checks
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
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(records) { record in
                            row(record)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            Divider()
            Text("Проверка сверяет файлы папки с её отчётом import-report.json; телефон для этого не нужен. «Убрать из списка» не удаляет папку с диска. Приложение помнит только пути к папкам и даты их добавления.")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    private func header(_ summary: ArchiveHistorySummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Архивы").font(.title.bold())
                Text("Папки переноса, созданные на этом Mac")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if summary.total > 0 {
                countChip("Всего", value: summary.total, tint: .secondary)
                countChip("В порядке", value: summary.passed, tint: .green)
                countChip("Проблемы", value: summary.problems, tint: summary.problems > 0 ? .orange : .secondary)
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
            stateIcon(state)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(record.parentPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Text("\(record.source.label) · добавлена \(record.recordedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                stateDetail(state)
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

    @ViewBuilder
    private func stateIcon(_ state: ArchiveCheckState) -> some View {
        switch state {
        case .unchecked:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
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
