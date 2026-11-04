import SwiftUI

extension UsageProduct {
    var tint: NSColor {
        switch self {
        case .cursor: .systemPurple
        case .grok: .systemTeal
        case .bot: .systemBlue
        case .other: .systemGray
        }
    }
}

func percent(_ value: Double, digits: Int = 1) -> String {
    (value / 100).formatted(.percent.precision(.fractionLength(digits)))
}

struct Overview: View {
    @ObservedObject var monitor: Monitor
    @State private var weeksBack = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Grokus").font(.headline)
                Spacer()
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Refresh usage")
                .disabled(monitor.refreshing)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }

            if let usage = monitor.usage {
                weeklyCard(usage)
                if let window = usage.window(calendar: monitor.calendar), let budget = monitor.todayBudget {
                    dailyCard(first: window.firstDay, count: window.count, share: budget.share, left: budget.left)
                }
                Text("Updated \(usage.sampledAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            creditsCard
            if let error = monitor.error {
                Text(error).font(.callout).foregroundStyle(.secondary)
            } else if monitor.usage == nil {
                Text("Checking your Cursor session…").foregroundStyle(.secondary)
            }
            if monitor.needsSignIn {
                Button("Sign in to Cursor…") { monitor.signIn() }
            }
            Text("Right-click the menu bar meter to switch Day / Week.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func weeklyCard(_ usage: Usage) -> some View {
        card {
            HStack {
                heading("Weekly pool")
                Spacer()
                if usage.included {
                    Text("\(percent(usage.used)) used").monospacedDigit().fontWeight(.semibold)
                }
            }
            Text("via \(usage.plan ?? "Cursor")").font(.callout).foregroundStyle(.secondary)
            if usage.included {
                GeometryReader { geometry in
                    Capsule().fill(.primary.opacity(0.12))
                        .overlay(alignment: .leading) {
                            HStack(spacing: 0) {
                                ForEach(monitor.weeklySlices) { slice in
                                    Color(nsColor: slice.id.tint)
                                        .frame(width: geometry.size.width * usage.used / 100 * slice.fraction)
                                }
                            }
                        }
                }
                .frame(height: 7)
                .clipShape(Capsule())
                if monitor.weeklySlices.contains(where: { $0.id != .other }) {
                    HStack(spacing: 10) {
                        ForEach(UsageProduct.allCases.filter { product in
                            product != .other || monitor.weeklySlices.contains { $0.id == .other }
                        }, id: \.self) { product in
                            Label {
                                Text(product.name)
                            } icon: {
                                Circle().fill(Color(nsColor: product.tint)).frame(width: 6, height: 6)
                            }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if let reset = usage.reset {
                    Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("This account has no included Grok Bot allowance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func dailyCard(first: Date, count: Int, share: Double, left: Double) -> some View {
        let calendar = monitor.calendar
        let selectedStart = calendar.date(byAdding: .day, value: -weeksBack * count, to: first) ?? first
        let dates = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: selectedStart) }
        let firstKey = UsageHistory.dayKey(selectedStart, calendar: calendar)
        let hasEarlier = monitor.recordedDays.keys.contains { $0 < firstKey }
        let today = calendar.startOfDay(for: Date())
        let visibleDates = weeksBack == 0 && today > (dates.last ?? today) ? dates + [today] : dates
        return card {
            HStack {
                heading("Daily budget")
                Text(percent(share)).fontWeight(.semibold).monospacedDigit()
                Spacer()
                if let last = visibleDates.last {
                    Text(selectedStart..<last, format: .interval.month(.abbreviated).day())
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { weeksBack += 1 } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous week").disabled(!hasEarlier)
                Button { weeksBack -= 1 } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next week").disabled(weeksBack == 0)
            }
            .buttonStyle(.borderless)
            HStack(spacing: 4) {
                ForEach(visibleDates, id: \.self) { day in
                    let key = UsageHistory.dayKey(day, calendar: calendar)
                    let value = monitor.recordedDays[key]
                    let height = 49 * min(1, (value ?? 0) / share)
                    let slices = monitor.dailySlices(day: key, total: value ?? 0)
                    VStack(spacing: 4) {
                        Capsule().fill(.primary.opacity(0.12))
                            .overlay(alignment: .bottom) {
                                VStack(spacing: 0) {
                                    ForEach(slices.reversed()) { slice in
                                        Color(nsColor: slice.id.tint).frame(height: height * slice.fraction)
                                    }
                                }
                            }
                            .clipShape(Capsule())
                            .frame(width: 11, height: 49)
                        Text(value.map { percent($0, digits: 0) } ?? "–").monospacedDigit()
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    }
                    .font(.caption2)
                    .foregroundStyle(day == today ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                }
            }
            if weeksBack == 0 {
                Text(left >= 0 ? "\(percent(left)) of the weekly pool left in today’s budget"
                    : "\(percent(-left)) of the weekly pool over today’s budget")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if weeksBack == 0, let since = monitor.history?.partialSince, !visibleDates.contains(where: {
                monitor.tokenMonDays[UsageHistory.dayKey($0, calendar: calendar)] != nil
            }) {
                Text("Daily usage is estimated from samples since \(since.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var creditsCard: some View {
        card {
            heading("Prepaid balance")
            if let balance = monitor.prepaidBalance {
                Text(balance.formatted(.currency(code: "USD"))).fontWeight(.semibold)
            } else if monitor.checkingCredits {
                Text("Checking balance…").foregroundStyle(.secondary)
            } else {
                Button(monitor.creditsSignedIn ? "Open Grok billing…" : "Sign in to Grok…") {
                    monitor.signIn(toGrok: true)
                }
            }
        }
        .font(.caption)
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.10)) }
    }
}
