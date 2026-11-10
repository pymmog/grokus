import Foundation

struct Usage: Codable {
    let used: Double
    let start: Date?
    let reset: Date?
    let plan: String?
    let included: Bool
    let sampledAt: Date

    func window(calendar: Calendar) -> (periodStart: Date, count: Int, periodEnd: Date)? {
        guard let reset, reset > sampledAt else { return nil }
        let reportedDays = start.map { max(0, Int((reset.timeIntervalSince($0) / 86_400).rounded())) } ?? 0
        let count = (6...8).contains(reportedDays) ? reportedDays : 7
        let periodStart: Date
        if let start, start < reset {
            periodStart = start
        } else if let inferred = calendar.date(byAdding: .day, value: -count, to: reset) {
            periodStart = inferred
        } else {
            return nil
        }
        return (periodStart, count, reset)
    }
}

struct UsageHistory: Codable {
    var session: String
    var latest: Usage?
    var days: [String: Double] = [:]
    var partialSince: Date?

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    mutating func record(_ usage: Usage, calendar: Calendar) {
        let today = Self.dayKey(usage.sampledAt, calendar: calendar)
        let startsToday = usage.start.map { calendar.isDate($0, inSameDayAs: usage.sampledAt) } ?? false
        let previous = latest
        latest = usage
        guard usage.included else {
            days.removeAll()
            partialSince = nil
            return
        }

        var delta = 0.0
        if let previous, previous.included {
            let rolledOver = previous.reset.map { $0 <= usage.sampledAt } == true
                && usage.reset.map { $0 > usage.sampledAt } == true
            let startedEarly = usage.start.flatMap { start in
                previous.start.map { start.timeIntervalSince($0) >= 3600 }
            } == true && previous.used - usage.used >= 0.5
            if rolledOver || startedEarly {
                days.removeAll()
                delta = startsToday || usage.used == 0 ? usage.used : 0
                partialSince = startsToday || usage.used == 0 ? nil : usage.sampledAt
            } else {
                delta = max(0, usage.used - previous.used)
            }
        } else {
            delta = startsToday ? usage.used : 0
            partialSince = startsToday || usage.used == 0 ? nil : usage.sampledAt
        }
        days[today, default: 0] += delta
    }
}

enum UsageError: LocalizedError {
    case signedOut, unavailable, invalidResponse, http(Int)

    var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to Cursor to load Grok Bot usage."
        case .unavailable: "Cursor reported no Grok Bot allowance for this account."
        case .invalidResponse: "Cursor returned an unreadable usage response."
        case .http(let status): "Cursor couldn’t load usage (HTTP \(status))."
        }
    }
}

// Endpoint and payload conventions follow TokenMon by Austin Faulkner-Pearce.
final class UsageClient: NSObject, URLSessionTaskDelegate, Sendable {
    static let dashboard = URL(string: "https://cursor.com/dashboard/usage")!

    func fetch(cookie: String) async throws -> Usage {
        let data = try await request(cookie: cookie)
        return try Self.parse(data, at: Date())
    }

    private func request(cookie: String) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let endpoint = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/bot", forHTTPHeaderField: "Referer")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        switch response.statusCode {
        case 200: return data
        case 300..<400, 401: throw UsageError.signedOut
        default: throw UsageError.http(response.statusCode)
        }
    }

    // The dashboard can redirect an expired session to WorkOS.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    static func parse(_ data: Data, at date: Date) throws -> Usage {
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        if fields["error"] as? String == "not_authenticated" { throw UsageError.signedOut }

        func value(_ camel: String, _ snake: String) -> Any? { fields[camel] ?? fields[snake] }
        func number(_ raw: Any?) -> Double? {
            let number = (raw as? String).flatMap(Double.init) ?? (raw as? NSNumber)?.doubleValue
            return number.flatMap { $0.isFinite ? $0 : nil }
        }
        func timestamp(_ raw: Any?) -> Date? {
            if let parts = raw as? [String: Any], let seconds = number(parts["seconds"]), seconds > 0 {
                return Date(timeIntervalSince1970: seconds + (number(parts["nanos"]) ?? 0) / 1_000_000_000)
            }
            guard let raw = raw as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let parsed = formatter.date(from: raw) { return parsed }
            formatter.formatOptions.remove(.withFractionalSeconds)
            return formatter.date(from: raw)
        }

        let start = timestamp(value("currentPeriodStart", "current_period_start"))
        let reset = timestamp(value("nextResetTimestampUtc", "next_reset_timestamp_utc"))
        let zero = value("includedLimitZero", "included_limit_zero") as? Bool
        let nonzero = value("hasNonZeroIncludedLimit", "has_non_zero_included_limit") as? Bool
        let reported = value("usagePercent", "usage_percent")
        if reported != nil, number(reported) == nil { throw UsageError.invalidResponse }
        guard reported != nil || start != nil || reset != nil || zero != nil || nonzero != nil else {
            throw UsageError.unavailable
        }
        let funding = value("includedUsageSuperGrokPlan", "included_usage_super_grok_plan") as? String
        let label = value("grokPlanLabel", "grok_plan_label") as? String
        return Usage(
            used: min(100, max(0, number(reported) ?? 0)),
            start: start, reset: reset,
            plan: funding?.isEmpty == false ? label.flatMap { $0.isEmpty ? nil : $0 } ?? funding : nil,
            included: zero != true && nonzero != false,
            sampledAt: date
        )
    }
}
