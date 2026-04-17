# Avatar

Native macOS app voor HR die portretfoto's van medewerkers consistent verwerkt: AI achtergrond-verwijdering, automatische uitlijning op het gezicht, vaste achtergrond, en één-klik export naar LinkedIn / Slack / Email / generieke formaten.

Vervangt de Figma-workflow.

## Vereisten

- macOS 14 (Sonoma) of nieuwer — vereist voor Apple's `VNGenerateForegroundInstanceMaskRequest` (subject lift)
- Xcode 15 of nieuwer
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — alleen nodig om `.xcodeproj` te (her)genereren

## Bouwen & draaien

```bash
# Eerste keer (of na het toevoegen van bestanden):
xcodegen generate

# Open in Xcode en draai (⌘R):
open Avatar.xcodeproj
```

Of vanaf de command line:

```bash
xcodebuild -project Avatar.xcodeproj -scheme Avatar \
  -configuration Debug -destination 'platform=macOS' build \
  CODE_SIGNING_ALLOWED=NO
```

De `.app` komt in `~/Library/Developer/Xcode/DerivedData/Avatar-*/Build/Products/Debug/Avatar.app`.

## Hoe het werkt

1. **Importeer** een portretfoto (sleep op het venster, of `+` knop)
2. App roept `Vision.VNGenerateForegroundInstanceMaskRequest` aan → vrijstaande cutout
3. App roept `Vision.VNDetectFaceRectanglesRequest` aan → gezicht-bounding-box
4. `AutoAligner` plaatst de cutout zodat het gezicht 38% van de canvas-hoogte beslaat,
   gecentreerd op (50%, 42%). Hierdoor staan **alle portretten visueel identiek**
   ongeacht de oorspronkelijke compositie.
5. Lila kan handmatig nog slepen / schalen / van achtergrond wisselen
6. **Exporteer** met een of meer presets in één klik → PNG's in haar gekozen map

## Bestandsstructuur

```
Avatar/
├── AvatarApp.swift        App entry, ModelContainer
├── Models/                        SwiftData @Model classes
│   ├── Portrait.swift
│   ├── BackgroundPreset.swift
│   └── ExportPreset.swift
├── Services/
│   ├── AppState.swift             Observable shared state + image cache
│   ├── ImageProcessor.swift       Subject lift + face detection (Vision)
│   ├── AutoAligner.swift          Face → canonical canvas transform (pure)
│   ├── Compositor.swift           Background + cutout + circle mask render
│   ├── ExportService.swift        PNG writer
│   ├── SeedData.swift             Built-in presets first-run
│   └── ImportFlow.swift           File → Portrait pipeline
└── Views/
    ├── MainWindow.swift           NavigationSplitView wrapper
    ├── LibraryView.swift          Sidebar + search
    ├── ImportDropZone.swift       Empty-state drop target
    ├── EditorView.swift           Live canvas, drag/scale, controls
    ├── ExportSheet.swift          Multi-preset selector + folder picker
    └── SettingsView.swift         Backgrounds & export-preset management
```

## Built-in export presets

| Naam        | Afmetingen | Vorm    |
|-------------|-----------|---------|
| LinkedIn    | 400×400   | Cirkel  |
| Slack       | 512×512   | Vierkant|
| Email       | 256×256   | Cirkel  |
| Generiek L  | 1024×1024 | Vierkant|
| Generiek M  | 512×512   | Vierkant|
| Generiek S  | 256×256   | Vierkant|

Lila kan extra presets toevoegen via **Avatar → Settings… → Export presets**.

## Auto-alignment afstemmen

De drie magische getallen staan in [`Avatar/Services/AutoAligner.swift`](Avatar/Services/AutoAligner.swift):

```swift
static let targetFaceHeightRatio: CGFloat = 0.38
static let targetFaceCenterY: CGFloat = 0.42
static let targetFaceCenterX: CGFloat = 0.50
```

Pas deze aan om de huisstijl te matchen (kleinere koppen, meer ruimte boven, etc.).

## Bekend / nog niet in v1

- Geen batch-import van meerdere foto's tegelijk
- Geen code-signing/notarization (de `.app` werkt lokaal; voor distributie moet je een Developer ID configureren)
- Geen undo/redo voor canvas-aanpassingen (auto-save bij elke wijziging)
