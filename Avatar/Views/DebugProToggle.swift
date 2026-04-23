import SwiftUI

/// Developer toggle — flips the local Pro entitlement without hitting
/// Stripe/Supabase. Persisted in UserDefaults and ignored by
/// `AppState.refreshEntitlement()` so it isn't clobbered on window
/// appear / after checkout / after a 402. Pair with `DEV_UNLIMITED_EMAILS`
/// on the backend to let Extend Body run end-to-end without credits.
/// Remove before shipping.
struct DebugProToggle: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var bindable = appState
        HStack(spacing: 8) {
            Image(systemName: "ladybug.fill")
                .foregroundStyle(.orange)
            Toggle(isOn: $bindable.isDebugPro) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("DEBUG: Pro")
                        .font(.system(size: 11, weight: .semibold))
                    Text(appState.isDebugPro ? "\(appState.proEntitlement.credits) credits" : "free tier")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.orange.opacity(0.25)), alignment: .top)
    }
}
