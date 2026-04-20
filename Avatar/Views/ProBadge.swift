import SwiftUI

/// Compact "PRO" pill used to mark premium features in the sidebar.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.3)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(.tint))
            .accessibilityHidden(true)
    }
}

#Preview {
    ProBadge()
        .padding()
}
