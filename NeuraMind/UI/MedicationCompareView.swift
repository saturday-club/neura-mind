import SwiftUI

// MARK: - Stats Model

struct MedicationStats {
    let avgDurationMinutes: Double   // average (endTimestamp - startTimestamp) / 60
    let sessionsPerDay: Double       // average number of summaries per day
    let daysOfData: Int              // distinct calendar days with at least one summary
    let topApps: [String]            // top 3 apps by frequency
    let topActivity: String?         // most common activityType
}

// MARK: - Compare View

/// Two-column stat grid comparing on-medication vs off-medication sessions
/// over the last 30 days. Requires at least 1 summary per group.
struct MedicationCompareView: View {
    var storageManager: StorageManager

    @State private var onStats: MedicationStats?
    @State private var offStats: MedicationStats?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading comparison...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if onStats == nil && offStats == nil {
                emptyState
            } else {
                statsGrid
            }
        }
        .onAppear { loadStats() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("Not enough data yet")
                .font(.headline)
            Text("Toggle medication on and off, then generate a few summaries in each state to see a comparison.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header row
                HStack {
                    Text("Last 30 days")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.fixed(140)),
                        GridItem(.fixed(140))
                    ],
                    alignment: .leading,
                    spacing: 0
                ) {
                    // Column headers
                    Text("").frame(maxWidth: .infinity, alignment: .leading)
                    columnHeader("💊 On Meds", color: .blue)
                    columnHeader("Off Meds", color: .secondary)

                    Divider().gridCellColumns(3)

                    statRow(
                        label: "Avg session",
                        on: onStats.map { formatMinutes($0.avgDurationMinutes) },
                        off: offStats.map { formatMinutes($0.avgDurationMinutes) }
                    )
                    statRow(
                        label: "Sessions / day",
                        on: onStats.map { String(format: "%.1f", $0.sessionsPerDay) },
                        off: offStats.map { String(format: "%.1f", $0.sessionsPerDay) }
                    )
                    statRow(
                        label: "Days of data",
                        on: onStats.map { "\($0.daysOfData) days" },
                        off: offStats.map { "\($0.daysOfData) days" }
                    )
                    statRow(
                        label: "Top apps",
                        on: onStats.map { $0.topApps.prefix(2).joined(separator: ", ") },
                        off: offStats.map { $0.topApps.prefix(2).joined(separator: ", ") }
                    )
                    statRow(
                        label: "Top activity",
                        on: onStats?.topActivity ?? offStats.flatMap { _ in nil },
                        off: offStats?.topActivity ?? onStats.flatMap { _ in nil }
                    )
                }

                if onStats == nil || offStats == nil {
                    Text("One or more groups have no data yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func columnHeader(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private func statRow(label: String, on: String?, off: String?) -> some View {
        Text(label)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)

        Text(on ?? "—")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(on != nil ? .primary : .secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)

        Text(off ?? "—")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(off != nil ? .primary : .secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)

        // Separator across full row
        Divider().gridCellColumns(3)
    }

    // MARK: - Data Loading

    private func loadStats() {
        isLoading = true
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!

        // Fetch all summaries from last 30 days — at most a few hundred rows
        let all = (try? storageManager.summaries(from: thirtyDaysAgo, to: Date(), limit: 2000)) ?? []

        let onSummaries  = all.filter { $0.medicationActive }
        let offSummaries = all.filter { !$0.medicationActive }

        onStats  = buildStats(from: onSummaries)
        offStats = buildStats(from: offSummaries)
        isLoading = false
    }

    private func buildStats(from summaries: [SummaryRecord]) -> MedicationStats? {
        guard !summaries.isEmpty else { return nil }

        let cal = Calendar.current
        let days = Set(summaries.map { cal.startOfDay(for: $0.startDate) })
        guard days.count >= 1 else { return nil }

        // Avg session duration
        let durations = summaries.map { $0.endTimestamp - $0.startTimestamp }
        let avgDuration = durations.reduce(0, +) / Double(durations.count) / 60.0

        // Sessions per day
        let sessionsPerDay = Double(summaries.count) / Double(days.count)

        // Top apps by frequency
        var appCounts: [String: Int] = [:]
        for s in summaries {
            for app in s.decodedAppNames {
                appCounts[app, default: 0] += 1
            }
        }
        let topApps = appCounts.sorted { $0.value > $1.value }.prefix(3).map(\.key)

        // Top activity type
        var activityCounts: [String: Int] = [:]
        for s in summaries {
            if let a = s.activityType { activityCounts[a, default: 0] += 1 }
        }
        let topActivity = activityCounts.sorted { $0.value > $1.value }.first?.key

        return MedicationStats(
            avgDurationMinutes: avgDuration,
            sessionsPerDay: sessionsPerDay,
            daysOfData: days.count,
            topApps: Array(topApps),
            topActivity: topActivity
        )
    }

    // MARK: - Formatting

    private func formatMinutes(_ minutes: Double) -> String {
        if minutes < 1 { return "<1 min" }
        return "\(Int(minutes.rounded())) min"
    }
}
