import SwiftUI

struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SidebarUpdateCard: View {
    @Environment(UpdateManager.self) private var updater

    var body: some View {
        if case let .readyToRelaunch(version) = updater.state {
            VStack(spacing: 10) {
                Image("AppLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.primary)

                VStack(spacing: 2) {
                    Text(Loc.updatedTo(version))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(Loc.relaunchToApply)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button(Loc.relaunch) {
                    updater.relaunchAndInstall()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
