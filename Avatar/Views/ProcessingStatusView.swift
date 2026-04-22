import SwiftUI

/// Loader card that rotates through playful status messages while a photo
/// is being processed. Each message has its own dwell time, so punchlines
/// linger and the whole sequence doesn't feel like a fixed loop restarting.
struct ProcessingStatusView: View {
    @Environment(AppState.self) private var appState
    @State private var index = 0

    private var messages: [String] {
        switch appState.processingKind {
        case .upscale: return Loc.upscaleStatuses
        case .generic: return Loc.processingStatuses
        }
    }

    /// Per-message dwell times. Varying the cadence masks the loop —
    /// punchlines ("that's a lot of hair…") get an extra beat, transitions
    /// stay snappy. Cycled modulo count for long waits. The upscale kind
    /// gets its own table because its punchline sits in a different slot.
    private static let genericDwellTimes: [TimeInterval] = [
        2.4,  // Warming up the scissors…
        2.4,  // Removing the background…
        2.2,  // Touching up the hair…
        3.2,  // Wow, that's a lot of hair…   ← punchline, linger
        2.4,  // Sharpening the details…
        2.6,  // Counting every pixel…
        2.4,  // Polishing the edges…
        3.0,  // Consulting the stylist…     ← linger
        3.4,  // Having second thoughts…     ← linger
        2.6,  // Almost there, promise…
    ]

    private static let upscaleDwellTimes: [TimeInterval] = [
        2.4,  // Summoning extra pixels…
        2.4,  // Zooming in on the details…
        2.6,  // Teaching pixels to multiply…
        3.2,  // Wow, that's a lot of pixels…  ← punchline, linger
        2.4,  // Sharpening every edge…
        2.4,  // Smoothing out the jaggies…
        2.6,  // Restoring fine textures…
        3.0,  // Asking each pixel twice…     ← linger
        2.6,  // Polishing up close…
        2.8,  // Almost there, promise…
    ]

    private var dwellTimes: [TimeInterval] {
        switch appState.processingKind {
        case .upscale: return Self.upscaleDwellTimes
        case .generic: return Self.genericDwellTimes
        }
    }

    private var currentDwell: TimeInterval {
        let table = dwellTimes
        return table[index % table.count]
    }

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(messages[index % max(messages.count, 1)])
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .id(index)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity.combined(with: .offset(y: -6))
                ))
        }
        .frame(minWidth: 220)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: index) {
            let nanos = UInt64(currentDwell * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                index += 1
            }
        }
    }
}
