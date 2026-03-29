import AppKit
import SwiftUI

// MARK: - Tab Enums (file-scope so controller can reference them)

enum NeuraMindMainTab: String, CaseIterable {
    case dailyAssistant = "Daily Assistant"
    case timeTracker    = "Time Tracker"
    case workPatterns   = "Work Patterns"
}

enum DailySubTab: String, CaseIterable {
    case goodMorning = "Good Morning"
    case windDown    = "Wind Down"
    case chat        = "Chat"
}

// MARK: - Panel State (shared between controller and views)

/// Holds the active tab selection so the controller can deep-link to a specific sub-tab.
@MainActor
final class NeuraMindPanelState: ObservableObject {
    @Published var mainTab: NeuraMindMainTab = .dailyAssistant
    @Published var subTab: DailySubTab      = .goodMorning
}

// MARK: - Panel Controller

/// Manages the floating NeuraMind panel: Daily Assistant + Work Patterns.
/// Follows the same pattern as EnrichmentPanelController.
@MainActor
final class NeuraMindPanelController {
    private var panel: NSPanel?
    let state = NeuraMindPanelState()

    private let morningEngine: MorningPlanEngine
    private let windDownEngine: WindDownEngine
    private let conversationEngine: ConversationEngine
    private let emailFetcher: EmailContextFetcher
    private let storageManager: StorageManager

    init(
        morningEngine: MorningPlanEngine,
        windDownEngine: WindDownEngine,
        conversationEngine: ConversationEngine,
        emailFetcher: EmailContextFetcher,
        storageManager: StorageManager
    ) {
        self.morningEngine = morningEngine
        self.windDownEngine = windDownEngine
        self.conversationEngine = conversationEngine
        self.emailFetcher = emailFetcher
        self.storageManager = storageManager
    }

    func toggle() {
        if let panel = panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func showMorning() {
        state.mainTab = .dailyAssistant
        state.subTab  = .goodMorning
        show()
    }

    func showWindDown() {
        state.mainTab = .dailyAssistant
        state.subTab  = .windDown
        show()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func show() {
        if panel == nil { createPanel() }
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createPanel() {
        let contentView = NeuraMindPanelView(
            state: state,
            morningEngine: morningEngine,
            windDownEngine: windDownEngine,
            conversationEngine: conversationEngine,
            emailFetcher: emailFetcher,
            storageManager: storageManager
        )

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 580),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "NeuraMind"
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.contentView = NSHostingView(rootView: contentView)
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = false
        self.panel = p
    }
}

// MARK: - Root View

struct NeuraMindPanelView: View {
    @ObservedObject var state: NeuraMindPanelState
    @ObservedObject var morningEngine: MorningPlanEngine
    @ObservedObject var windDownEngine: WindDownEngine
    @ObservedObject var conversationEngine: ConversationEngine
    @ObservedObject var emailFetcher: EmailContextFetcher
    var storageManager: StorageManager

    var body: some View {
        VStack(spacing: 0) {
            // Glass tab bar
            HStack(spacing: 2) {
                ForEach(NeuraMindMainTab.allCases, id: \.self) { tab in
                    GlassTabButton(
                        title: tab.rawValue,
                        icon: tabIcon(tab),
                        isSelected: state.mainTab == tab
                    ) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            state.mainTab = tab
                        }
                    }
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Group {
                switch state.mainTab {
                case .dailyAssistant:
                    DailyAssistantTab(
                        state: state,
                        morningEngine: morningEngine,
                        windDownEngine: windDownEngine,
                        conversationEngine: conversationEngine,
                        emailFetcher: emailFetcher
                    )
                case .timeTracker:
                    TimeTrackerView(engine: TimeTrackerEngine.shared)
                case .workPatterns:
                    WorkPatternsTab(storageManager: storageManager)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 580, minHeight: 480)
    }

    private func tabIcon(_ tab: NeuraMindMainTab) -> String {
        switch tab {
        case .dailyAssistant: return "brain.head.profile"
        case .timeTracker:    return "clock.fill"
        case .workPatterns:   return "chart.bar.fill"
        }
    }
}

// MARK: - Daily Assistant Tab

struct DailyAssistantTab: View {
    @ObservedObject var state: NeuraMindPanelState
    @ObservedObject var morningEngine: MorningPlanEngine
    @ObservedObject var windDownEngine: WindDownEngine
    @ObservedObject var conversationEngine: ConversationEngine
    @ObservedObject var emailFetcher: EmailContextFetcher

    var body: some View {
        VStack(spacing: 0) {
            // Glass sub-tab picker
            HStack(spacing: 2) {
                ForEach(DailySubTab.allCases, id: \.self) { tab in
                    GlassTabButton(
                        title: tab.rawValue,
                        icon: subTabIcon(tab),
                        isSelected: state.subTab == tab
                    ) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            state.subTab = tab
                        }
                    }
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.3))
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Group {
                switch state.subTab {
                case .goodMorning:
                    GoodMorningView(engine: morningEngine, emailFetcher: emailFetcher)
                case .windDown:
                    WindDownView(engine: windDownEngine)
                case .chat:
                    ChatView(engine: conversationEngine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func subTabIcon(_ tab: DailySubTab) -> String {
        switch tab {
        case .goodMorning: return "sun.max.fill"
        case .windDown:    return "moon.fill"
        case .chat:        return "bubble.left.and.bubble.right"
        }
    }
}

// MARK: - Good Morning View

struct GoodMorningView: View {
    @ObservedObject var engine: MorningPlanEngine
    @ObservedObject var emailFetcher: EmailContextFetcher

    @State private var goalsText: String = ""
    @FocusState private var isGoalsFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "sun.max.fill").foregroundStyle(.yellow)
                    Text("Good Morning").font(.title3.bold())
                    Spacer()
                    Text(todayLabel).font(.caption).foregroundStyle(.secondary)
                }

                // Goals input
                VStack(alignment: .leading, spacing: 6) {
                    Text("What do you want to accomplish today?")
                        .font(.subheadline).foregroundStyle(.secondary)

                    TextEditor(text: $goalsText)
                        .focused($isGoalsFocused)
                        .font(.body)
                        .frame(minHeight: 80, maxHeight: 140)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [.white.opacity(0.12), .white.opacity(0.04)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                }

                // Email context badge (if loaded)
                if let emailContext = emailFetcher.context {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Email/calendar context", systemImage: "envelope")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(emailContext)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if let emailError = emailFetcher.error {
                    Text(emailError).font(.caption).foregroundStyle(.secondary)
                }

                // Actions
                HStack(spacing: 10) {
                    Button(action: planDay) {
                        if engine.isProcessing {
                            ProgressView().controlSize(.small).padding(.trailing, 4)
                            Text("Planning...")
                        } else {
                            Image(systemName: "sparkles")
                            Text("Plan My Day")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        engine.isProcessing ||
                        goalsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .keyboardShortcut(.return, modifiers: .command)

                    Spacer()

                    // Pull email context (only shown if a provider is configured)
                    let provider = EmailProvider.current
                    if provider != .none {
                        Button(action: { Task { await emailFetcher.fetch(provider: provider) } }) {
                            if emailFetcher.isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Pull \(provider.displayName)", systemImage: "envelope.badge")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(emailFetcher.isLoading)
                    }
                }

                if let err = engine.error {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }

                // Generated plan
                if let plan = engine.currentPlan {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.yellow)
                            Text("Your Day Plan").font(.subheadline.bold())
                            Spacer()
                            Button(action: { copyText(plan) }) {
                                Image(systemName: "doc.on.doc").font(.caption)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Copy to clipboard")
                        }
                        Text(stripMarkdown(plan))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [.white.opacity(0.15), .white.opacity(0.05)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 0.5
                                    )
                            )
                    )
                }
            }
            .padding(20)
        }
        .onAppear {
            goalsText = engine.todayGoals
            isGoalsFocused = true
        }
    }

    private var todayLabel: String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: Date())
    }

    private func planDay() {
        Task { await engine.generatePlan(goals: goalsText, emailContext: emailFetcher.context) }
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Wind Down View

struct WindDownView: View {
    @ObservedObject var engine: WindDownEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "moon.fill").foregroundStyle(.indigo)
                    Text("Wind Down").font(.title3.bold())
                    Spacer()
                }

                Text("Review your day and set an intention for tomorrow.")
                    .font(.subheadline).foregroundStyle(.secondary)

                HStack {
                    Button(action: { Task { await engine.generateRecap() } }) {
                        if engine.isProcessing {
                            ProgressView().controlSize(.small).padding(.trailing, 4)
                            Text("Reviewing...")
                        } else {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("Review My Day")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.isProcessing)
                    .keyboardShortcut(.return, modifiers: .command)

                    Spacer()
                }

                if let err = engine.error {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }

                if let recap = engine.currentRecap {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "moon.stars")
                                .foregroundStyle(.indigo)
                            Text("Day Recap").font(.subheadline.bold())
                            Spacer()
                            Button(action: { copyText(recap) }) {
                                Image(systemName: "doc.on.doc").font(.caption)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Copy to clipboard")
                        }
                        Text(stripMarkdown(recap))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [.white.opacity(0.15), .white.opacity(0.05)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 0.5
                                    )
                            )
                    )
                }
            }
            .padding(20)
        }
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Chat View

struct ChatView: View {
    @ObservedObject var engine: ConversationEngine
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if engine.messages.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.largeTitle).foregroundStyle(.secondary)
                                Text("Ask anything about your day")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 50)
                        }

                        ForEach(engine.messages) { msg in
                            ChatBubble(message: msg).id(msg.id)
                        }

                        if engine.isProcessing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Thinking...").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.leading, 12)
                            .id("loading")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: engine.messages.count) { _, _ in
                    withAnimation {
                        if let last = engine.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: engine.isProcessing) { _, processing in
                    if processing {
                        withAnimation { proxy.scrollTo("loading", anchor: .bottom) }
                    }
                }
            }

            if engine.isAtLimit {
                Text("10-turn limit reached. Clear the conversation to start fresh.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }

            Divider()

            // Glass input row
            HStack(spacing: 8) {
                TextField("Ask about your day...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .lineLimit(1...4)
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.12), .white.opacity(0.04)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.5
                            )
                    )
                    .onSubmit { sendIfPossible() }

                VStack(spacing: 6) {
                    Button(action: sendIfPossible) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? .blue : Color(nsColor: .tertiaryLabelColor))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)

                    if !engine.messages.isEmpty {
                        Button(action: { engine.reset() }) {
                            Image(systemName: "trash")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear conversation")
                    }
                }
            }
            .padding(12)

            if let err = engine.error {
                Text(err)
                    .font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .onAppear { isInputFocused = true }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !engine.isProcessing
            && !engine.isAtLimit
    }

    private func sendIfPossible() {
        let msg = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, !engine.isProcessing, !engine.isAtLimit else { return }
        inputText = ""
        Task { await engine.send(message: msg) }
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ConversationMessage

    var body: some View {
        let isUser = message.role == "user"
        let displayText = isUser ? message.content : stripMarkdown(message.content)

        HStack(alignment: .top, spacing: 8) {
            if !isUser {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11))
                    .foregroundStyle(.blue.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.blue.opacity(0.08)))
                    .padding(.top, 2)
            }

            Text(displayText)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isUser ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.ultraThinMaterial))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: isUser
                                            ? [Color.accentColor.opacity(0.15), Color.accentColor.opacity(0.05)]
                                            : [.white.opacity(0.12), .white.opacity(0.04)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                )
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if isUser {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.secondary.opacity(0.08)))
                    .padding(.top, 2)
            }
        }
    }
}

// MARK: - Work Patterns Tab

struct WorkPatternsTab: View {
    var storageManager: StorageManager

    enum TimeRangeOption: String, CaseIterable {
        case today     = "Today"
        case yesterday = "Yesterday"
        case last7Days = "Last 7 Days"
    }

    enum TimeOfDay: String, CaseIterable {
        case all       = "All Day"
        case morning   = "Morning (6am–12pm)"
        case afternoon = "Afternoon (12pm–6pm)"
        case evening   = "Evening (6pm+)"
    }

    enum MedicationFilter: String, CaseIterable {
        case all          = "All"
        case onMedication = "On Meds"
        case offMedication = "Off Meds"
    }

    enum SubTab: String, CaseIterable {
        case browse  = "Browse"
        case compare = "Compare"
    }

    @State private var subTab: SubTab = .browse
    @State private var isExporting: Bool = false
    @State private var timeRange: TimeRangeOption = .today
    @State private var timeOfDay: TimeOfDay = .all
    @State private var selectedApp: String = ""
    @State private var medicationFilter: MedicationFilter = .all
    @State private var summaries: [SummaryRecord] = []
    @State private var availableApps: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Browse / Compare sub-tab picker
            Picker("", selection: $subTab) {
                ForEach(SubTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)

            Divider()

            if subTab == .compare {
                MedicationCompareView(storageManager: storageManager)
            } else {
                browseContent
            }
        }
    }

    private var browseContent: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 8) {
                Picker("", selection: $timeRange) {
                    ForEach(TimeRangeOption.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 110)

                Picker("", selection: $timeOfDay) {
                    ForEach(TimeOfDay.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 148)

                Picker("", selection: $selectedApp) {
                    Text("All Apps").tag("")
                    ForEach(availableApps, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 120)

                Picker("", selection: $medicationFilter) {
                    ForEach(MedicationFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 90)

                Spacer()

                Text("\(summaries.count) entries")
                    .font(.caption).foregroundStyle(.secondary)

                Button(action: { Task { await exportReport() } }) {
                    if isExporting {
                        ProgressView().controlSize(.mini).padding(.trailing, 2)
                        Text("Generating…").font(.caption)
                    } else {
                        Label("Export PDF", systemImage: "arrow.down.doc").font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(summaries.isEmpty || isExporting)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            Divider()

            if summaries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No summaries in this range")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(summaries, id: \.startTimestamp) { summary in
                        SummaryRow(summary: summary)
                    }
                }
                .listStyle(.plain)
            }
        }
        .onAppear { reload() }
        .onChange(of: timeRange)         { _, _ in reload() }
        .onChange(of: timeOfDay)         { _, _ in reload() }
        .onChange(of: selectedApp)       { _, _ in reload() }
        .onChange(of: medicationFilter)  { _, _ in reload() }
    }

    private func exportReport() async {
        isExporting = true
        let (start, end) = currentDateRange()
        let data = ReportData(from: start, to: end, summaries: summaries)
        await ReportEngine.export(data: data)
        isExporting = false
    }

    /// Returns the (start, end) dates matching the current timeRange selection.
    private func currentDateRange() -> (Date, Date) {
        let now = Date()
        let cal = Calendar.current
        switch timeRange {
        case .today:
            return (cal.startOfDay(for: now), now)
        case .yesterday:
            let y = cal.date(byAdding: .day, value: -1, to: now)!
            return (cal.startOfDay(for: y), cal.startOfDay(for: now))
        case .last7Days:
            return (cal.date(byAdding: .day, value: -7, to: now)!, now)
        }
    }

    private func reload() {
        let cal = Calendar.current
        let (start, end) = currentDateRange()

        // Fetch with optional app filter
        let appFilter = selectedApp.isEmpty ? nil : selectedApp
        var all = (try? storageManager.summaries(from: start, to: end, limit: 300, appName: appFilter)) ?? []

        // Apply time-of-day filter in-process
        if timeOfDay != .all {
            all = all.filter { s in
                let h = cal.component(.hour, from: s.startDate)
                switch timeOfDay {
                case .morning:   return h >= 6 && h < 12
                case .afternoon: return h >= 12 && h < 18
                case .evening:   return h >= 18
                case .all:       return true
                }
            }
        }

        // Apply medication filter in-process
        switch medicationFilter {
        case .onMedication:  all = all.filter { $0.medicationActive }
        case .offMedication: all = all.filter { !$0.medicationActive }
        case .all:           break
        }

        summaries = all

        // Rebuild the app dropdown from the unfiltered range
        let allRaw = (try? storageManager.summaries(from: start, to: end, limit: 500)) ?? []
        availableApps = Array(Set(allRaw.flatMap { $0.decodedAppNames })).sorted()
    }
}

// MARK: - Summary Row

struct SummaryRow: View {
    let summary: SummaryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(timeRangeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                ForEach(summary.decodedAppNames.prefix(3), id: \.self) { app in
                    Text(app)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Spacer()

                if let activity = summary.activityType {
                    Text(activity)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(badgeColor(activity).opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            Text(summary.summary)
                .font(.subheadline)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var timeRangeLabel: String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return "\(f.string(from: summary.startDate))–\(f.string(from: summary.endDate))"
    }

    private func badgeColor(_ type: String) -> Color {
        switch type {
        case "coding":        return .blue
        case "research":      return .orange
        case "communication": return .green
        case "admin":         return .purple
        default:              return .gray
        }
    }
}

// MARK: - Glass Tab Button

struct GlassTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(tabBackground)
            .shadow(color: isSelected ? .black.opacity(0.06) : .clear, radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var tabBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        } else if isHovered {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(0.03))
        } else {
            Color.clear
        }
    }
}

// MARK: - Markdown Stripping

/// Strips common markdown formatting artifacts from LLM output so it renders
/// as clean plain text in the UI (no ** bold **, # headers, backticks, etc.).
func stripMarkdown(_ text: String) -> String {
    var s = text
    // Bold: **text** or __text__
    s = s.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: "__(.+?)__", with: "$1", options: .regularExpression)
    // Italic: *text* (after bold is already stripped)
    s = s.replacingOccurrences(of: "(?<=\\s|^)\\*(.+?)\\*(?=\\s|$|[.,;:!?])", with: "$1", options: .regularExpression)
    // Headers: # ## ### at line start
    s = s.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
    // Inline code backticks
    s = s.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
    // Horizontal rules
    s = s.replacingOccurrences(of: "(?m)^[\\-\\*_]{3,}$", with: "", options: .regularExpression)
    return s
}
