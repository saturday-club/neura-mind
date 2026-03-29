import AppKit
import SwiftUI

// MARK: - Actions

/// Clean action buttons for pause, enrichment, debug, and activity graph.
struct ActionsView: View {
    @ObservedObject var captureEngine: CaptureEngine
    var onOpenEnrichment: () -> Void
    var onOpenDailyAssistant: () -> Void
    var onOpenDebug: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            MenuActionButton(
                title: captureEngine.isRunning ? "Pause Capture" : "Resume Capture",
                icon: captureEngine.isRunning ? "pause.fill" : "play.fill",
                shortcut: "P",
                modifiers: "Shift+Cmd"
            ) {
                if captureEngine.isRunning {
                    captureEngine.stop()
                } else {
                    captureEngine.start()
                }
            }

            MenuActionButton(
                title: "Plan & Summary",
                icon: "brain.head.profile",
                shortcut: "N",
                modifiers: "Shift+Cmd"
            ) {
                onOpenDailyAssistant()
                NSApp.activate(ignoringOtherApps: true)
            }

            MenuActionButton(
                title: "Enrich Prompt",
                icon: "sparkles",
                shortcut: "Space",
                modifiers: "Shift+Cmd"
            ) {
                onOpenEnrichment()
                NSApp.activate(ignoringOtherApps: true)
            }

            MenuActionButton(
                title: "Database Debug",
                icon: "ladybug",
                shortcut: "D",
                modifiers: "Opt+Cmd"
            ) {
                onOpenDebug()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

// MARK: - Menu Action Button

/// A single action row styled like a native macOS menu item with hover highlight.
struct MenuActionButton: View {
    let title: String
    let icon: String
    let shortcut: String?
    let modifiers: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .frame(width: 16, alignment: .center)

                Text(title)
                    .font(.system(size: 13))

                Spacer()

                if let shortcut = shortcut, let modifiers = modifiers {
                    Text("\(modifiers)+\(shortcut)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Quit Button

/// Quit action at the bottom of the panel.
struct QuitButton: View {
    @State private var isHovered = false

    var body: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "power")
                    .font(.system(size: 12))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .frame(width: 16, alignment: .center)

                Text("Quit NeuraMind")
                    .font(.system(size: 13))

                Spacer()

                Text("Cmd+Q")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
