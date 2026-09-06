# E13 — Release-voorbereiding

Team: **INFRA**

Laatste epic (13.0 uitgezonderd: doorlopende deploy-port, kan eerder).

## 13.0 — Backend-port v2-main → main (productie-deploy)
- status: done
- owner: INFRA
- blockedBy: —
- DoD: backend-typecheck groen op main; v2-main-kant ongewijzigd
- Context: Vercel (avatars-api, rootDirectory=backend) deployt `main`, niet v2-main. (Story toegevoegd op besluit Thierry 2026-06-12.)

Backend-wijzigingen die op v2-main landen naar `main` porten zodat ze op productie komen.
Wachten inmiddels: het recovery-endpoint `/v1/auth/send-recovery-email` (E01.7 — staat als
niet-gecommit v1-werk in de hoofd-checkout) én MODEL_REGISTRY/`model_override` (E01.10).
Tot een port gedraaid is testen agents in-app tegen een Vercel-preview-deploy van de branch
(genoteerd in E09.1 en E15.5).

**Result:** Port gedraaid 2026-06-12: branch v1/backend-port-2026-06-12 met send-recovery-email (E01.7, stond sinds 19 mei ongecommit) + de zeven E01.10-backendbestanden byte-identiek aan v2-main (diff-geverifieerd), ff-merge naar main (b27cdd5..3bc2a76) en gepusht → Vercel-productie-deploy; tsc-typecheck + models-smoke groen op main; productie-smoke OK (/v1/auth/send-recovery-email: 400 invalid_email waar eerst 404; /v1/colorize zonder auth: 401). Bewust niet mee: backend/sql/012 (device_grants account_link) — hoort bij account-link-werk dat nergens in tracked code bestaat, geen dependency van het endpoint; blijft als los punt in de hoofd-checkout. v2-main-kant ongewijzigd.

## 13.1 — Apart updatekanaal
- status: done (code + tooling) — **prod-deploy + eerste release zijn gated (Thierry), zie GO-NO-GO-2.0.md §4**
- owner: INFRA (2026-08-01, branch v2/e13-release)
- blockedBy: —
- DoD: beide targets bouwen, tests groen

Eigen appcast voor 2.0-beta; v1-gebruikers merken niets.

**Result (2026-08-01):**
- **Eigen feed:** Avatar2 → `https://api.aaavatar.nl/appcast-v2.xml`; v1 blijft
  op `/appcast.xml`. Backend: [appcast-v2.ts](../backend/api/appcast-v2.ts) +
  rewrite in vercel.json; de serveer-logica (cache/etag/304) is gedeeld met het
  v1-kanaal via [appcastFeed.ts](../backend/lib/appcastFeed.ts) i.p.v.
  gekopieerd. Canon in de repo-root: `appcast-v2.xml` (leeg channel = geldig,
  Sparkle meldt "geen update"). `tsc --noEmit` groen.
- **Eigen versielijn:** het Avatar2-target erfde v1's 1.2.1/18 uit de
  root-settings — een v1-release-bump zou het v2-kanaal stil hernummeren. Nu
  target-overrides 2.0.0 / build **100** (ruim boven élk v1-buildnummer, zodat
  een dev-binary die ooit op het gedeelde feed stond nooit een "downgrade"
  ziet). Beide geverifieerd via `xcodebuild -showBuildSettings`.
- **release.sh (v1) ontscherpt:** de globale `sed`-bump verving élke
  MARKETING_VERSION-match — die zou de nieuwe v2-overrides meepakken. Nu een
  first-match-only bump (python).
- **[release-v2.sh](../scripts/release-v2.sh):** volledige v2-flow (scheme
  Avatar2, "Aaavatar 2.app", `Aaavatar-2-<v>.dmg`, tag `v<v>`), bumpt alléén
  het Avatar2-blok (assert op precies 2 matches — faalt hard bij een derde),
  en publiceerde als GitHub-**prerelease** — verplicht zolang de website-link
  `releases/latest/download/Aaavatar.dmg` v1 moest blijven serveren.
  **Bijstelling 2026-09-04 (besluit Thierry):** 2.0 is de publieke release;
  het script publiceert nu `--latest` mét een stabiele kopie `Aaavatar.dmg`,
  zodat de website-link zonder Framer-edit 2.0 serveert. `PRERELEASE=1`
  staged een build (Sparkle-e2e eerst), `gh release edit --prerelease=false
  --latest` zet 'm live. Zelfde EdDSA-sleutelpaar als v1 (besluit E01.11),
  dus geen nieuw key-beheer.
- **Gated (Thierry):** de backend-port/deploy (prod geeft op `/appcast-v2.xml`
  nu 404) en de eerste beta-release (signing/notarisatie). Stappen in
  GO-NO-GO-2.0.md §4.

## 13.2 — Migratiepad
- status: done (code + tests) — **e2e met een echte v1-bibliotheek is gated (Thierry), zie GO-NO-GO-2.0.md §5**
- owner: INFRA (2026-08-01, branch v2/e13-release)
- blockedBy: —
- DoD: beide targets bouwen, tests groen

v1-library → Portrait2-store (read-only import).

**Result (2026-08-01):** de migratie rijdt op v1's bestáánde bibliotheek-export
(`LibraryArchive`, zip met manifest.json + cutout-PNG's) — niet op v1's live
store. Dat is geen gemakzucht maar een sandbox-feit: beide apps zijn
gesandboxt onder verschillende bundle-ids, dus v2 kán v1's container niet stil
lezen; de gebruiker exporteert in v1 en kiest het bestand in v2
(user-selected-read-entitlement). Read-only aan de v1-kant per constructie.
- **[V1LibraryArchive](../AvatarKit/Sources/AvatarKit/Services/V1LibraryArchive.swift)**
  (AvatarKit): tolerante lezer van het schema-1-manifest (ISO-8601), weigert
  níeuwere schema's expliciet, telt records-zonder-cutout i.p.v. ze stil te
  snoeien. 5 tests op fixtures in het échte zip-formaat.
- **[V1LibraryImporter](../Avatar2/Features/Settings/V1LibraryImporter.swift)**
  (Avatar2): mapt naar Portrait2 in één "Aaavatar 1"-map, met de échte
  v1-datums (dus oude portretten landen in Earlier, niet bovenop Recent).
  Idempotent via nieuw veld `Portrait2.v1ImportID` (lichtgewicht migratie,
  nil-default): her-import dupliceert niets en overschrijft nóóit een portret
  dat in v2 al bewerkt is. 6 tests, incl. dat v2-eigen portretten onzichtbaar
  zijn voor de dedup.
- **Mapping-besluiten:** cutout+naam+datums mee; originele foto níét (zit niet
  in v1's back-up — alleen een bookmark; v2's bestaande legacy-pad verbergt dan
  de Original-achtergrondkeuze); v1-tags → `role` (zichtbaar en hernoembaar —
  weggooien is onherstelbaar); v1's transform/adjust níét (ander canvasmodel,
  half-kloppende geometrie oogt kapotter dan een nette her-layout). Geen
  backend-calls, geen credits: de cutout ís al vrijstaand.
- **Instap:** Settings → Preferences → "Import from Aaavatar 1" →
  "Import backup…" (NSOpenPanel, .zip); resultaat/fout in de rij-subtitle.

## 13.3 — Go/no-go-checklist
- status: done (checklist staat; de ⬜-items zijn per definitie Thierry's go-besluit)
- owner: INFRA (2026-08-01, branch v2/e13-release)
- blockedBy: —
- DoD: beide targets bouwen, tests groen

Bakeoff-besluiten verwerkt, beide apps groen, onboarding+main flow compleet, Stripe-identiteitstest
(E01.7) geslaagd.

Checklist-items uit E01.7 (INFRA, 2026-06-12):
- [ ] E2E mismatch-pad testen tegen productie. (Deploy-helft is klaar: /v1/auth/send-recovery-email
      staat sinds de E13.0-port van 2026-06-12 op productie.) → opgenomen in
      GO-NO-GO-2.0.md §6.

**Result (2026-08-01):** **[GO-NO-GO-2.0.md](GO-NO-GO-2.0.md)** — negen
secties, elk item ✅ (met hoe-geverifieerd) of ⬜ (met eigenaar). Vandaag
geverifieerd: volledige DoD groen (incl. beide guards), prod-surface-smoke
(8 CMS-endpoints 200, 6 betaalde POST-routes 401, appcast-v1 200),
`bannersEnabled` default uit, alle bakeoff-besluiten verwerkt op **E32.0 na**
(nooit gedraaid — expliciet go-besluit: bakeoff vóór launch of nano-banana-
baseline accepteren). De zes resterende ⬜-stappen staan onderaan het document
als minimale go-lijst: backend-deployronde, eerste release + Sparkle-e2e,
migratie-e2e, Stripe-e2e, visuele passes, asset-besluit.

## 13.4 — Backend-port ronde 2 (v2-main → main) — KLAARGEZET
- status: done (productie-deploy 2026-06-14) — DB-migraties blijven wacht-op-Thierry
- owner: FEAT (AI-agent, marathon — voorbereiding; uitvoering door Thierry)
- blockedBy: — (klaar; alleen de gated uitvoering rest)
- DoD: de nieuwe cloud-routes draaien op productie; prod-smoke groen
- Context: vervolg op E13.0. De cloud-routes uit deze marathon (E09.2 prod-`/v1/stylize` +
  style/hair/clothes-intents, E10.3 `/v1/upscale`, E15.6 `generation_model`, E15.5
  `is_dev_unlimited`, E14.3 fill_body 2 cr) staan op v2-main maar nog niet op productie.

**Plan/voorbereiding (gedaan):**
1. Gecureerde port-manifest geschreven: **`backend/PORT-2026-06-14.md`** — exacte bestandenlijst,
   de val (send-recovery-email.ts niet verwijderen), DB-migratie 013 (gated), env/Replicate-checks,
   deploy-stappen + prod-smoke.
2. Verse Vercel-**preview** gedeployd vanaf v2-main (alle nieuwe routes):
   **https://avatars-r5jafqkdn-square-one-69d6814b.vercel.app**.

**WACHT-OP-THIERRY:** (a) de productie-deploy naar api.aaavatar.nl (stappen in PORT-2026-06-14.md;
push NIET autonoom gedaan) en (b) de DB-migratie 013 tegen de live database. Doe bij voorkeur
eerst de E01.15-e2e tegen de preview (kleding-acceptatiecriterium) vóór go-live.

**Result:** Productie-deploy gedaan 2026-06-14 (op expliciete go van Thierry). Gecureerde port van
`main` (3bc2a76) → `b27b31b`: alle v2-cloud-routes (stylize style/hair/clothes-intents, /v1/upscale,
generation_model, account.is_dev_unlimited, fill_body 1→2) + de E17-messaging-endpoints; `send-
recovery-email.ts` behouden. `npm run typecheck` groen; gepusht naar origin/main → Vercel-prod;
prod-smoke OK (/v1/stylize + /v1/upscale 401, /v1/messages 405, /v1/cutout + send-recovery intact).
DB-migraties 013 + 014 door Thierry in Supabase gedraaid (2026-06-14). **fill_body 1→2 credits is
bewust** en geldt nu ook voor live v1. Rest: Payload `messages`-tabellen via avatar-admin-deploy
(push:true) — apart, wacht-op-Thierry.

## 13.5 — Sparkle app-breed initialiseren + achtergrondcheck bij launch
- status: done
- team: INFRA
- blockedBy: —

Voortgekomen uit de CTO-audit (`plan/AUDIT-CTO-2026-07-01.md`, bevinding C1).
**Wat:** `UpdateManager` (en dus `SPUUpdater.start()`) wordt uitsluitend
geconstrueerd als `@State` van `SettingsAboutPage.swift:19` — bij app-launch bestaat
er géén updater, dus de "Automatic updates"-toggle belooft iets dat alleen gebeurt
terwijl het About-scherm zichtbaar is. `checkForUpdatesInBackground()` heeft nul
call sites (dood). Elk About-bezoek maakt bovendien een **nieuwe** `SPUUpdater` aan
op dezelfde bundle — Sparkle verwacht er één per proces; een tweede `start()` kan
falen (belandt stil in `state = .error`). Voor een DMG-only app is dit het enige
update-kanaal → release-kritisch.
**Voorstel:** één app-brede `UpdateManager` (bv. `@State` in `Avatar2App`, doorgeven
via Environment); bij launch `checkForUpdatesInBackground()` aanroepen. About
consumeert dezelfde instance i.p.v. een eigen.
**DoD:** beide targets bouwen; een fresh launch triggert een achtergrond-update-check
zonder dat About geopend hoeft te worden; tests groen; Result-regel.

**Result:** Gedaan 2026-07-02 (branch v2/e13-5-sparkle). `Avatar2App` bezit nu dé
app-brede `UpdateManager` (`@State`, gebouwd in `init`) en geeft hem via
`.environment(updates)` door; `SettingsAboutPage` consumeert die via
`@Environment(UpdateManager.self)` — geen per-view `SPUUpdater` meer (één per proces,
zoals Sparkle eist). Bij launch roept een `.task` `checkForUpdatesInBackgroundAtLaunch()`
aan: eenmalig per proces (guard tegen venster-heropen), respecteert de "Automatic
updates"-toggle, en zet observeerbaar bewijs (`lastBackgroundCheckRequest`) + een
`.notice`-logbreadcrumb ("Launch background update check requested (E13.5)",
subsystem `nl.squareone.aaavatar2`). De echte `SPUUpdater` zit achter een nieuw
`UpdaterEngine`-seam (SparkleUpdaterEngine in prod, no-op in de unit-test-host zodat
`xcodebuild test` nooit een echte updater/netwerkcheck start, fake in tests). Nieuw:
`Avatar2Tests/UpdateManagerTests.swift` (6 tests: één engine-start, launch-check
precies één keer, toggle-uit → geen check, doorgeef-gedrag, canCheckForUpdates-mirror).
Geverifieerd: beide targets bouwen; Avatar2-tests, AvatarKit (89) en AvatarUI (37)
groen; fresh launch van de Debug-build logt de launch-check zonder dat About open was
(via `/usr/bin/log stream`).

**Bijstelling (2026-09-02, besluit Thierry):** de handmatige
`checkForUpdatesInBackgroundAtLaunch()` is weer verwijderd. Sparkle plant de
launch-check zelf zodra `SUEnableAutomaticChecks` aan staat; onze extra call viel
in Sparkle's eigen start-cyclus (`sessionInProgress == YES` in het log) en werd
stil genegeerd — dubbel werk zonder effect. Daarnaast: een gevonden update wordt
niet meer stil gedownload maar aangeboden in een kaart linksonder bij de sidebar
(`UpdateToastView`: Install Update/Later → voortgang + Cancel → Relaunch/Later;
"Later" op een gedownloade update laat Sparkle bij afsluiten installeren).
`SUEnableDownloaderService` is uit Avatar2's Info.plist gehaald (hing onder de
Xcode-debugger; met `network.client` overbodig). Tests: launch-check-tests
vervangen door kaart-mapping-tests.


## 13.6 — AuthSessionFileStorage: token-write faalt bij vergrendeld scherm [INFRA]
- status: done
- owner: INFRA (2026-07-12, branch v2/e13-13.6)
- team: INFRA
- blockedBy: —

Gevonden tijdens de E53.2-DoD (2026-07-12, ~02:10): `AuthSessionFileStorage.store`
schrijft met `[.atomic, .completeFileProtection]`; zodra het scherm vergrendeld is
(`CGSSessionScreenIsLocked`) faalt élke zulke write met EPERM ("mktemp failed …
errno 1", regel 37) — live gereproduceerd met een minimale `Data.write`:
`.atomic` slaagt, `.atomic + .completeFileProtection` faalt bij lock, en dezelfde
5 `AuthSessionStorageTests` die om 01:36/02:04 groen waren falen om 02:10 (scherm
op slot) in élke worktree, óók buiten de sandbox.
**Gevolg in productie:** een Supabase-token-refresh terwijl de Mac vergrendeld is
(app draait door) kan zijn sessie niet persisteren → verklaart mogelijk de
sessie-herstel-klachten die 921b1e7 (Pro grace-period) aan de symptoomkant dempt.
**Voorstel:** file-protection-klasse heroverwegen voor dit pad — bv. schrijf met
`.atomic` + `posixPermissions 0o600` (zoals nu al ná de write gezet wordt) en laat
`.completeFileProtection` vallen (macOS-keybag-semantiek ≠ iOS), óf vang de fout
en herkans na unlock (NSWorkspace.screensDidWakeNotification). Testflank: de 5
AuthSessionStorageTests draaien alleen betrouwbaar met ontgrendeld scherm —
documenteer dat in de test of maak de write-optie injecteerbaar.
**DoD:** beide targets bouwen; AuthSessionStorageTests groen mét en zonder
vergrendeld scherm (of expliciet gedocumenteerde lock-gate); Result-regel.
**Result:** ✅ `.completeFileProtection` uit `AuthSessionFileStorage.store` (alleen nog `.atomic` + de bestaande 0600/0700-permissies) — confidentialiteit komt al van de AES-GCM-envelop met Keychain-sleutel, de protection-class voegde niets toe en blokkeerde writes bij dichte keybag; rationale als comment op de write. ✅ Geverifieerd ónder vergrendeld scherm (`CGSSessionScreenIsLocked=true`): AuthSessionStorageTests 6/6 groen waar vóór de fix 5/6 faalden met EPERM — de lock-conditie zelf was het bewijs. ✅ build-v2.sh volledig groen (idem vergrendeld). ⚠ v1 heeft dezelfde bug (`Avatar/Services/FileAuthStorage.swift:56`) — niet aangeraakt (v1 bevroren, geen SHARED-story); apart besluit Thierry of dit een SHARED-fix waard is.

## 13.7 — Directe import van de Aaavatar 1-bibliotheek op dezelfde Mac [INFRA+FEAT]
- status: done
- owner: INFRA+FEAT (2026-09-04, branch v2/e13-13.7)
- team: INFRA (AvatarKit-reader + entitlement) · FEAT (Settings / first-launch)
- blockedBy: —
- DoD: beide targets bouwen, tests groen, Result-regel

**Waarom.** 13.2 werkt alleen als de gebruiker in v1 een back-up exporteert vóór
de drag-install; wie dat overslaat ziet in 2.0 een lege bibliotheek. De
v1-container blijft echter intact op schijf
(`~/Library/Containers/nl.avatar.app/Data/Library/Application Support/default.store`
+ `.default_SUPPORT/_EXTERNAL_DATA/`). Deze story leest die store **read-only**
vanuit 2.0 en voedt de bestaande importer (dedup via `Portrait2.v1ImportID`
blijft gelden). Bonus: de live store bevat óók de originele foto's — v1 slaat
de bytes op (`ImportFlow.swift:1031`), ondanks de "bookmark"-comment in
`Portrait.swift` — die de zip-back-up níét bevat.

**Scope.**
- AvatarKit: `V1StoreReader` — kopieert store + `-wal` + `-shm` naar tmp,
  opent de kopie via SQLite3, leest `ZPORTRAIT` (ZID = 16 uuid-bytes, ZNAME,
  ZTAGS, ZCREATEDAT/ZUPDATEDAT = Core Data-referentiedatums, blobs met de
  external-storage-codering: `0x01`+inline of `0x02`+UUID-bestandsnaam in
  `_EXTERNAL_DATA`; gewone Data-kolommen zonder prefix — empirisch geverifieerd
  met een SwiftData-fixture op 2026-09-04). Levert `V1LibraryArchive.Library`
  met `PortraitPayload.originalImage` als nieuw optioneel veld.
- Avatar2: sandbox-uitzondering (read-only, home-relative
  `/Library/Containers/nl.avatar.app/`) + `NSAppDataUsageDescription`
  (macOS 15+ vraagt eenmalig "would like to access data from other apps");
  Settings → Migration krijgt "Import from this Mac"; eerste-startpad: hint
  wanneer een v1-bibliotheek gevonden is en er nog niets geïmporteerd is.
- 13.2 (zip) blijft de fallback voor een andere Mac.

**Result (2026-09-05):** ✅ `V1StoreReader` (AvatarKit): kopie van store + `-wal` +
`-shm` naar tmp → SQLite-lees van `ZPORTRAIT` (`SELECT *`, mapping op kolomnaam);
external-storage-codering (0x01 inline / 0x02 + UUID-bestandsnaam in
`_EXTERNAL_DATA`) empirisch vastgesteld met een SwiftData-fixture en zo ook getest —
7 tests, incl. byte-gelijkheid van de v1-bestanden vóór/ná lezen en een
path-traversal-guard. ✅ `PortraitPayload.originalImage` (nieuw, optioneel) →
`Portrait2.originalData`; importer-test erbij (Avatar2Tests 7/7). ✅ Avatar2:
read-only temporary-exception op `~/Library/Containers/nl.avatar.app/Data/Library/
Application Support/` + `NSAppDataUsageDescription`; Settings → Migration: "Import
from this Mac" (bestaande back-up-rij heet nu "Import from a backup file");
first-use-state: regel "Coming from Aaavatar 1? Import your library" — **niet in
Figma 4008:7050**, bewuste toevoeging als één regel in de stijl van "or choose a
file" (Thierry kan 'm schrappen) → import, nieuwste portret op canvas, bon-toast;
fout → de canvas-melding van een mislukte drop. ✅ **Échte-data-test (GO-NO-GO §5):**
`TEST_RUNNER_V1_REAL_STORE=1 xcodebuild … test -only-testing:Avatar2Tests/V1StoreRealDataTests`
las Thierry's echte v1-container door de gesandboxte test-host: 1 portret
("Imported", cutout 8186 B, origineel 4259 B), import 1, her-import 0 + "1 already
present" → de entitlement werkt; op deze Mac (macOS 26) hield geen TCC-prompt de run
op. ⚠ Die v1-store is een dev-bibliotheek met één testportret — een grote échte
bibliotheek is nog niet gezien. ✅ build-v2.sh volledig groen (EXIT=0). Niet in
scope (zelfde besluit als 13.2): v1-achtergronden en transforms. Announcement
(GO-NO-GO §7): sql/021 op prod geverifieerd; concept in avatar-admin gevuld
(titel/slug/body), Max App Version + CTA + Published At + Save door Thierry gedaan
(2026-09-05). **Uitgerold in Aaavatar 2.0.1 (build 103), 2026-09-05 00:36** via
`release-v2.sh` (genotariseerd + gestapled, EdDSA-item bovenaan appcast-v2, GitHub
`latest`, website-link serveert de 2.0.1-DMG, prod-appcast byte-gelijk aan de canon,
main = v2-main = d65c4e8). Sparkle-e2e op een 2.0.0-install: Thierry.

## 13.8 — Sparkle-install faalt vanuit de sandbox (mach-lookup-entitlements) [INFRA]

- status: done — 2.0.2 (build 104) live 2026-09-06; sql/023 + main-push + CMS-bericht nog door Thierry
- owner: INFRA
- branch: v2-main (hotfix, 2026-09-06)

**Probleem (Thierry, 2026-09-06, 2.0.0 build 102 → 2.0.1):** kaart "Install
Update" → download → installeren → kaart verdwijnt → niets; de app blijft 2.0.0.
Log: `sandboxd: Sandbox: Aaavatar(19147) deny(1) mach-lookup
nl.squareone.aaavatar2-spks`, Sparkle: "failed to probe status service … The
remote port connection was invalidated from the updater. If your application is
sandboxed, please ensure Installer Connection & Status entitlements are correctly
set up", Autoupdate: "Timeout: installation data was never received". Sparkle
termineert en herstart de app wél (daarom lijkt er "iets" te gebeuren), maar de
installer heeft de update nooit gekregen. Beide DMG-downloads (11:33 en 11:34)
staan nog in `~/Library/Containers/nl.squareone.aaavatar2/…/PersistentDownloads/`.
De fout zelf wordt bewust niet in de kaart getoond (alleen Settings → About), dus
voor de gebruiker "verdwijnt" de kaart gewoon.

**Oorzaak:** Sparkle 2 vanuit de sandbox heeft naast
`SUEnableInstallerLauncherService` ook twee mach-lookup-uitzonderingen nodig
(`<bundle-id>-spki` en `-spks`, zie
https://sparkle-project.org/documentation/sandboxing/). Die ontbraken in
`Avatar2.entitlements` (en ontbreken óók in v1's `Avatar.entitlements` — v1 is
bevroren, niet aangeraakt; v1-installs updaten naar 2.0 toch via de DMG).

**Fix:** `com.apple.security.temporary-exception.mach-lookup.global-name` =
[`nl.squareone.aaavatar2-spks`, `nl.squareone.aaavatar2-spki`] in
`Avatar2/Avatar2.entitlements`.

**Feedback bij falen (Thierry, 2026-09-06: "can't just close the toast and do
nothing"):** nieuwe state `UpdateState.installFailed(version:message:)` — alleen
voor fouten ná een klik op Install/Relaunch (`installRequested` in de
user-driver); achtergrond-checkfouten blijven `.error` (About-only, geen nag).
Kaart: "Aaavatar <ver> couldn't be installed" + Sparkle's
`localizedDescription` én `localizedFailureReason` (daar staat de échte reden),
knoppen "Try again" (verse check-cyclus) / "Download" (`AppLinks.latestDownload`,
dezelfde DMG als de website-knop — de uitweg voor 2.0.0/2.0.1) / "Dismiss".
`settleAfterDismiss` laat `.error`/`.installFailed` nu staan (Sparkle roept
`dismissUpdateInstallation` direct ná de fout-acknowledgement; voorheen werd
óók de About-fouttekst daardoor meteen weer `idle`). About: "Installing version
<ver> failed — see the update card". Kaart-variant staat niet in Figma: opgezet
in de stijl van de bestaande vier stappen (zelfde chrome, small-knoppen).

**Bereik van de 2.0.0/2.0.1-installs (Thierry, 2026-09-06: "ask them to install
the DMG and offer a link via the toast"):** die builds zijn niet meer te wijzigen,
maar lezen wél `/v1/messages` bij elke launch en tonen het bericht als
`DSMessageSheet` met een CTA-knop die een URL opent. De Messages-collectie had
alleen `minAppVersion`; nu ook `targeting.maxAppVersion` (admin-veld, backend-
filter `withinMaxVersion` in `api/v1/messages.ts`, `sql/023`, test), zodat het
bericht 2.0.2+ nooit bereikt. Uitrol (gated, Thierry): sql/023 in de Supabase
SQL-editor → main-push (admin-deploy) → `vercel --prod` avatars-api → bericht in
admin: cohort all, maxAppVersion `2.0.1`, frequency everySignInUntilDismissed,
CTA "Download Aaavatar 2.0.2" → `https://github.com/Square-One-Official/Avatar/releases/latest/download/Aaavatar.dmg`
(= `AppLinks.latestDownload`), body: sleep de DMG naar Applications, bibliotheek
blijft. Pas publiceren ná de 2.0.2-release, anders wijst de link nog naar 2.0.1.

**Consequentie (besluit Thierry nodig):** de entitlement zit in de *draaiende*
app, niet in de update. 2.0.0- en 2.0.1-installs kunnen dus nooit via Sparkle
naar 2.0.2; die moeten éénmalig handmatig de DMG opnieuw installeren (drag naar
/Applications, bibliotheek blijft — zelfde bundle-id/container). Vanaf 2.0.2
werkt Sparkle wel. Voorstel: 2.0.2 (build 104) uitbrengen + korte melding via de
CMS-announcement (`maxAppVersion` 2.0.1) met de download-link.

**Result (2026-09-06):** ✅ mach-lookup-uitzonderingen `-spks`/`-spki` in
`Avatar2.entitlements`, geverifieerd in de gesigneerde build (`codesign -d
--entitlements`). ✅ Mislukte installatie ná Install/Relaunch toont nu een kaart
met reden + Try again / Download / Dismiss (`UpdateState.installFailed`); check-
fouten blijven About-only; `.error`/`.installFailed` overleven Sparkle's
`dismissUpdateInstallation`. ✅ build-v2.sh volledig groen (EXIT=0, "alles groen";
eigen DerivedData `build/dd-e138` omdat een parallelle sessie `build/dd` gebruikte),
Avatar2Tests incl. nieuwe kaart-tests. ⚠ Niet gecommit/gereleased: 2.0.2 (build
104) via `release-v2.sh 2.0.2 104` + CMS-announcement voor 2.0.0/2.0.1-installs
(handmatige DMG-herinstallatie éénmalig nodig) = besluit Thierry. De e2e van het
Sparkle-pad zelf kan pas met een geïnstalleerde 2.0.2 → 2.0.3.

**Uitgerold (2026-09-06 13:30):** ✅ `release-v2.sh 2.0.2 104` vanuit een schone
tijdelijke worktree (v2-main had een parallelle sessie met dirty Shell-bestanden +
een untracked Swift-bestand dat anders mee was gecompileerd): archive → Developer
ID-export → DMG → notarisatie Accepted → staple → EdDSA → appcast-v2 (item 2.0.2/104
bovenaan, mirror byte-gelijk) → tag v2.0.2 op 2491310 → GitHub-release latest
(`Aaavatar-2.0.2.dmg` + stabiele `Aaavatar.dmg`, 11183299 B; website-link serveert
'm). Entitlements in het gearchiveerde Release-product geverifieerd (-spks/-spki).
v2-main ff naar 2491310 + gepusht; avatars-api via `vercel --prod` gedeployd —
`api.aaavatar.nl/appcast-v2.xml` serveert 2.0.2. ⏳ Thierry: sql/023 in de
Supabase SQL-editor → `main` ff naar 2491310 + push (admin-deploy met het
maxAppVersion-veld) → CMS-bericht (maxAppVersion 2.0.1, CTA naar de DMG) →
eigen Mac handmatig naar 2.0.2. Sparkle-e2e pas mogelijk bij 2.0.2 → 2.0.3.

