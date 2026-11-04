import Foundation

enum UsageProduct: String, Codable, CaseIterable {
    case cursor, grok, bot, other

    var name: String {
        switch self {
        case .cursor: "Cursor"
        case .grok: "Grok"
        case .bot: "Grok Bot"
        case .other: "Unattributed"
        }
    }

    init(billingName: String) {
        switch billingName {
        case "PRODUCT_GROK_BOT": self = .bot
        case let name where name.hasPrefix("PRODUCT_CURSOR"): self = .cursor
        case let name where name.hasPrefix("PRODUCT_GROK_"): self = .grok
        default: self = .other
        }
    }
}

struct ProductSlice: Identifiable {
    let id: UsageProduct
    let fraction: Double

    static func split(_ products: [UsageProduct: Double], total: Double) -> [Self] {
        guard total > 0 else { return [] }
        let denominator = max(total, products.values.reduce(0, +))
        let shares = UsageProduct.allCases.compactMap { product -> Self? in
            guard product != .other, let used = products[product], used > 0 else { return nil }
            return Self(id: product, fraction: used / denominator)
        }
        let remainder = max(0, 1 - shares.map(\.fraction).reduce(0, +))
        return remainder > 0 ? shares + [Self(id: .other, fraction: remainder)] : shares
    }
}

struct GrokBilling: Decodable {
    let prepaidBalance: Cents?
    let currentPeriod: Period?
    let productUsage: [Product]?

    struct Cents: Decodable {
        let dollars: Decimal

        init(from decoder: Decoder) throws {
            enum Key: String, CodingKey { case val }
            let values = try decoder.container(keyedBy: Key.self)
            let cents = (try? values.decode(Int64.self, forKey: .val))
                ?? (try? values.decode(String.self, forKey: .val)).flatMap(Int64.init)
            dollars = Decimal(cents ?? 0) / 100
        }
    }

    struct Period: Decodable {
        let end: String

        var reset: Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let date = formatter.date(from: end) { return date }
            formatter.formatOptions.remove(.withFractionalSeconds)
            return formatter.date(from: end)
        }
    }

    struct Product: Decodable {
        let product: String
        let usagePercent: Double?
    }

    var products: [UsageProduct: Double] {
        (productUsage ?? []).reduce(into: [:]) { totals, item in
            guard let used = item.usagePercent, used.isFinite, used > 0 else { return }
            totals[UsageProduct(billingName: item.product), default: 0] += used
        }
    }

    static let dashboard = URL(string: "https://grok.com/dashboard/billing")!

    static func fetch(cookie: String) async throws -> Self {
        struct Response: Decodable { let config: GrokBilling }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: UsageClient(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let url = URL(string: "https://grok.com/rest/grok/credits")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UsageError.invalidResponse }
        return try JSONDecoder().decode(Response.self, from: data).config
    }
}

struct ProductHistory: Codable {
    let session: String
    let reset: Date
    var last: [UsageProduct: Double]
    var days: [String: [UsageProduct: Double]] = [:]

    mutating func record(_ products: [UsageProduct: Double], day: String) {
        for (product, used) in products {
            let increase = used - (last[product] ?? 0)
            if increase > 0 { days[day, default: [:]][product, default: 0] += increase }
        }
        last = products
    }
}
