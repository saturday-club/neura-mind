import AppKit
import SwiftUI

// MARK: - Tab Enums (file-scope so controller can reference them)

enum NeuraMindMainTab: String, CaseIterable {
    case dailyAssistant = "Daily Assistant"
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
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 580),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "NeuraMind"
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
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
            Picker("", selection: $state.mainTab) {
                ForEach(NeuraMindMainTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

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
                case .workPatterns:
                    WorkPatternsTab(storageManager: storageManager)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 580, minHeight: 480)
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
            Picker("", selection: $state.subTab) {
                ForEach(DailySubTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

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
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
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
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Your Day Plan").font(.subheadline.bold())
                            Spacer()
                            Button(action: { copyText(plan) }) {
                                Image(systemName: "doc.on.doc").font(.caption)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Copy to clipboard")
                        }
                        Text(plan)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Day Recap").font(.subheadline.bold())
                            Spacer()
                            Button(action: { copyText(recap) }) {
                                Image(systemName: "doc.on.doc").font(.caption)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Copy to clipboard")
                        }
                        Text(recap)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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

            // Input row
            HStack(spacing: 8) {
                TextField("Ask about your day...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .lineLimit(1...4)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
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
        HStack(alignment: .top, spacing: 8) {
            if message.role == "assistant" {
                Image(systemName: "brain.head.profile")
                    .font(.caption).foregroundStyle(.blue)
                    .frame(width: 20).padding(.top, 3)
            }

            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
                .padding(10)
                .background(
                    message.role == "user"
                        ? Color.accentColor.opacity(0.1)
                        : Color(nsColor: .controlBackgroundColor)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)

            if message.role == "user" {
                Image(systemName: "person.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 20).padding(.top, 3)
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
        case morning   = "Morning (6–12)"
        case afternoon = "Afternoon (12–18)"
        case evening   = "Evening (18+)"
    }

    @State private var timeRange: TimeRangeOption = .today
    @State private var timeOfDay: TimeOfDay = .all
    @State private var selectedApp: String = ""
    @State private var summaries: [SummaryRecord] = []
    @State private var availableApps: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 10) {
                Picker("", selection: $timeRange) {
                    ForEach(TimeRangeOption.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 120)

                Picker("", selection: $timeOfDay) {
                    ForEach(TimeOfDay.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 155)

                Picker("", selection: $selectedApp) {
                    Text("All Apps").tag("")
                    ForEach(availableApps, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 130)

                Spacer()

                Text("\(summaries.count) entries")
                    .font(.caption).foregroundStyle(.secondary)
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
        .onChange(of: timeRange)   { _, _ in reload() }
        .onChange(of: timeOfDay)   { _, _ in reload() }
        .onChange(of: selectedApp) { _, _ in reload() }
    }

    private func reload() {
        let now = Date()
        let cal = Calendar.current

        let (start, end): (Date, Date) = {
            switch timeRange {
            case .today:
                return (cal.startOfDay(for: now), now)
            case .yesterday:
                let y = cal.date(byAdding: .day, value: -1, to: now)!
                return (cal.startOfDay(for: y), cal.startOfDay(for: now))
            case .last7Days:
                return (cal.date(byAdding: .day, value: -7, to: now)!, now)
            }
        }()

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
