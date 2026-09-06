// About-pagina (E15.4) — geen eigen Figma-frame; geëxtrapoleerd in de
// 15.1-stijl (Setting Row-patroon) conform de werkregel. Functionele
// referentie: v1 UpdatesSection (versie-rij, auto-check-toggle,
// check-knop) + appcast.
//
// Sparkle is in het Avatar2-target nog niet gelinkt (project.yml =
// INFRA-grens; story E01.11 staat op het bord). Tot die landt is de
// check-knop disabled met de versie-rij en links volledig functioneel;
// de auto-check-voorkeur persisteert alvast onder settings2.* zodat de
// Sparkle-port hem direct kan consumeren.

import AvatarUI
import SwiftUI

struct SettingsAboutPage: View {
    /// E13.5 (audit-C1): consumeert dé app-brede Sparkle-updater die
    /// Avatar2App bezit en via Environment doorgeeft — Sparkle verwacht één
    /// SPUUpdater per proces, dus hier nooit meer een eigen instance maken.
    /// De auto-check-voorkeur leeft in Sparkle's eigen store.
    @Environment(UpdateManager.self) private var updater

    private var versionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }

    /// Subtitel onder de "Check now"-rij. Tijdens checking/downloading blijft
    /// de tekst gelijk aan idle: anders wisselt het aantal regels (smalle
    /// vensters wikkelen de idle-tekst) en springt de Links-kaart eronder.
    /// De voortgang zit in het knop-label; alleen echte uitkomsten wisselen.
    private var checkSubtitle: String {
        switch updater.state {
        case .idle, .checking, .downloading, .extracting:
            return "Updates arrive via the Aaavatar update channel"
        case .upToDate:
            return "You're up to date"
        case .available(let version):
            return "Version \(version) is available"
        case .readyToRelaunch(let version):
            return "Version \(version) downloaded — relaunch to install"
        case .error:
            return "Update check failed — try again later"
        case .installFailed(let version, _):
            return "Installing version \(version) failed — see the update card"
        }
    }

    private var checkButtonLabel: String {
        switch updater.state {
        case .checking: return "Checking…"
        case .downloading: return "Downloading…"
        case .extracting: return "Preparing…"
        default: return "Check now"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("About")
                .dsTextStyle(.h1)
                .foregroundStyle(DSColor.Foreground.primary)

            VStack(alignment: .leading, spacing: DSSpacing.gap1) {
                SettingsSectionCard(title: "Updates") {
                    VStack(alignment: .leading, spacing: DSSpacing.gap4) {
                        SettingsRow(
                            title: "Version",
                            subtitle: "Aaavatar"
                        ) {
                            Text(versionLabel)
                                .dsTextStyle(.labelBase)
                                .foregroundStyle(DSColor.Foreground.muted)
                        }
                        SettingsRow(
                            title: "Automatic updates",
                            subtitle: "Check for new versions in the background"
                        ) {
                            DSToggle(isOn: Binding(
                                get: { updater.automaticallyChecksForUpdates },
                                set: { updater.automaticallyChecksForUpdates = $0 }
                            ))
                        }
                        SettingsRow(
                            title: "Check for updates",
                            subtitle: checkSubtitle
                        ) {
                            // E01.11: live op Sparkle. Disabled zolang een
                            // check loopt (canCheckForUpdates = false).
                            if case .readyToRelaunch = updater.state {
                                DSPrimaryButton("Relaunch") {
                                    updater.relaunchAndInstall()
                                }
                            } else if case .available = updater.state {
                                DSPrimaryButton("Install") {
                                    updater.installAvailableUpdate()
                                }
                            } else {
                                DSNeutralButton(checkButtonLabel) {
                                    updater.checkForUpdates()
                                }
                                .disabled(!updater.canCheckForUpdates)
                            }
                        }
                    }
                }
                SettingsSectionCard(title: "Links") {
                    VStack(alignment: .leading, spacing: DSSpacing.gap4) {
                        linkRow(
                            title: "Website",
                            subtitle: "aaavatar.nl",
                            url: AppLinks.website
                        )
                        linkRow(
                            title: "Privacy policy",
                            subtitle: "How Aaavatar handles your photos",
                            url: AppLinks.privacyPolicy
                        )
                    }
                }
            }
            .padding(.top, DSSpacing.gap8)
        }
        .padding(.top, ShellMetrics.settingsPageTopInset)
        .padding(.leading, DSSpacing.gap6)
        .padding(.trailing, DSSpacing.gap6)
    }

    private func linkRow(title: String, subtitle: String, url: URL) -> some View {
        SettingsRow(title: title, subtitle: subtitle) {
            DSIconButton(Image(systemName: "arrow.up.right"), label: "Open \(title)") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
