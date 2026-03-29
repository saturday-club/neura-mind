import SwiftUI

/// Lightweight onboarding view shown only when permissions are not yet granted.
struct OnboardingView: View {
    @ObservedObject var permissionManager: PermissionManager
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                Text("Welcome to NeuraMind")
                    .font(.title.bold())

                Text("NeuraMind needs accessibility permission to read focused window titles and app information.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Divider()

            PermissionRow(
                icon: "accessibility",
                title: "Accessibility",
                description: "Read focused window titles and app information.",
                isGranted: permissionManager.accessibilityGranted,
                onRequest: { permissionManager.requestAccessibility() },
                onOpenSettings: { permissionManager.openAccessibilitySettings() }
            )

            Divider()

            HStack(spacing: 12) {
                Button("Refresh Status") {
                    permissionManager.refreshStatus()
                }
                .buttonStyle(.bordered)

                Button("Continue") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
            }

            Text("You can grant permissions later via System Settings → Privacy & Security → Accessibility.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 520)
    }
}

/// A single permission row showing status and action buttons.
private struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(isGranted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.headline)

                    Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(isGranted ? .green : .red)
                        .font(.caption)
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isGranted {
                Button("Grant") { onRequest() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Settings") { onOpenSettings() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 8)
    }
}
