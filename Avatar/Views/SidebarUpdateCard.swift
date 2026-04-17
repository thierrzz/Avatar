import SwiftUI

struct SidebarUpdateCard: View {
    @Environment(UpdateManager.self) private var updater

    var body: some View {
        if case let .readyToRelaunch(version) = updater.state {
            VStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.tint)

                VStack(spacing: 2) {
                    Text(Loc.updatedTo(version))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(Loc.restartToApply)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button(Loc.restart) {
                    updater.relaunchAndInstall()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
