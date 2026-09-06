// Update-kaart linksonder, bij de sidebar (besluit Thierry 2026-09-02, naar
// het Weeve-voorbeeld): een update wordt nooit stil gedownload of stil
// verborgen. Vier stappen, één kaart:
//   available  → "Install Update" / "Later"
//   downloading→ voortgangspil (+ %) / "Cancel"
//   extracting → spinner
//   ready      → "Relaunch" / "Later" (Sparkle installeert dan bij afsluiten)
//   failed     → reden + "Try again" / "Download" / "Dismiss" (E13.8, besluit
//                Thierry 2026-09-06: een mislukte installatie mag nooit stil
//                verdwijnen)
// Zelfde kaartchrome als DSToast (bg Card, divider-rand, r-2xl, Shadows/Default);
// smaller (300) zodat 'ie in de sidebar-kolom past. Check-fouten (achtergrond)
// horen hier niet: die staan in Settings → About.

import AppKit
import AvatarUI
import SwiftUI

struct UpdateToastView: View {
    let updater: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.gap1) {
            Text(title)
                .dsTextStyle(.labelLarge)
                .foregroundStyle(DSColor.Foreground.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(description)
                .dsTextStyle(.bodySmall)
                .foregroundStyle(DSColor.Foreground.subtle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DSSpacing.gap3) {
                controls
            }
            .padding(.top, DSSpacing.gap3)
        }
        .padding(DSSpacing.gap4)
        .frame(width: 300, alignment: .leading)
        .background(DSColor.Background.card)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.xl2))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.xl2)
                .strokeBorder(DSColor.Foreground.divider, lineWidth: DSBorderWidth.thin)
        )
        .shadow(
            color: DSShadow.default.color,
            radius: DSShadow.default.radius / 2,
            x: DSShadow.default.offset.width,
            y: DSShadow.default.offset.height / 2
        )
        .dsMotion(DSMotion.fast, value: updater.state)
    }

    // MARK: - Copy

    private var title: String {
        switch updater.state {
        case .available(let version): return "Aaavatar \(version) is available"
        case .downloading(let version, _): return "Downloading Aaavatar \(version)"
        case .extracting(let version): return "Preparing Aaavatar \(version)"
        case .readyToRelaunch(let version): return "Aaavatar \(version) is ready"
        case .installFailed(let version, _): return "Aaavatar \(version) couldn't be installed"
        default: return ""
        }
    }

    private var description: String {
        switch updater.state {
        case .available, .downloading:
            return "Install the latest update to stay up to date."
        case .extracting:
            return "Almost there."
        case .readyToRelaunch:
            return "Relaunch to finish installing."
        case .installFailed(_, let message):
            return message
        default:
            return ""
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        switch updater.state {
        case .available:
            DSNeutralButton("Install Update", size: .small) {
                updater.installAvailableUpdate()
            }
            DSGhostButton("Later", size: .small) {
                updater.dismissAvailableUpdate()
            }
        case .downloading(_, let progress):
            progressPill(progress)
            DSGhostButton("Cancel", size: .small) {
                updater.cancelDownload()
            }
        case .extracting:
            HStack(spacing: DSSpacing.gap2) {
                DSProgressView().controlSize(.small)
                Text("Preparing…")
                    .dsTextStyle(.labelBase)
                    .foregroundStyle(DSColor.Foreground.subtle)
            }
        case .readyToRelaunch:
            DSPrimaryButton("Relaunch", size: .small) {
                updater.relaunchAndInstall()
            }
            DSGhostButton("Later", size: .small) {
                updater.dismissAvailableUpdate()
            }
        case .installFailed:
            DSNeutralButton("Try again", size: .small) {
                updater.retryFailedUpdate()
            }
            // Uitweg als Sparkle het echt niet kan (bv. de sandbox-bug van
            // 2.0.0/2.0.1): dezelfde DMG als de website-knop.
            DSGhostButton("Download", size: .small) {
                NSWorkspace.shared.open(AppLinks.latestDownload)
            }
            DSGhostButton("Dismiss", size: .small) {
                updater.dismissFailedUpdate()
            }
        default:
            EmptyView()
        }
    }

    /// Pil met voortgangsbalk + percentage; zonder bekende grootte een
    /// spinner met "Starting…" (Sparkle meldt de lengte pas na de eerste
    /// response).
    @ViewBuilder
    private func progressPill(_ progress: Double?) -> some View {
        HStack(spacing: DSSpacing.gap2) {
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DSColor.Background.neutralStronger)
                        Capsule()
                            .fill(DSColor.Action.primary)
                            .frame(width: max(6, geo.size.width * min(max(progress, 0), 1)))
                    }
                }
                .frame(height: 6)
                Text("\(Int((progress * 100).rounded()))%")
                    .dsTextStyle(.labelBase)
                    .foregroundStyle(DSColor.Foreground.primary)
                    .monospacedDigit()
            } else {
                DSProgressView().controlSize(.small)
                Text("Starting…")
                    .dsTextStyle(.labelBase)
                    .foregroundStyle(DSColor.Foreground.subtle)
            }
        }
        .padding(.horizontal, DSSpacing.gap3)
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(DSColor.Background.neutral, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progress.map { "Downloading, \(Int($0 * 100)) percent" } ?? "Starting download")
    }
}
