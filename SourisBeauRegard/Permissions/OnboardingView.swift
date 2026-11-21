import SwiftUI

/// Écran d'accueil : état de chaque autorisation et accès direct au bon panneau des Réglages Système.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let permissions = appState.permissions
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "eye")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Souris beau regard").font(.title2.bold())
                    Text("Regardez un élément pour le viser, appuyez sur une touche pour cliquer.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Autorisations nécessaires").font(.headline)

            ForEach(Permission.allCases) { permission in
                PermissionRow(permission: permission,
                              status: permissions.status(of: permission))
            }

            Text("Après un nouveau build, si l'Accessibilité semble perdue : vérifiez que l'équipe de signature n'a pas changé, ou lancez `tccutil reset Accessibility fr.sourisbeauregard.SourisBeauRegard` puis réautorisez.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                if !permissions.allRequiredGranted {
                    Label("Caméra et Accessibilité sont indispensables.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Continuer") { appState.closeOnboarding() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 440)
        .onAppear { permissions.refresh() }
    }
}

private struct PermissionRow: View {
    @Environment(AppState.self) private var appState
    let permission: Permission
    let status: PermissionStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.systemImage)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(permission.title).font(.body.bold())
                    if !permission.isRequired {
                        Text("facultative").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(permission.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                StatusBadge(status: status)
                if status != .granted {
                    HStack {
                        Button("Demander") {
                            Task { await appState.permissions.request(permission) }
                        }
                        Button("Réglages…") {
                            appState.permissions.openSettings(for: permission)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusBadge: View {
    let status: PermissionStatus

    var body: some View {
        Label(status.label, systemImage: icon)
            .font(.caption.bold())
            .foregroundStyle(color)
    }

    private var icon: String {
        switch status {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "questionmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .orange
        }
    }
}
