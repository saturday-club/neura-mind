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

struct SessionAnalysis {
    let time: String
    let duration: String
    let work: String
    let quality: String   // "high" | "moderate" | "fragmented"
}

struct DistractionPeriod {
    let time: String
    let duration: String
    let pattern: String
}

struct LLMNarrative {
    let executiveSummary: String
    let focusSessions: [SessionAnalysis]
    let distractionPeriods: [DistractionPeriod]
    let workSummary: String
    let behavioralObservations: String
    let medicationNote: String?
    let clinicalNotes: String
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

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = "NeuraMind-Report-\(data.formattedDateRange).pdf"
        panel.title = "Save Activity Report"
        panel.prompt = "Save PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let reportView = MedicalReportView(data: data, narrative: narrative)
            .frame(width: 700)
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: reportView)
        renderer.proposedSize = .init(width: 700, height: nil)

        renderer.render { size, renderFn in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            renderFn(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
    }

    // MARK: LLM Narrative

    private static func generateNarrative(data: ReportData) async -> LLMNarrative? {
        let llm = ServiceContainer.shared.llmClient
        let statsBlock = buildStatsBlock(data: data)

        let systemPrompt = """
        You are an ADHD behavioral analyst generating a detailed clinical activity report for a doctor or therapist.
        You have access to a minute-by-minute timeline of the user's computer activity.
        Write in clear, professional clinical language. Be specific — reference actual times, durations, and activities.
        Do not diagnose or recommend medication changes.
        Always respond with valid JSON only — no markdown, no code fences.
        """

        let userPrompt = """
        Analyze this behavioral activity data and generate a detailed clinical report.

        \(statsBlock)

        Respond with this exact JSON structure:
        {
          "executive_summary": "3-4 sentences summarizing the overall period, key patterns, and clinical relevance",
          "focus_sessions": [
            {
              "time": "exact time range e.g. 9:05 AM – 10:42 AM",
              "duration": "e.g. 97 min",
              "work": "Detailed description of exactly what was worked on — be specific about tasks, tools, topics",
              "quality": "high | moderate | fragmented"
            }
          ],
          "distraction_periods": [
            {
              "time": "exact time range",
              "duration": "e.g. 23 min",
              "pattern": "Specific description of the wandering pattern — which apps, what kind of switching, any identifiable trigger"
            }
          ],
          "work_summary": "2-3 paragraph analysis of what was accomplished, what type of work dominated, how productive the session was relative to time spent",
          "behavioral_observations": "2-3 paragraph clinical analysis of attention patterns, context-switching behavior, hyperfocus indicators, fatigue signs, and any ADHD-relevant patterns observed in the timeline",
          "medication_note": "one sentence about medication impact on focus, or null if only one medication state is present",
          "clinical_notes": "2-3 paragraph summary written for a medical professional — include time-of-day patterns, sustained attention capacity, task-switching frequency, and any observations relevant to ADHD assessment or treatment monitoring"
        }

        Rules:
        - focus_sessions should only include genuine sustained work periods (at least 10 continuous minutes)
        - distraction_periods should cover gaps and fragmented activity between work periods
        - Be specific about times — use the actual timestamps from the data
        - If there are no distraction periods, return an empty array
        """

        do {
            let response = try await llm.complete(
                messages: [LLMMessage(role: "user", content: userPrompt)],
                model: "anthropic/claude-haiku-4-5",
                maxTokens: 2000,
                systemPrompt: systemPrompt,
                temperature: 0.2
            )
            return parseNarrative(response)
        } catch {
            return nil
        }
    }

    private static func buildStatsBlock(data: ReportData) -> String {
        let tf = DateFormatter(); tf.dateStyle = .none; tf.timeStyle = .short

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

        let actLines = data.activityBreakdown.map { "\($0.type) \($0.percent)%" }.joined(separator: ", ")

        // Build a detailed work period timeline with actual session content
        var timelineLines: [String] = []
        for (i, period) in data.workPeriods.enumerated() {
            guard let first = period.first, let last = period.last else { continue }
            let dur = Int((last.endTimestamp - first.startTimestamp) / 60)
            timelineLines.append("WORK PERIOD \(i + 1): \(tf.string(from: first.startDate)) – \(tf.string(from: last.endDate)) (\(dur) min, \(period.count) sessions)")
            for s in period.prefix(15) {
                let act = s.activityType.map { " [\($0)]" } ?? ""
                timelineLines.append("  \(tf.string(from: s.startDate))\(act): \(s.summary)")
            }
            if period.count > 15 {
                timelineLines.append("  ... and \(period.count - 15) more sessions")
            }
            // Show gap to next period
            if i < data.workPeriods.count - 1,
               let nextFirst = data.workPeriods[i + 1].first {
                let gapMins = Int((nextFirst.startTimestamp - last.endTimestamp) / 60)
                if gapMins > 0 {
                    timelineLines.append("  ↳ GAP: \(gapMins) min until next work period (\(tf.string(from: last.endDate)) – \(tf.string(from: nextFirst.startDate)))")
                }
            }
            timelineLines.append("")
        }
        let timeline = timelineLines.isEmpty ? "  (no work periods detected)" : timelineLines.joined(separator: "\n")

        return """
        PERIOD: \(data.formatDay(data.from)) – \(data.formatDay(data.to))
        TOTAL RECORDED TIME: \(data.formattedDuration) across \(data.summaries.count) sessions
        WORK PERIODS: \(data.workPeriods.count) | AVG DURATION: \(String(format: "%.0f", data.avgWorkPeriodMinutes)) min
        FOCUS BLOCKS (≥15 min sustained): \(data.focusBlocks.count)
        APP SWITCHES/HOUR (within work periods): \(String(format: "%.1f", data.switchesPerHour))
        MEDICATION: \(medStr)
        ACTIVITY BREAKDOWN: \(actLines.isEmpty ? "not available" : actLines)

        APP USAGE:
        \(appLines.isEmpty ? "  (no data)" : appLines)

        DETAILED SESSION TIMELINE:
        \(timeline)
        """
    }

    private static func parseNarrative(_ response: String) -> LLMNarrative? {
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
        }
        guard let jsonData = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return nil }

        let focusSessions: [SessionAnalysis] = (json["focus_sessions"] as? [[String: Any]] ?? []).compactMap { item in
            guard let time = item["time"] as? String,
                  let duration = item["duration"] as? String,
                  let work = item["work"] as? String,
                  let quality = item["quality"] as? String else { return nil }
            return SessionAnalysis(time: time, duration: duration, work: work, quality: quality)
        }

        let distractionPeriods: [DistractionPeriod] = (json["distraction_periods"] as? [[String: Any]] ?? []).compactMap { item in
            guard let time = item["time"] as? String,
                  let duration = item["duration"] as? String,
                  let pattern = item["pattern"] as? String else { return nil }
            return DistractionPeriod(time: time, duration: duration, pattern: pattern)
        }

        return LLMNarrative(
            executiveSummary: json["executive_summary"] as? String ?? "",
            focusSessions: focusSessions,
            distractionPeriods: distractionPeriods,
            workSummary: json["work_summary"] as? String ?? "",
            behavioralObservations: json["behavioral_observations"] as? String ?? "",
            medicationNote: json["medication_note"] as? String,
            clinicalNotes: json["clinical_notes"] as? String ?? ""
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
            statsAtAGlance
            rule
            if !data.focusBlocks.isEmpty {
                focusBlocksSection
                rule
            }
            if let n = narrative {
                executiveSummarySection(n)
                rule
                focusSessionsSection(n)
                if !n.distractionPeriods.isEmpty {
                    rule
                    distractionPeriodsSection(n)
                }
                rule
                workSummarySection(n)
                rule
                behavioralSection(n)
                if !n.clinicalNotes.isEmpty {
                    rule
                    clinicalNotesSection(n)
                }
                if let medNote = n.medicationNote {
                    rule
                    medicationNoteSection(medNote)
                }
            }
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

    // MARK: LLM Analytical Sections

    @ViewBuilder
    private func executiveSummarySection(_ n: LLMNarrative) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("EXECUTIVE SUMMARY")
            Text(n.executiveSummary)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func focusSessionsSection(_ n: LLMNarrative) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("FOCUS SESSIONS")
            if n.focusSessions.isEmpty {
                Text("No sustained focus sessions detected in this period.")
                    .font(.system(size: 11)).foregroundStyle(Color(white: 0.45))
            } else {
                ForEach(Array(n.focusSessions.enumerated()), id: \.offset) { _, session in
                    focusSessionRow(session)
                }
            }
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func focusSessionRow(_ s: SessionAnalysis) -> some View {
        let qualityColor: Color = s.quality == "high" ? .green : s.quality == "moderate" ? .orange : .red
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(s.time)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.35))
                Text("·")
                    .foregroundStyle(Color(white: 0.6))
                Text(s.duration)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(white: 0.45))
                Spacer()
                Text(s.quality)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(qualityColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(qualityColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(s.work)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.15))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color(white: 0.975))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func distractionPeriodsSection(_ n: LLMNarrative) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("DISTRACTION & WANDERING PERIODS")
            ForEach(Array(n.distractionPeriods.enumerated()), id: \.offset) { _, period in
                distractionRow(period)
            }
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func distractionRow(_ d: DistractionPeriod) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(d.time)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.35))
                Text("·")
                    .foregroundStyle(Color(white: 0.6))
                Text(d.duration)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(white: 0.45))
            }
            Text(d.pattern)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.25))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func workSummarySection(_ n: LLMNarrative) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("WORK & PRODUCTIVITY ANALYSIS")
            Text(n.workSummary)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.15))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func behavioralSection(_ n: LLMNarrative) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("BEHAVIORAL OBSERVATIONS")
            Text(n.behavioralObservations)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.15))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func clinicalNotesSection(_ n: LLMNarrative) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("CLINICAL NOTES  (for treating physician / therapist)")
            Text(n.clinicalNotes)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.15))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.blue.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.blue.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func medicationNoteSection(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "pill.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.blue)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("MEDICATION NOTE")
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.2))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
