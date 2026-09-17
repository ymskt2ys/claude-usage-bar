import Foundation
import Security

// MARK: - Model

/// メニューバーに出す 1 行。5 時間枠 / 週 / モデル別週枠のどれか。
struct UsageLimit: Identifiable {
    enum Kind {
        case session          // 5 時間枠
        case weeklyAll        // 週 (全体)
        case weeklyScoped     // 週 (モデル別 = Fable など)
    }

    /// この数字がどこから来たか。
    enum Origin {
        case api                        // OAuth で API から取得 (いま現在の値)
        case planHistory(Date)          // Claude デスクトップアプリが記録した最新サンプル
        case cache(Date)                // ~/.claude.json のキャッシュ (古い可能性が高い)
    }

    let kind: Kind
    /// メニューバー用の短いラベル ("5h" / "7d" / "F")
    let shortLabel: String
    /// ドロップダウン用のラベル ("5時間枠" / "週 (全体)" / "週 (Fable)")
    let longLabel: String
    /// 値が信用できない場合は nil (リセット時刻を過ぎたキャッシュなど)。
    let percent: Double?
    let resetsAt: Date?
    let origin: Origin

    var id: String { longLabel }

    /// キャッシュの値は、その枠のリセット時刻を過ぎたら 0 に戻っているはずで、もう使えない。
    var isOutdated: Bool {
        guard case .cache = origin, let resetsAt else { return false }
        return resetsAt < Date()
    }

    /// 表示用。信用できない値は出さない。
    var displayPercent: Double? { isOutdated ? nil : percent }

    /// 取得時刻が分かるものは、それが古ければ注記を出す。
    var staleNote: String? {
        switch origin {
        case .api:
            return nil
        case .planHistory(let at):
            // デスクトップアプリは 15 分おきに書く。30 分以上開いていたら注記。
            return Date().timeIntervalSince(at) > 1800 ? "\(Format.timestamp(at)) 時点" : nil
        case .cache(let at):
            return isOutdated ? "\(Format.timestamp(at)) 時点・リセット済みで不明"
                              : "\(Format.timestamp(at)) 時点"
        }
    }
}

struct UsageSnapshot {
    let limits: [UsageLimit]
    let fetchedAt: Date
    /// API 取得に失敗した場合の理由。ローカルソースで表示は出せているが、注記として出す。
    let degradedReason: String?
}

enum UsageError: LocalizedError {
    case noCredentials
    case noRefreshToken
    case refreshFailed(Int)
    case refreshRejected(String)
    case unauthorized
    case http(Int)
    case malformed
    case noLocalData

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "Keychain に認証情報なし"
        case .noRefreshToken: return "リフレッシュトークンなし"
        case .refreshFailed(let code): return "トークン更新に失敗 (HTTP \(code))"
        case .refreshRejected(let message): return "トークン更新を拒否された: \(message)"
        case .unauthorized: return "認証エラー"
        case .http(let code): return "API エラー (HTTP \(code))"
        case .malformed: return "レスポンスを解釈できなかった"
        case .noLocalData: return "ローカルにも使用状況データが見つからない"
        }
    }
}

// MARK: - 取得の司令塔

enum UsageFetcher {
    /// 5 時間枠と週は認証なしのローカルソースで必ず出す。
    /// モデル別週枠 (Fable) だけはローカルに無いので、API が取れた時だけ現在値になる。
    static func fetch() async -> Result<UsageSnapshot, Error> {
        var degradedReason: String?
        var apiLimits: [UsageLimit] = []

        do {
            let json = try await ClaudeAPI.usage()
            apiLimits = parseLimits(from: json, origin: .api)
        } catch {
            degradedReason = error.localizedDescription
        }

        // API が全部返せたならそれが一番正確。
        if apiLimits.count >= 3 {
            return .success(UsageSnapshot(limits: apiLimits, fetchedAt: Date(), degradedReason: nil))
        }

        var limits = apiLimits
        // 足りない枠をローカルソースで埋める。
        if let history = PlanHistory.latest() {
            merge(&limits, with: history)
        }
        if let cached = ClaudeConfigCache.limits() {
            merge(&limits, with: cached)
        }

        guard !limits.isEmpty else {
            return .failure(degradedReason == nil ? UsageError.noLocalData : UsageError.noLocalData)
        }

        limits.sort { order($0.kind) < order($1.kind) }
        return .success(UsageSnapshot(limits: limits, fetchedAt: Date(), degradedReason: degradedReason))
    }

    private static func order(_ kind: UsageLimit.Kind) -> Int {
        switch kind {
        case .session: return 0
        case .weeklyAll: return 1
        case .weeklyScoped: return 2
        }
    }

    /// まだ埋まっていない枠だけ追加する (先に入っているソースほど信頼度が高い)。
    private static func merge(_ limits: inout [UsageLimit], with candidates: [UsageLimit]) {
        for candidate in candidates where !limits.contains(where: { $0.kind == candidate.kind }) {
            limits.append(candidate)
        }
    }

    // MARK: パース (API / ~/.claude.json 共通の utilization 形式)

    static func parseLimits(from json: [String: Any], origin: UsageLimit.Origin) -> [UsageLimit] {
        if let raw = json["limits"] as? [[String: Any]] {
            let parsed = raw.compactMap { parseLimitEntry($0, origin: origin) }
            if !parsed.isEmpty { return parsed }
        }
        return parseLegacy(from: json, origin: origin)
    }

    private static func parseLimitEntry(_ entry: [String: Any], origin: UsageLimit.Origin) -> UsageLimit? {
        guard let kindString = entry["kind"] as? String,
              let percent = entry["percent"] as? Double
        else { return nil }

        let resetsAt = (entry["resets_at"] as? String).flatMap(parseDate)

        switch kindString {
        case "session":
            return UsageLimit(kind: .session, shortLabel: "5h", longLabel: "5時間枠",
                              percent: percent, resetsAt: resetsAt, origin: origin)
        case "weekly_all":
            return UsageLimit(kind: .weeklyAll, shortLabel: "7d", longLabel: "週 (全体)",
                              percent: percent, resetsAt: resetsAt, origin: origin)
        case "weekly_scoped":
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = (model?["display_name"] as? String) ?? "モデル別"
            return UsageLimit(kind: .weeklyScoped, shortLabel: String(name.prefix(1)),
                              longLabel: "週 (\(name))", percent: percent,
                              resetsAt: resetsAt, origin: origin)
        default:
            return nil
        }
    }

    /// `limits` が無い古い形式向け。
    private static func parseLegacy(from json: [String: Any], origin: UsageLimit.Origin) -> [UsageLimit] {
        var result: [UsageLimit] = []

        if let five = json["five_hour"] as? [String: Any], let percent = five["utilization"] as? Double {
            result.append(UsageLimit(kind: .session, shortLabel: "5h", longLabel: "5時間枠",
                                     percent: percent,
                                     resetsAt: (five["resets_at"] as? String).flatMap(parseDate),
                                     origin: origin))
        }
        if let week = json["seven_day"] as? [String: Any], let percent = week["utilization"] as? Double {
            result.append(UsageLimit(kind: .weeklyAll, shortLabel: "7d", longLabel: "週 (全体)",
                                     percent: percent,
                                     resetsAt: (week["resets_at"] as? String).flatMap(parseDate),
                                     origin: origin))
        }
        return result
    }

    static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

// MARK: - ローカルソース 1: デスクトップアプリの記録 (認証不要・15 分ごと更新)

enum PlanHistory {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    /// `{"samples":[{"t":<ms>,"u":{"fh":11,"sd":30}}]}` の最新 1 件。
    /// fh = five hour、sd = seven day。モデル別の枠はここには入らない。
    static func latest() -> [UsageLimit]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]],
              let last = samples.last,
              let usage = last["u"] as? [String: Any]
        else { return nil }

        let at = (last["t"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date.distantPast
        var result: [UsageLimit] = []

        if let fh = usage["fh"] as? Double {
            result.append(UsageLimit(kind: .session, shortLabel: "5h", longLabel: "5時間枠",
                                     percent: fh, resetsAt: nil, origin: .planHistory(at)))
        }
        if let sd = usage["sd"] as? Double {
            result.append(UsageLimit(kind: .weeklyAll, shortLabel: "7d", longLabel: "週 (全体)",
                                     percent: sd, resetsAt: nil, origin: .planHistory(at)))
        }
        return result.isEmpty ? nil : result
    }
}

// MARK: - ローカルソース 2: ~/.claude.json のキャッシュ (CLI が動いた時だけ更新)

enum ClaudeConfigCache {
    static func limits() -> [UsageLimit]? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any]
        else { return nil }

        let at = (cached["fetchedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? Date.distantPast
        let parsed = UsageFetcher.parseLimits(from: utilization, origin: .cache(at))
        return parsed.isEmpty ? nil : parsed
    }
}

// MARK: - API (OAuth)

enum ClaudeAPI {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let betaHeader = "oauth-2025-04-20"

    /// 期限切れなら 1 度だけ更新して取り直す。
    static func usage() async throws -> [String: Any] {
        guard var credentials = KeychainCredentials.load() else { throw UsageError.noCredentials }

        if credentials.isExpired {
            credentials = try await refresh(credentials)
        }

        do {
            return try await getUsage(token: credentials.accessToken)
        } catch UsageError.unauthorized {
            // 期限内のはずのトークンが弾かれた場合も、一度だけ更新して再試行する。
            let renewed = try await refresh(credentials)
            return try await getUsage(token: renewed.accessToken)
        }
    }

    private static func getUsage(token: String) async throws -> [String: Any] {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.malformed }
        guard http.statusCode == 200 else {
            throw http.statusCode == 401 ? UsageError.unauthorized : UsageError.http(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.malformed
        }
        return json
    }

    /// Claude Code 本体と同じ手順でトークンを更新し、Keychain に書き戻す。
    /// 書き戻さないとリフレッシュトークンのローテーションで本体のログインが壊れるので、
    /// 更新と保存は必ずセットで行う。
    private static func refresh(_ credentials: KeychainCredentials) async throws -> KeychainCredentials {
        guard let refreshToken = credentials.refreshToken else { throw UsageError.noRefreshToken }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.malformed }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw UsageError.refreshRejected("HTTP \(http.statusCode) \(body)")
        }

        var updated = credentials
        updated.accessToken = accessToken
        // ローテーションされた場合は新しいものに差し替える。返らなければ既存を維持。
        updated.refreshToken = (json["refresh_token"] as? String) ?? credentials.refreshToken
        if let expiresIn = json["expires_in"] as? Double {
            updated.expiresAt = Date().addingTimeInterval(expiresIn)
        }

        try updated.save()
        return updated
    }
}

// MARK: - Keychain

/// Claude Code が `Claude Code-credentials` に置いている資格情報。
/// 同じ項目に `mcpOAuth` も同居しているので、`claudeAiOauth` だけを触る。
/// 他のキーは読んだまま書き戻して壊さない。
struct KeychainCredentials {
    private static let service = "Claude Code-credentials"
    private static let oauthKey = "claudeAiOauth"

    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    /// Keychain に入っていた JSON 全体 (書き戻し用)
    private var root: [String: Any]

    var isExpired: Bool {
        guard let expiresAt else { return true }
        // 期限ぎりぎりで叩かないよう 1 分の余裕を見る。
        return expiresAt.addingTimeInterval(-60) < Date()
    }

    static func load() -> KeychainCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root[oauthKey] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String
        else { return nil }

        return KeychainCredentials(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            root: root
        )
    }

    func save() throws {
        var oauth = (root[Self.oauthKey] as? [String: Any]) ?? [:]
        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt { oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000 }

        var newRoot = root
        newRoot[Self.oauthKey] = oauth
        let data = try JSONSerialization.data(withJSONObject: newRoot)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw UsageError.refreshFailed(Int(status)) }
    }
}

// MARK: - ログイン項目

import ServiceManagement

/// システム設定 → 一般 → ログイン項目 への登録。
/// アプリを移動すると登録が切れるので、その時は登録し直す。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
