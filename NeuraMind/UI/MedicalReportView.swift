import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Supporting Types

struct FocusBlock {
    let startDate: Date
    let endDate: Date
    let primaryApp: String
    let activityType: String?
    let durationMinutes: Double
}

struct LLMNarrative {
    let executiveSummary: String
    let focusObservations: String
    let dailyNotes: [String: String]   // "YYYY-MM-DD" → one sentence
    let medicationNote: String?
}

// MARK: - Report Data

struct ReportData {
    let from: Date
    let to: Date
    let summaries: [SummaryRecord]
    let generatedAt: Date = Date()

    // MARK: Basic stats

    var totalRecordedSeconds: TimeInterval {
        summaries.reduce(0) { $0 + ($1.endTimestamp - $1.startTimestamp) }
    }

    var formattedDuration: String { formatMinutes(totalRecordedSeconds / 60) }

    // MARK: Work periods
    //
    // Summaries are ~1-minute chunks saved by the summarization engine.
    // A "work period" = run of consecutive summaries where the gap between
    // any two adjacent ones is < 5 minutes (300s). Gaps larger than that
    // are breaks or the end of a sitting.

    var workPeriods: [[SummaryRecord]] {
        let sorted = summaries.sorted { $0.startTimestamp < $1.startTimestamp }
        guard !sorted.isEmpty else { return [] }
        var periods: [[SummaryRecord]] = []
        var current = [sorted[0]]
        for i in 1..<sorted.count {
            if sorted[i].startTimestamp - sorted[i - 1].endTimestamp < 300 {
                current.append(sorted[i])
            } else {
                periods.append(current)
                current = [sorted[i]]
            }
        }
        periods.append(current)
        return periods
    }

    /// Average duration of a continuous work period (minutes).
    var avgWorkPeriodMinutes: Double {
        let periods = workPeriods
        guard !periods.isEmpty else { return 0 }
        let durations = periods.compactMap { p -> Double? in
            guard let first = p.first, let last = p.last else { return nil }
            return (last.endTimestamp - first.startTimestamp) / 60
        }
        return durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
    }

    var medicationDayCounts: (on: Int, off: Int) {
        let cal = Calendar.current
        var onDays = Set<Date>()
        var offDays = Set<Date>()
        for s in summaries {
            let day = cal.startOfDay(for: s.startDate)
            if s.medicationActive { onDays.insert(day) } else { offDays.insert(day) }
        }
        return (onDays.count, offDays.count)
    }

    // MARK: Focus blocks (consecutive sessions < 2 min gap, total ≥ 15 min)

    var focusBlocks: [FocusBlock] {
        let sorted = summaries.sorted { $0.startTimestamp < $1.startTimestamp }
        guard !sorted.isEmpty else { return [] }

        var blocks: [FocusBlock] = []
        var blockStart = sorted[0].startDate
        var blockEnd   = sorted[0].endDate
        var appCounts: [String: Int] = [:]
        var blockActivity: String? = sorted[0].activityType

        func flush() {
            let dur = blockEnd.timeIntervalSince(blockStart) / 60
            guard dur >= 15 else { return }
            let top = appCounts.sorted { $0.value > $1.value }.first?.key ?? "Unknown"
            blocks.append(FocusBlock(startDate: blockStart, endDate: blockEnd,
                                     primaryApp: top, activityType: blockActivity,
                                     durationMinutes: dur))
        }

        for app in sorted[0].decodedAppNames { appCounts[app, default: 0] += 1 }

        for i in 1..<sorted.count {
            let gap = sorted[i].startTimestamp - sorted[i - 1].endTimestamp
            if gap < 120 {
                blockEnd = sorted[i].endDate
                for app in sorted[i].decodedAppNames { appCounts[app, default: 0] += 1 }
                if blockActivity == nil { blockActivity = sorted[i].activityType }
            } else {
                flush()
                blockStart = sorted[i].startDate
                blockEnd   = sorted[i].endDate
                appCounts  = [:]
                for app in sorted[i].decodedAppNames { appCounts[app, default: 0] += 1 }
                blockActivity = sorted[i].activityType
            }
        }
        flush()
        return blocks
    }

    // MARK: App usage (minutes per app)

    var appTimes: [(app: String, minutes: Double)] {
        var times: [String: Double] = [:]
        for s in summaries {
            let dur = (s.endTimestamp - s.startTimestamp) / 60
            let apps = s.decodedAppNames
            guard !apps.isEmpty else { continue }
            let perApp = dur / Double(apps.count)
            for app in apps { times[app, default: 0] += perApp }
        }
        return times.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    // MARK: Context switch rate
    //
    // Counts dominant-app changes between adjacent summaries within the same
    // work period only. Transitions at the boundary between two work periods
    // (i.e. after a 5+ min break) are NOT counted — resuming work in a
    // different app after lunch is not a context switch.
    // Divided by total active recorded time (sum of summary durations).

    var switchesPerHour: Double {
        var switches = 0
        for period in workPeriods {
            for i in 1..<period.count {
                let prev = dominantApp(of: period[i - 1])
                let curr = dominantApp(of: period[i])
                if !prev.isEmpty && !curr.isEmpty && prev != curr { switches += 1 }
            }
        }
        let hours = totalRecordedSeconds / 3600
        return hours > 0 ? Double(switches) / hours : 0
    }

    /// App that appears most often in a summary's appNames list.
    private func dominantApp(of summary: SummaryRecord) -> String {
        let apps = summary.decodedAppNames
        guard !apps.isEmpty else { return "" }
        var counts: [String: Int] = [:]
        for app in apps { counts[app, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.first?.key ?? apps[0]
    }

    // MARK: Activity breakdown

    var activityBreakdown: [(type: String, percent: Int)] {
        var counts: [String: Int] = [:]
        for s in summaries { counts[s.activityType ?? "other", default: 0] += 1 }
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [] }
        return counts.sorted { $0.value > $1.value }
            .map { (type: $0.key, percent: Int(Double($0.value) / Double(total) * 100)) }
    }

    // MARK: Days

    var byDay: [(date: Date, summaries: [SummaryRecord], isOnMedication: Bool)] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: summaries) { cal.startOfDay(for: $0.startDate) }
        return grouped.sorted { $0.key < $1.key }.map { day, daySummaries in
            let sorted = daySummaries.sorted { $0.startTimestamp < $1.startTimestamp }
            let onMed = sorted.first?.medicationActive ?? false
            return (day, sorted, onMed)
        }
    }

    // MARK: Per-day summary text for LLM context

    var dailySummaryContext: String {
        byDay.map { day, daySummaries, onMed in
            let medStr = onMed ? "on medication" : "off medication"
            let lines = daySummaries.prefix(8).map { "  - \($0.summary)" }.joined(separator: "\n")
            return "\(iso(day)) [\(medStr)]:\n\(lines)"
        }.joined(separator: "\n\n")
    }

    // MARK: Helpers

    var formattedDateRange: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        if Calendar.current.isDate(from, inSameDayAs: to) { return f.string(from: from) }
        return "\(f.string(from: from))_\(f.string(from: to))"
    }

    func iso(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    func formatDay(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM yyyy"; return f.string(from: date)
    }
}

func formatMinutes(_ m: Double) -> String {
    let total = Int(m)
    let h = total / 60; let mn = total % 60
    if h > 0 { return "\(h)h \(mn)m" }
    return "\(mn)m"
}

// MARK: - Report Engine

@MainActor
enum ReportEngine {

    static func export(data: ReportData) async {
        let narrative = await generateNarrative(data: data)

        let reportView = MedicalReportView(data: data, narrative: narrative)
        let hosting = NSHostingView(rootView: reportView)
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 10)

        // NSHostingView must be attached to a window to lay out and render correctly.
        // Position it far off-screen so it's never visible.
        let offscreenWindow = NSWindow(
            contentRect: NSRect(x: -9999, y: -9999, width: 700, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        offscreenWindow.contentView = hosting
        offscreenWindow.orderFrontRegardless()

        hosting.layoutSubtreeIfNeeded()
        let height = max(hosting.fittingSize.height, 500)
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: height)
        offscreenWindow.setContentSize(NSSize(width: 700, height: height))
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        let pdfData = hosting.dataWithPDF(inside: hosting.bounds)
        offscreenWindow.orderOut(nil)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = "NeuraMind-Report-\(data.formattedDateRange).pdf"
        panel.title = "Save Activity Report"
        panel.prompt = "Save PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? pdfData.write(to: url)
    }

    // MARK: LLM Narrative

    private static func generateNarrative(data: ReportData) async -> LLMNarrative? {
        let llm = ServiceContainer.shared.llmClient
        let statsBlock = buildStatsBlock(data: data)

        let systemPrompt = """
        You are an ADHD behavioral analyst generating a clinical activity report.
        Write in clear, professional language suitable for a doctor or therapist.
        Be specific and factual. Do not diagnose or recommend medication changes.
        Always respond with valid JSON only — no markdown, no code fences.
        """

        let userPrompt = """
        Generate a narrative analysis for this behavioral activity report.

        \(statsBlock)

        Respond with this JSON structure:
        {
          "executive_summary": "2-3 sentences summarizing the overall period and key patterns",
          "focus_observations": "1-2 sentences about focus quality, consistency, and context switching",
          "daily_notes": { "YYYY-MM-DD": "one sentence per day describing what was worked on and focus quality" },
          "medication_note": "one sentence about medication impact on focus patterns, or null if only one state present"
        }
        """

        do {
            let response = try await llm.complete(
                messages: [LLMMessage(role: "user", content: userPrompt)],
                model: "anthropic/claude-haiku-4-5",
                maxTokens: 600,
                systemPrompt: systemPrompt,
                temperature: 0.2
            )
            return parseNarrative(response, data: data)
        } catch {
            return nil
        }
    }

    private static func buildStatsBlock(data: ReportData) -> String {
        let med = data.medicationDayCounts
        let medStr: String
        if med.on > 0 && med.off > 0 {
            medStr = "Mixed (\(med.on) days on medication, \(med.off) days off)"
        } else if med.on > 0 {
            medStr = "On medication (\(med.on) days)"
        } else {
            medStr = "Off medication (\(med.off) days)"
        }

        let appLines = data.appTimes.prefix(6).map { app, mins in
            let pct = data.totalRecordedSeconds > 0
                ? Int(mins * 60 / data.totalRecordedSeconds * 100) : 0
            return "  \(app): \(formatMinutes(mins)) (\(pct)%)"
        }.joined(separator: "\n")

        let blockLines = data.focusBlocks.prefix(8).map { b in
            let tf = DateFormatter(); tf.dateStyle = .none; tf.timeStyle = .short
            return "  \(tf.string(from: b.startDate))–\(tf.string(from: b.endDate)) | \(Int(b.durationMinutes)) min | \(b.primaryApp)\(b.activityType.map { " | \($0)" } ?? "")"
        }.joined(separator: "\n")

        let actLines = data.activityBreakdown.map { "\($0.type) \($0.percent)%" }.joined(separator: ", ")

        return """
        PERIOD: \(data.formatDay(data.from)) – \(data.formatDay(data.to))
        TOTAL SESSIONS: \(data.summaries.count) | TOTAL TIME: \(data.formattedDuration)
        AVG WORK PERIOD: \(String(format: "%.0f", data.avgWorkPeriodMinutes)) min | FOCUS BLOCKS (≥15 min): \(data.focusBlocks.count)
        APP SWITCHES/HOUR (within work periods): \(String(format: "%.1f", data.switchesPerHour))
        MEDICATION: \(medStr)
        ACTIVITY BREAKDOWN: \(actLines.isEmpty ? "not available" : actLines)

        APP USAGE:
        \(appLines.isEmpty ? "  (no data)" : appLines)

        FOCUS BLOCKS:
        \(blockLines.isEmpty ? "  (no sustained focus blocks detected)" : blockLines)

        DAILY SUMMARIES:
        \(data.dailySummaryContext)
        """
    }

    private static func parseNarrative(_ response: String, data: ReportData) -> LLMNarrative? {
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
        }
        guard let jsonData = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return nil }

        var dailyNotes: [String: String] = [:]
        if let notes = json["daily_notes"] as? [String: String] {
            dailyNotes = notes
        }

        return LLMNarrative(
            executiveSummary: json["executive_summary"] as? String ?? "",
            focusObservations: json["focus_observations"] as? String ?? "",
            dailyNotes: dailyNotes,
            medicationNote: json["medication_note"] as? String
        )
    }
}

// MARK: - Medical Report View

struct MedicalReportView: View {
    let data: ReportData
    let narrative: LLMNarrative?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            rule
            if let n = narrative {
                narrativeSummarySection(n)
                rule
            }
            statsAtAGlance
            rule
            if !data.focusBlocks.isEmpty {
                focusBlocksSection
                rule
            }
            dailyBreakdownSection
            medicationSection
            footer
        }
        .padding(44)
        .frame(width: 700, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NeuraMind")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(white: 0.45))
                    Text("Behavioral Activity Report")
                        .font(.system(size: 22, weight: .bold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Generated \(formatDateTime(data.generatedAt))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(white: 0.5))
                    let med = data.medicationDayCounts
                    if med.on > 0 || med.off > 0 {
                        Text("Medication: On \(med.on)d · Off \(med.off)d")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.5))
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Period:")
                    .font(.system(size: 12)).foregroundStyle(Color(white: 0.45))
                Text(formatPeriod(from: data.from, to: data.to))
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.top, 2)
        }
        .padding(.bottom, 16)
    }

    // MARK: LLM Narrative

    @ViewBuilder
    private func narrativeSummarySection(_ n: LLMNarrative) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("ANALYSIS")

            if !n.executiveSummary.isEmpty {
                Text(n.executiveSummary)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !n.focusObservations.isEmpty {
                Text(n.focusObservations)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.25))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let medNote = n.medicationNote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "pill.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.blue)
                        .padding(.top, 1)
                    Text(medNote)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.3))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.blue.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: Stats at a Glance

    private var statsAtAGlance: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("STATISTICS")
            HStack(spacing: 10) {
                statCell("Focus blocks (≥15m)",
                         value: "\(data.focusBlocks.count)",
                         detail: "sustained periods")
                statCell("Avg work period",
                         value: String(format: "%.0f min", data.avgWorkPeriodMinutes),
                         detail: "before a 5+ min break")
                statCell("Switches / hour",
                         value: String(format: "%.1f", data.switchesPerHour),
                         detail: "within work periods")
            }
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func statCell(_ label: String, value: String, detail: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(white: 0.3))
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.55))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: Focus Blocks

    private var focusBlocksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("FOCUS BLOCKS  (consecutive sessions ≥ 15 minutes)")
            ForEach(data.focusBlocks, id: \.startDate) { block in
                focusBlockRow(block)
            }
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func focusBlockRow(_ block: FocusBlock) -> some View {
        HStack(spacing: 10) {
            Text(timeRange(block.startDate, block.endDate))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
                .frame(width: 130, alignment: .leading)

            Text("\(Int(block.durationMinutes)) min")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .frame(width: 48, alignment: .trailing)

            Text(block.primaryApp)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 120, alignment: .leading)

            if let activity = block.activityType {
                Text(activity)
                    .font(.system(size: 9))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(activityColor(activity).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(activityColor(activity))
            }
        }
        thinLine
    }

    // MARK: App Usage

    private var appUsageSection: some View {
        let top = data.appTimes.prefix(7)
        let maxMins = top.first?.minutes ?? 1

        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("APP USAGE")
            ForEach(Array(top), id: \.app) { app, mins in
                HStack(spacing: 8) {
                    Text(app)
                        .font(.system(size: 11))
                        .frame(width: 130, alignment: .leading)
                    Text(formatMinutes(mins))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(white: 0.4))
                        .frame(width: 52, alignment: .trailing)
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.blue.opacity(0.25))
                            .frame(width: geo.size.width * CGFloat(mins / maxMins))
                    }
                    .frame(height: 10)
                    let pct = data.totalRecordedSeconds > 0
                        ? Int(mins * 60 / data.totalRecordedSeconds * 100) : 0
                    Text("\(pct)%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(white: 0.4))
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: Daily Breakdown

    private var dailyBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("DAILY BREAKDOWN")
                .padding(.bottom, 10)
            ForEach(data.byDay, id: \.date) { date, daySummaries, onMed in
                daySection(date: date, summaries: daySummaries,
                           onMed: onMed, note: narrative?.dailyNotes[data.iso(date)])
            }
        }
        .padding(.top, 14)
    }

    @ViewBuilder
    private func daySection(date: Date, summaries: [SummaryRecord],
                             onMed: Bool, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Day header
            HStack(spacing: 8) {
                Text(data.formatDay(date))
                    .font(.system(size: 13, weight: .semibold))
                Text(onMed ? "💊 On medication" : "Off medication")
                    .font(.system(size: 10))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(onMed ? Color.blue.opacity(0.1) : Color(white: 0.93))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(onMed ? Color.blue : Color(white: 0.4))
                Spacer()
                Text("\(summaries.count) sessions · \(formatMinutes(summaries.reduce(0) { $0 + ($1.endTimestamp - $1.startTimestamp) } / 60))")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.45))
            }
            .padding(.vertical, 8)

            // LLM daily note
            if let note = note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11)).italic()
                    .foregroundStyle(Color(white: 0.35))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }

            // Sessions
            ForEach(summaries, id: \.startTimestamp) { s in
                sessionRow(s)
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func sessionRow(_ s: SummaryRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timeRange(s.startDate, s.endDate))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
                .frame(width: 118, alignment: .leading)

            if let activity = s.activityType {
                Text(activity)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(activityColor(activity).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(activityColor(activity))
                    .frame(width: 80, alignment: .leading)
            } else {
                Color.clear.frame(width: 80, height: 1)
            }

            Text(s.summary)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.15))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        thinLine
    }

    // MARK: Medication Comparison (only if both states present)

    @ViewBuilder
    private var medicationSection: some View {
        let med = data.medicationDayCounts
        if med.on > 0 && med.off > 0 {
            rule
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("MEDICATION COMPARISON")
                let onSessions  = data.summaries.filter { $0.medicationActive }
                let offSessions = data.summaries.filter { !$0.medicationActive }
                LazyVGrid(
                    columns: [GridItem(.fixed(180), alignment: .leading),
                              GridItem(.flexible(), alignment: .leading),
                              GridItem(.flexible(), alignment: .leading)],
                    spacing: 6
                ) {
                    Text("").frame(maxWidth: .infinity, alignment: .leading)
                    Text("💊 On medication").font(.system(size: 10, weight: .semibold)).foregroundStyle(.blue)
                    Text("Off medication").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(white: 0.4))

                    compRow("Sessions",
                            on: "\(onSessions.count)",
                            off: "\(offSessions.count)")
                    compRow("Total time",
                            on: formatMinutes(onSessions.reduce(0) { $0 + ($1.endTimestamp - $1.startTimestamp) } / 60),
                            off: formatMinutes(offSessions.reduce(0) { $0 + ($1.endTimestamp - $1.startTimestamp) } / 60))
                    compRow("Avg session",
                            on: onSessions.isEmpty ? "—" : String(format: "%.1f min", onSessions.reduce(0.0) { $0 + ($1.endTimestamp - $1.startTimestamp) } / Double(onSessions.count) / 60),
                            off: offSessions.isEmpty ? "—" : String(format: "%.1f min", offSessions.reduce(0.0) { $0 + ($1.endTimestamp - $1.startTimestamp) } / Double(offSessions.count) / 60))
                }
            }
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func compRow(_ label: String, on: String, off: String) -> some View {
        Text(label).font(.system(size: 11)).foregroundStyle(Color(white: 0.4))
        Text(on).font(.system(size: 11, weight: .medium))
        Text(off).font(.system(size: 11, weight: .medium))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            rule
            Text("This report was generated automatically by NeuraMind for clinical review.")
                .font(.system(size: 9)).foregroundStyle(Color(white: 0.5))
            Text("Data reflects passive screen activity captured on this device. All data remains local and is not transmitted externally.")
                .font(.system(size: 9)).foregroundStyle(Color(white: 0.5))
        }
        .padding(.top, 16)
    }

    // MARK: Shared components

    private var rule: some View {
        Rectangle().fill(Color(white: 0.82)).frame(height: 1)
    }

    private var thinLine: some View {
        Rectangle().fill(Color(white: 0.92)).frame(height: 0.5)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(white: 0.45))
            .tracking(1.2)
    }

    // MARK: Formatting helpers

    private func formatDateTime(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }

    private func formatPeriod(from: Date, to: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none
        if Calendar.current.isDate(from, inSameDayAs: to) { return f.string(from: from) }
        return "\(f.string(from: from)) – \(f.string(from: to))"
    }

    private func timeRange(_ a: Date, _ b: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
        return "\(f.string(from: a))–\(f.string(from: b))"
    }

    private func activityColor(_ type: String) -> Color {
        switch type {
        case "coding":        return .blue
        case "research":      return .orange
        case "communication": return .green
        case "admin":         return .purple
        default:              return .gray
        }
    }
}
