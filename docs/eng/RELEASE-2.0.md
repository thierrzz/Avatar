# Aaavatar 2.x — release & auto-updates (runbook)

Het product heet voor gebruikers gewoon **Aaavatar** (`Aaavatar.app`, bundle-id
`nl.squareone.aaavatar2`; besluit Thierry 2026-09-04). Een drag-install vervangt
daarmee Aaavatar 1 in /Applications — de v1-bibliotheek blijft in v1's container.

Hoe een 2.0-release gebouwd, getekend, genotariseerd en gepubliceerd wordt, en
waarom het kanaal zo in elkaar zit. Bron van waarheid voor de stappen is
[`scripts/release-v2.sh`](../../scripts/release-v2.sh); dit document legt de
volgorde en de redenen vast zodat een release ook uitvoerbaar is door iemand
die het script nog nooit gedraaid heeft. v1 (`Avatar`-target, `release.sh`,
`appcast.xml`) is bevroren en staat hier bewust buiten.

## Artefacten

| Artefact | Gemaakt door | Doel | Waar |
|---|---|---|---|
| `Aaavatar-<ver>.dmg` | `create-dmg` in `release-v2.sh` (stap 5), genotariseerd + gestapled | Download én Sparkle-enclosure | GitHub-release `v<ver>` (asset) |
| `Aaavatar.dmg` | Kopie van bovenstaande (stap 10) | Stabiele bestandsnaam — dít lost `releases/latest/download/Aaavatar.dmg` (website) op | Zelfde GitHub-release |
| `docs/releases/RELEASE-NOTES-<ver>.md` | Mens, vóór de run | GitHub-release-body (`--notes-file`) | Repo, gecommit |
| `appcast-v2.xml` | `release-v2.sh` (stap 9), nieuwste item bovenaan | Canon van het Sparkle-feed | Repo-root, gecommit |
| `backend/api/_appcast-v2.xml` | `cp` van de canon (stap 9) | Wat prod serveert | Repo, gecommit, gedeployd met avatars-api |
| Feed-URL | [`backend/api/appcast-v2.ts`](../../backend/api/appcast-v2.ts) + rewrite in [`backend/vercel.json`](../../backend/vercel.json) | `SUFeedURL` in de app | `https://api.aaavatar.nl/appcast-v2.xml` |
| Tag `v<ver>` | `gh release create` (stap 10) | Download-URL in het appcast-item | GitHub, als **latest** (of staged als prerelease met `PRERELEASE=1`) |

```
project.yml (Avatar2-blok) ─bump─► xcodegen ─► xcodebuild archive ─► export (Developer ID)
        │
        └─► create-dmg ─► notarytool ─► stapler ─► sign_update (EdDSA)
                                                      │
                     appcast-v2.xml ◄── item bovenaan ─┘
                            │
                            ├─cp─► backend/api/_appcast-v2.xml
                            │
                     gh release create v<ver> --latest  (DMG + Aaavatar.dmg; PRERELEASE=1 = staged)
                            │
                     git commit (project.yml, pbxproj, Info.plist, beide appcasts)
                            │
                     main ff'en + pushen (= Vercel-deploy) ─► curl api.aaavatar.nl/appcast-v2.xml | grep <ver>
                            │
                     (staged) gh release edit v<ver> --prerelease=false --latest

 bestaande 2.x-installs:  Sparkle → api.aaavatar.nl/appcast-v2.xml → GitHub-asset Aaavatar-<ver>.dmg
 website-downloads:       releases/latest/download/Aaavatar.dmg → nieuwste niet-prerelease
 v1-installs:             pollen /appcast.xml en zien 2.0 nooit (andere bundle-id);
                          horen van 2.0 via een CMS-announcement met maxAppVersion
```

## Waarom deze vorm

- **Eigen feed naast v1.** v1-installs zijn gepind op `/appcast.xml`; 2.0
  praat tegen `/appcast-v2.xml`. Zo krijgt een v1-gebruiker nooit ongevraagd
  een 2.0 aangeboden (E13.1). Beide feeds delen de serveer-logica in
  [`backend/lib/appcastFeed.ts`](../../backend/lib/appcastFeed.ts).
- **Feed op het eigen domein, niet GitHub raw.** `api.aaavatar.nl` is
  TLS-gepind in de app; het appcast is daarmee onderdeel van dezelfde
  trust-root als de rest van de backend. De DMG-assets zelf staan wél op
  GitHub Releases.
- **2.0 ís de publieke release; de website-link verandert niet.** De website
  linkt `releases/latest/download/Aaavatar.dmg`; GitHub's "latest" is de
  nieuwste níet-prerelease. Sinds 2026-09-04 (besluit Thierry) publiceert
  `release-v2.sh` daarom een stabiele kopie onder exact die naam en de
  release als `--latest`. Tot die datum waren 2.0-releases verplicht
  prerelease om de v1-link te beschermen; dat is voorbij. `PRERELEASE=1`
  bestaat nog om een build eerst te stagen (Sparkle-e2e vóór de site 'm
  serveert) en daarna met `gh release edit v<ver> --prerelease=false
  --latest` live te zetten.
- **v1 → 2.0 is geen Sparkle-update.** Andere bundle-id
  (`nl.avatar.app` vs `nl.squareone.aaavatar2`) én gepinde feed: Sparkle
  installeert nooit een bundle met een andere id. Bestaande v1-gebruikers
  krijgen een CMS-announcement (veld `maxAppVersion`, bv. `1.99`) met de
  download-link en de Import-backup-route; 2.0-installs zien dat bericht
  niet. Sinds E13.7 hoeft de back-up niet meer vóór de install: 2.0 leest
  de achtergebleven v1-container read-only (Settings → Migration → "Import
  from this Mac", of de link in de first-use-state) via een read-only
  sandbox-uitzondering in `Avatar2.entitlements`; macOS 15+ vraagt daarbij
  eenmalig om toegang tot "data from other apps".
- **Eigen versielijn, buildnummers vanaf 100.** Het Avatar2-target overschrijft
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in zijn eigen blok in
  `project.yml`; de root-settings zijn van v1. Build 100 ligt ruim boven elk
  v1-buildnummer, zodat een dev-binary die ooit op het gedeelde feed stond
  nooit een "downgrade" ziet.
- **Tag `v<ver>` zonder slash.** v1 is bevroren op 1.x, dus `v2.x.y` botst
  nooit, en een tag zonder slash houdt de download-URL encoding-vrij.
- **Zelfde EdDSA-sleutelpaar als v1** (besluit E01.11): één private key voor
  beide kanalen, geen extra key-beheer. De publieke sleutel staat als
  `SUPublicEDKey` in het Avatar2-blok van `project.yml`.
- **Geen `SUEnableDownloaderService`.** Avatar2 heeft de
  `network.client`-entitlement, dus Sparkle haalt appcast en download
  in-process. De Downloader-XPC was overbodig én hing onder de Xcode-debugger
  (die spawnt 'm suspended en kan niet attachen → "Checking for updates…"
  bleef eeuwig staan). Weggehaald 2026-09-02;
  `SUEnableInstallerLauncherService` blijft (nodig voor installeren vanuit de
  sandbox).
- **Sandbox + Sparkle = ook mach-lookup-uitzonderingen.** De installer
  (Autoupdate) luistert op de mach-services `nl.squareone.aaavatar2-spki` en
  `-spks`; de app mag die alleen opzoeken met
  `com.apple.security.temporary-exception.mach-lookup.global-name` in
  `Avatar2.entitlements`. Zonder die twee regels (2.0.0/2.0.1, E13.8) downloadt
  Sparkle netjes, herstart de app, maar installeert niets — en de fout staat
  alleen in Console (`sandboxd … deny(1) mach-lookup …-spks`) en Settings →
  About. Let op: dit zit in de *draaiende* app, dus een kapotte install kan
  zichzelf niet via Sparkle repareren; alleen een handmatige DMG-install helpt.
  Controle na een export: `codesign -d --entitlements :- Aaavatar.app | grep spk`.

## Eenmalige setup (alleen Thierry)

```bash
brew install create-dmg xcodegen gh

# Notarisatie-profiel (app-specific password van appleid.apple.com):
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id thierryemmery@gmail.com \
  --team-id 5J92MMGKTX \
  --password <app-specific-password>
```

Verder nodig in de Keychain van de release-Mac:

- **Developer ID Application**-certificaat (team 5J92MMGKTX) — Xcode exporteert
  ermee via `method: developer-id`.
- **Sparkle EdDSA private key** — `sign_update` leest 'm uit de Keychain. Het
  script pint een kopie van `sign_update` op
  `~/Library/Caches/avatar-release/sign_update` (of neemt `SIGN_UPDATE_PATH`),
  zodat de Keychain-ACL aan één vast pad hangt en niet bij elke DerivedData-
  wissel opnieuw om toestemming vraagt. Nooit `sign_update` gedraaid? Bouw dan
  eerst één keer, zodat de binary in DerivedData staat.

Check vooraf of het profiel er is; dit is precies wat op 2026-08-21 de
agent-run blokkeerde (GO-NO-GO §4):

```bash
xcrun notarytool history --keychain-profile AC_PASSWORD | head -3
```

## Per release

Invariant, in deze volgorde en niet anders: **de DMG-assets staan op GitHub
vóór het appcast gecommit en gedeployd wordt, en het appcast is gedeployd vóór
iemand het nieuws krijgt.** Iets publieks mag nooit verwijzen naar iets dat
nog niet bestaat.

1. Schone werkboom op `v2-main`, beide targets groen via
   `scripts/build-v2.sh`.
2. Kies versie + build: build is het vorige `<sparkle:version>` in
   `appcast-v2.xml` + 1 (eerste beta: `2.0.0` / `101`).
3. Schrijf `docs/releases/RELEASE-NOTES-<ver>.md` (release-body; het script
   weigert zonder) en draai het script (bumpt, archiveert, exporteert, bouwt
   DMG, notariseert, staplet, tekent, werkt beide appcasts bij en publiceert):
   ```bash
   PRERELEASE=1 ./scripts/release-v2.sh 2.0.0 101   # staged: site blijft op de vorige latest
   ./scripts/release-v2.sh 2.0.1 102                # direct latest (patch-releases)
   ```
   Bij een bestaande release met dezelfde tag overschrijft het script de
   DMG-assets (`--clobber`); dat is bedoeld voor een herhaalde run, niet
   voor een tweede release onder dezelfde versie.
4. Controleer het nieuwe item bovenaan `appcast-v2.xml` (versie, build,
   `length`, `sparkle:edSignature`, URL naar `releases/download/v<ver>/…`) en
   dat `backend/api/_appcast-v2.xml` byte-gelijk is:
   ```bash
   cmp appcast-v2.xml backend/api/_appcast-v2.xml && echo mirror ok
   ```
5. De release-commit maakt het script zelf (alleen project.yml, pbxproj,
   Info.plist en beide appcasts) en pusht de tag `v<ver>` op precies die
   commit vóór `gh release create` — een tag op een sha die niet op origin
   staat gaf HTTP 422, en zonder target belandde de tag op main's HEAD (v1).
   Controleer `git log -1` en de tag: `git ls-remote origin refs/tags/v<ver>`.
6. Deploy de backend zodat prod het nieuwe item serveert. Sinds 2.0 = `main`
   is dat: `main` fast-forwarden naar de release-commit en pushen (Vercel
   deployt avatars-api én avatar-admin van `main`). Let op: het
   Payload-schema is handmatig (`push:false`) — nieuwe CMS-velden staan als
   SQL in `backend/sql/` en moeten **vóór de push** door Thierry in de
   Supabase SQL-editor zijn toegepast, anders breekt de admin-detailpagina
   van die collectie. Voor 2.0.0: `backend/sql/021_announcements_max_app_version.sql`.
7. Smoke:
   ```bash
   curl -s https://api.aaavatar.nl/appcast-v2.xml | grep 2.0.0
   ```
8. Update-e2e: een geïnstalleerde oudere 2.0-build → Settings → About →
   "Check now" → kaart linksonder "Aaavatar <ver> is available" → Install
   Update → voortgang → Relaunch → nieuwe versie draait. Plus een verse
   download-test via de release-pagina (Gatekeeper "verified"). Blijft de oude
   versie draaien: `/usr/bin/log show --last 10m --predicate 'process ==
   "Autoupdate" OR eventMessage CONTAINS "mach-lookup"'` (let op `/usr/bin/log`
   — zsh heeft een eigen `log`-builtin dat stil niets doet). Oudere installs dan
   2.0.2 kunnen dit pad niet halen (E13.8).
9. Staged gepubliceerd (`PRERELEASE=1`)? Dan nu live:
   ```bash
   gh release edit v<ver> --prerelease=false --latest
   curl -sIL https://github.com/Square-One-Official/Avatar/releases/latest/download/Aaavatar.dmg | grep -i location
   ```

## Rollback

1. `gh release delete v<ver> --yes` (haalt de assets weg). Was de release al
   `latest`: `gh release edit <vorige tag> --latest`, anders wijst de
   website-link naar niets.
2. Revert de release-commit (appcasts + versiebump) en deploy de backend
   opnieuw, zodat het feed het item niet meer aanbiedt.
3. Installs die de update al hebben, blijven erop staan; een hotfix is dan
   een nieuwe, hogere build.

## Sleutels — niet kwijtraken

- **Sparkle EdDSA private key** (Keychain). Gedeeld met v1: verlies breekt de
  auto-update-keten van **beide** apps voor elke install. Offline back-uppen.
- **Notarytool-profiel `AC_PASSWORD`** — herstelbaar (nieuw app-specific
  password), maar zonder profiel geen release.
- **Developer ID Application**-certificaat + private key (team 5J92MMGKTX).
- Publieke tegenhanger van de Sparkle-key: `SUPublicEDKey` in `project.yml`,
  identiek in beide targets.

## Bekende gaten (bewust, niet nu)

- `release-v2.sh` heeft geen preflight: een ontbrekend notary-profiel, een
  ontbrekende Developer ID of een al bestaande tag blijkt pas ná minuten
  archiveren. Geen verificatiestap na export (`codesign --verify --strict`,
  `spctl`, `stapler validate`) en niet hervatbaar na een halverwege gefaalde
  notarisatie.
- `scripts/build-v2.sh` pipet de xcodebuild-stappen door `tail -1`, waardoor
  de foutmelding bij een rode build niet zichtbaar is (de exit-code wél).

Deze staan als vervolgwerk genoteerd (scripthardening, CI-lint,
flag-registry) en zijn geen release-blocker voor de beta.
