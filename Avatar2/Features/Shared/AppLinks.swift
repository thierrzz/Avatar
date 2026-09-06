// E49.2: één bron voor de publieke aaavatar.nl-links. De privacy-URL stond op
// drie plekken hardcoded en was in Settings/About `/privacy` (404) i.p.v. het
// live `/privacy-policy` — één constante voorkomt dat ze uit elkaar lopen.

import Foundation

enum AppLinks {
    static let website = URL(string: "https://aaavatar.nl")!
    static let termsOfService = URL(string: "https://aaavatar.nl/terms-of-service")!
    static let privacyPolicy = URL(string: "https://aaavatar.nl/privacy-policy")!
    /// Dezelfde stabiele DMG-URL als de download-knop op aaavatar.nl
    /// (release-v2.sh publiceert elke release óók onder exact deze naam, zie
    /// docs/eng/RELEASE-2.0.md). Uitweg in de update-kaart als Sparkle faalt.
    static let latestDownload = URL(string: "https://github.com/Square-One-Official/Avatar/releases/latest/download/Aaavatar.dmg")!
}
