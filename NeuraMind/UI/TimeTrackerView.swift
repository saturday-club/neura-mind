import SwiftUI

// MARK: - Data Model

struct TaskSession: Codable, Sendable {
    let startedAt: Date
    var endedAt: Date?

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

struct TrackedTask: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var sessions: [TaskSession]
    let createdAt: Date

    var totalDuration: TimeInterval {
        sessions.reduce(0) { $0 + $1.duration }
    }

    var isRunning: Bool {
        sessions.last?.endedAt == nil
    }

    var todayDuration: TimeInterval {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return sessions.filter {
            $0.startedAt >= startOfDay || ($0.endedAt ?? Date()) >= startOfDay
        }.reduce(0) { total, session in
            let effectiveStart = max(session.startedAt, startOfDay)
            let effectiveEnd = session.endedAt ?? Date()
            return total + max(0, effectiveEnd.timeIntervalSince(effectiveStart))
        }
    }
}

// MARK: - Engine

@MainActor
final class TimeTrackerEngine: ObservableObject {
    static let shared = TimeTrackerEngine()

    @Published var tasks: [TrackedTask] = []
    @Published var activeTaskID: UUID?
    @Published var tick: Date = Date()

    private var timer: Timer?
    private let storageKey = "neuramind.timeTracker.tasks"

    private init() {
        load()
        if let running = tasks.first(where: { $0.isRunning }) {
            activeTaskID = running.id
            startTick()
        }
    }

    func addTask(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = TrackedTask(
            id: UUID(), name: trimmed, sessions: [], createdAt: Date()
        )
        tasks.insert(task, at: 0)
        save()
    }

    func startTask(id: UUID) {
        // Stop any currently running task first
        if let activeID = activeTaskID, activeID != id {
            stopTask(id: activeID)
        }
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].sessions.append(TaskSession(startedAt: Date(), endedAt: nil))
        activeTaskID = id
        startTick()
        save()
    }

    func stopTask(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }),
              let lastIdx = tasks[idx].sessions.indices.last,
              tasks[idx].sessions[lastIdx].endedAt == nil else { return }
        tasks[idx].sessions[lastIdx].endedAt = Date()
        if activeTaskID == id {
            activeTaskID = nil
            stopTick()
        }
        save()
    }

    func toggleTask(id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        if task.isRunning { stopTask(id: id) } else { startTask(id: id) }
    }

    func deleteTask(id: UUID) {
        if activeTaskID == id { stopTask(id: id) }
        tasks.removeAll { $0.id == id }
        save()
    }

    var todayTotal: TimeInterval {
        tasks.reduce(0) { $0 + $1.todayDuration }
    }

    var productivityLabel: String {
        let total = todayTotal
        if total < 60 { return "Just getting started" }
        if total < 1800 { return "Building momentum" }
        if total < 3600 { return "Good focus session" }
        if total < 7200 { return "Strong productivity" }
        return "Deep work mode"
    }

    // MARK: - Timer

    private func startTick() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick = Date() }
        }
    }

    private func stopTick() {
        if activeTaskID == nil { timer?.invalidate(); timer = nil }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([TrackedTask].self, from: data)
        else { return }
        tasks = decoded
    }
}

// MARK: - Time Tracker View

struct TimeTrackerView: View {
    @ObservedObject var engine: TimeTrackerEngine
    @State private var newTaskName = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            todayHeader
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            addTaskRow
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider().opacity(0.2).padding(.horizontal, 12)

            if engine.tasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .onAppear { isInputFocused = true }
    }

    // MARK: - Subviews

    private var todayHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue.opacity(0.8))
                    Text("Time Tracker")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                let _ = engine.tick
                Text(engine.productivityLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                let _ = engine.tick
                Text(formatDuration(engine.todayTotal))
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                Text("today")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.18), .white.opacity(0.05)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )
        )
    }

    private var addTaskRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.blue.opacity(0.7))

            TextField("What are you working on?", text: $newTaskName)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .font(.system(size: 13))
                .onSubmit { addTask() }

            if !newTaskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: addTask) {
                    Text("Start")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.blue))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                )
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("Add a task and hit play")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Track how long you spend on each task")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(engine.tasks) { task in
                    TaskRow(task: task, engine: engine)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Actions

    private func addTask() {
        let name = newTaskName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        engine.addTask(name: name)
        if let first = engine.tasks.first {
            engine.startTask(id: first.id)
        }
        newTaskName = ""
    }
}

// MARK: - Task Row

struct TaskRow: View {
    let task: TrackedTask
    @ObservedObject var engine: TimeTrackerEngine
    @State private var isHovered = false

    var body: some View {
        let isActive = task.isRunning
        let _ = engine.tick

        HStack(spacing: 10) {
            // Play/Pause button
            Button { engine.toggleTask(id: task.id) } label: {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.orange.opacity(0.12) : Color.blue.opacity(0.08))
                        .frame(width: 32, height: 32)
                    Image(systemName: isActive ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? .orange : .blue)
                }
            }
            .buttonStyle(.plain)

            // Task info
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(task.sessions.count) session\(task.sessions.count == 1 ? "" : "s")")
                    if isActive {
                        Circle().fill(.orange).frame(width: 4, height: 4)
                        Text("tracking")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }

            Spacer()

            // Duration
            Text(formatDuration(task.totalDuration))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(isActive ? .primary : .secondary)

            // Delete
            if isHovered && !isActive {
                Button { engine.deleteTask(id: task.id) } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isActive
                        ? AnyShapeStyle(Color.blue.opacity(0.04))
                        : AnyShapeStyle(isHovered ? Color.white.opacity(0.03) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isActive
                                ? Color.blue.opacity(0.15)
                                : (isHovered ? Color.white.opacity(0.08) : Color.clear),
                            lineWidth: 0.5
                        )
                )
        )
        .animation(.easeOut(duration: 0.15), value: isActive)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Helpers

func formatDuration(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}
