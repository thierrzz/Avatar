import SwiftUI
import AppKit

/// Paywall presented when a free user (or a Pro user out of credits) taps
/// an Extend Body card. Three tier cards → Stripe Checkout opened in the
/// default browser. Return is handled by the `aaavatar://` URL scheme.
struct ProUpgradeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var busyTier: ProTier?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headline
                    tierGrid
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    footer
                }
                .padding(24)
            }
        }
        .frame(width: 720, height: 520)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(Loc.extendBodyUpgradeTitle)
                .font(.title2.weight(.semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(Color.secondary.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Loc.extendBodyUpgradeHeadline)
                .font(.title3.weight(.semibold))
            Text(Loc.extendBodyUpgradeSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Tiers

    private var tierGrid: some View {
        HStack(alignment: .top, spacing: 12) {
            tierCard(.starter, highlighted: false)
            tierCard(.plus, highlighted: true)    // recommended
            tierCard(.studio, highlighted: false)
        }
    }

    @ViewBuilder
    private func tierCard(_ tier: ProTier, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(tier.displayName)
                    .font(.headline)
                Spacer()
                if highlighted {
                    Text(Loc.extendBodyUpgradePopular)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.tint))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(tier.monthlyPriceEUR)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text(Loc.extendBodyUpgradePerMonth)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(Loc.extendBodyUpgradeCreditsPerMonth(tier.monthlyCredits))
                    .font(.callout)
                    .foregroundStyle(.primary)
            }

            Text(description(for: tier))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button {
                startCheckout(tier)
            } label: {
                HStack {
                    if busyTier == tier {
                        ProgressView().controlSize(.small)
                    }
                    Text(Loc.extendBodyUpgradeCTA)
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(highlighted ? .accentColor : .secondary)
            .disabled(busyTier != nil)
        }
        .padding(16)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 280, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(highlighted ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(highlighted ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: highlighted ? 1.5 : 0.5)
        )
    }

    private func description(for tier: ProTier) -> String {
        switch tier {
        case .starter: return Loc.extendBodyUpgradeStarterDesc
        case .plus:    return Loc.extendBodyUpgradePlusDesc
        case .studio:  return Loc.extendBodyUpgradeStudioDesc
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Loc.extendBodyUpgradeFinePrint)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Link(Loc.termsOfService, destination: URL(string: "https://aaavatar.nl/terms")!)
                Link(Loc.privacyPolicy, destination: URL(string: "https://aaavatar.nl/privacy")!)
            }
            .font(.caption)
        }
    }

    // MARK: Actions

    private func startCheckout(_ tier: ProTier) {
        errorMessage = nil
        busyTier = tier
        Task {
            do {
                let url = try await appState.backend.startCheckout(tier: tier)
                NSWorkspace.shared.open(url)
                // Leave sheet open — the URL scheme handler will refresh
                // ProEntitlement and dismiss via NotificationCenter once the
                // user completes checkout in their browser.
                busyTier = nil
            } catch BackendError.notSignedIn {
                errorMessage = Loc.extendBodyUpgradeSignInFirst
                appState.showSignInPrompt = true
                busyTier = nil
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                busyTier = nil
            }
        }
    }
}
