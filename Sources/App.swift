import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var errorMessage: String?
    @Published var isRefreshing = false

    private var timer: Timer?

    /// 5 時間枠が動くので 60 秒ごと。メニューを開いた時も引く。
    private let interval: TimeInterval = 60

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        switch await UsageFetcher.fetch() {
        case .success(let snapshot):
            self.snapshot = snapshot
            self.errorMessage = nil
        case .failure(let error):
            self.errorMessage = error.localizedDescription
        }
    }

    /// メニューバーに出す 1 行。例: "5h 14% · 7d 31% · F 3%"
    var menuBarTitle: String {
        guard let limits = snapshot?.limits, !limits.isEmpty else { return "—" }
        return limits
            .map { limit in
                guard let percent = limit.displayPercent else { return "\(limit.shortLabel) —" }
                return "\(limit.shortLabel) \(Int(percent.rounded()))%"
            }
            .joined(separator: " · ")
    }

    /// どれか 1 つでも逼迫していたら色を変える。
    var severityColor: Color {
        let peak = snapshot?.limits.compactMap(\.displayPercent).max() ?? 0
        return UsageStore.color(for: peak)
    }

    static func color(for percent: Double) -> Color {
        switch percent {
        case 90...: return .red
        case 75...: return .orange
        default: return .primary
        }
    }
}

// MARK: - 表示用フォーマッタ

enum Format {
    /// "あと 2時間14分" / "あと 3日"
    static func remaining(until date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return "まもなくリセット" }

        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60

        if days > 0 { return "あと \(days)日\(hours)時間" }
        if hours > 0 { return "あと \(hours)時間\(minutes)分" }
        return "あと \(minutes)分"
    }

    /// "12:50" / "9/14 12:50"
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - ドロップダウン

struct UsagePanel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let limits = store.snapshot?.limits, !limits.isEmpty {
                VStack(spacing: 10) {
                    ForEach(limits) { limit in
                        LimitRow(limit: limit)
                    }
                }
            } else {
                Text(store.errorMessage ?? "読み込み中…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
    }

    private var header: some View {
        HStack {
            Text("Claude Usage")
                .font(.headline)
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sourceNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("更新") {
                    Task { await store.refresh() }
                }
                Spacer()
                Button("終了") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private var sourceNote: String {
        guard let snapshot = store.snapshot else { return "" }
        if let reason = snapshot.degradedReason {
            return "更新 \(Format.timestamp(snapshot.fetchedAt))・API 未取得 (\(reason))"
        }
        return "更新 \(Format.timestamp(snapshot.fetchedAt))"
    }
}

private struct LimitRow: View {
    let limit: UsageLimit

    /// リセットまでの残り時間と、値が古い場合の時点表示。
    private var rowNote: String? {
        let parts = [limit.resetsAt.map(Format.remaining(until:)), limit.staleNote].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(limit.longLabel)
                    .font(.subheadline)
                Spacer()
                Text(limit.displayPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(UsageStore.color(for: limit.displayPercent ?? 0))
            }

            ProgressView(value: min(limit.displayPercent ?? 0, 100), total: 100)
                .tint(UsageStore.color(for: limit.displayPercent ?? 0))

            if let note = rowNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - App

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var store = UsageStore()

    init() {
        // `ClaudeUsageBar --diagnose` で、取得経路の結果だけを標準出力に吐いて終わる。
        // アプリ本体と同じ署名で動くので、Keychain の許可を余分に訊かれない。
        guard CommandLine.arguments.contains("--diagnose") else { return }
        let semaphore = DispatchSemaphore(value: 0)
        // init は MainActor なので、ここで Task を作ると semaphore.wait() と睨み合って止まる。
        Task.detached {
            switch await UsageFetcher.fetch() {
            case .success(let snapshot):
                print("degradedReason: \(snapshot.degradedReason ?? "なし (API 取得成功)")")
                for limit in snapshot.limits {
                    let value = limit.displayPercent.map { "\(Int($0))%" } ?? "—"
                    print("\(limit.shortLabel)\t\(limit.longLabel)\t\(value)\t\(limit.origin)")
                }
            case .failure(let error):
                print("失敗: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store)
        } label: {
            Text(store.menuBarTitle)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(store.severityColor)
                .onAppear { store.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
