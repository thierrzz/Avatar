import Foundation

// MARK: - Language

enum Lang: String, CaseIterable, Identifiable {
    case en, nl
    var id: String { rawValue }
    var label: String {
        switch self {
        case .en: "English"
        case .nl: "Nederlands"
        }
    }

    static var current: Lang {
        Lang(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "en") ?? .en
    }
}

// MARK: - Localised strings

/// All user-facing strings, English by default.
/// Access via `Loc.xxx`. Reads `Lang.current` on every access so views
/// that re-render (e.g. because `appState.language` changed) pick up
/// the new language automatically.
enum Loc {
    private static var en: Bool { Lang.current == .en }

    // MARK: General
    static var cancel: String          { en ? "Cancel" : "Annuleer" }
    static var delete: String          { en ? "Delete" : "Verwijder" }
    static var ok: String              { "OK" }
    static var name: String            { en ? "Name" : "Naam" }
    static var add: String             { en ? "Add" : "Toevoegen" }
    static var close: String           { en ? "Close" : "Sluiten" }
    static var error: String           { en ? "Error" : "Fout" }
    static var retry: String           { en ? "Retry" : "Probeer opnieuw" }
    static var restart: String         { en ? "Restart" : "Herstart" }
    static var select: String          { en ? "Select" : "Selecteer" }
    static var info: String            { "Info" }

    // MARK: Toolbar / Editor actions
    static var undo: String            { en ? "Undo" : "Stap terug" }
    static var undoHelp: String        { en ? "Undo (⌘Z)" : "Ongedaan maken (⌘Z)" }
    static var redo: String            { en ? "Redo" : "Stap vooruit" }
    static var redoHelp: String        { en ? "Redo (⌘⇧Z)" : "Opnieuw (⌘⇧Z)" }
    static var alignmentGuide: String  { en ? "Alignment Guide" : "Uitlijnhulp" }
    static var alignmentGuideHelp: String { en ? "Show eye and head guides on the canvas" : "Toon oog- en hoofdhulplijnen op het canvas" }
    static var inspector: String       { "Inspector" }
    static var inspectorHelp: String   { en ? "Show or hide the inspector" : "Toon of verberg de instellingen" }
    static var export: String          { en ? "Export" : "Exporteer" }

    // MARK: Editor – Info section
    static var employeeName: String    { en ? "Name" : "Naam" }
    static var role: String            { en ? "Role" : "Rol" }

    // MARK: Editor – Background
    static var background: String      { en ? "Background" : "Achtergrond" }

    // MARK: Editor – Position & Scale
    static var positionScale: String   { en ? "Position & Scale" : "Positie & Schaal" }
    static var autoAlignFace: String   { en ? "Auto-align to face" : "Auto-uitlijnen op gezicht" }
    static var scale: String           { en ? "Scale" : "Schaal" }

    // MARK: Editor – Edit section
    static var edit: String            { en ? "Edit" : "Bewerken" }
    static var reCutout: String        { en ? "Re-cutout" : "Opnieuw uitknippen" }
    static var reCutoutHelpAdvanced: String {
        en ? "Re-cuts this portrait with the advanced AI model for better hair quality."
           : "Knipt dit portret opnieuw uit met het geavanceerde AI-model voor betere haarkwaliteit."
    }
    static var reCutoutHelpApple: String {
        en ? "Re-cuts this portrait with the Apple pipeline. Position and scale are preserved."
           : "Knipt dit portret opnieuw uit met de Apple-pipeline. Positie en schaal blijven behouden."
    }
    static var upscale2x: String       { en ? "Upscale (2x)" : "Opschalen (2x)" }
    static var alreadyUpscaled: String {
        en ? "This portrait has already been upscaled."
           : "Dit portret is al opgeschaald."
    }
    static var upscaleHelp: String {
        en ? "Upscales the original photo to 2× resolution and re-cuts for higher quality."
           : "Schaalt de originele foto op naar 2× resolutie en knipt opnieuw uit voor hogere kwaliteit."
    }
    static var magicRetouchDone: String { "Magic Retouch ✓" }
    static var magicRetouch: String    { "Magic Retouch" }
    static var magicRetouchUndo: String {
        en ? "Undo Magic Retouch" : "Magic Retouch ongedaan maken"
    }
    static var magicRetouchAlready: String {
        en ? "Magic Retouch has already been applied. Click again to undo."
           : "Magic Retouch is al toegepast. Klik nogmaals om ongedaan te maken."
    }
    static var magicRetouchHelp: String {
        en ? "Automatically enhances colors, exposure, and shadows for studio quality."
           : "Verbetert automatisch kleuren, belichting en schaduwen voor studiokwaliteit."
    }
    static var magicRetouchWithUpgradeHelp: String {
        en ? "Upgrades the cutout with the advanced AI model and enhances colors for studio quality."
           : "Verbetert de uitknip met het geavanceerde AI-model en optimaliseert kleuren voor studiokwaliteit."
    }
    static var magicRetouchUndoHelp: String {
        en ? "Revert to the original cutout without Magic Retouch."
           : "Herstel de originele uitknip zonder Magic Retouch."
    }

    // MARK: Editor – Adjustments
    static var colorAdjustments: String { en ? "Color Adjustments" : "Kleuraanpassingen" }
    static var exposure: String        { en ? "Exposure" : "Belichting" }
    static var contrast: String        { "Contrast" }
    static var tint: String            { "Tint" }
    static var saturation: String      { en ? "Saturation" : "Verzadiging" }
    static var temperature: String     { en ? "Temperature" : "Temperatuur" }
    static var highlights: String      { "Highlights" }
    static var shadows: String         { en ? "Shadows" : "Schaduwen" }
    static var resetAdjustments: String { en ? "Reset Adjustments" : "Herstel aanpassingen" }
    static var adjustment: String      { en ? "Adjustment" : "Aanpassing" }

    // MARK: Editor – Library section
    static var library: String         { en ? "Library" : "Bibliotheek" }
    static var alignAllPortraits: String { en ? "Align all portraits" : "Lijn alle portretten uit" }
    static func alignAllHelp(_ count: Int) -> String {
        en ? "Applies the same face size and eye height to \(count) portraits."
           : "Past dezelfde gezichtsgrootte en ooghoogte toe op \(count) portretten."
    }
    static var deletePortrait: String  { en ? "Delete portrait" : "Verwijder portret" }

    // MARK: Editor – Bulk align dialog
    static var alignAllQuestion: String { en ? "Align all portraits?" : "Alle portretten uitlijnen?" }
    static func alignButton(_ count: Int) -> String {
        en ? "Align (\(count))" : "Uitlijnen (\(count))"
    }
    static func alignConfirmMessage(_ count: Int) -> String {
        en ? "This will overwrite manual adjustments for \(count) portraits. You can undo with ⌘Z."
           : "Hiermee worden handmatige aanpassingen overschreven voor \(count) portretten. Je kunt dit ongedaan maken met ⌘Z."
    }
    static var alignComplete: String   { en ? "Alignment complete" : "Uitlijnen voltooid" }
    static func skippedPortraits(_ n: Int) -> String {
        en ? "\(n) \(n == 1 ? "portrait skipped" : "portraits skipped") — no face found."
           : "\(n) \(n == 1 ? "portret overgeslagen" : "portretten overgeslagen") — geen gezicht gevonden."
    }

    // MARK: Editor – Undo action names
    static var moveAction: String      { en ? "Move" : "Verplaats" }
    static var autoAlignAction: String { en ? "Auto-align" : "Auto-uitlijnen" }
    static var backgroundAction: String { en ? "Background" : "Achtergrond" }

    // MARK: Editor – Drop / processing overlays
    static var dropPhotoHere: String {
        en ? "Drop photo here for a new portrait"
           : "Drop foto hier voor een nieuw portret"
    }
    static var processingPhoto: String { en ? "Processing photo…" : "Foto verwerken…" }

    // MARK: Editor – Advanced model hint
    static var betterHairAvailable: String {
        en ? "Better hair quality available"
           : "Betere haarkwaliteit beschikbaar"
    }
    static var advancedModelHint: String {
        en ? "Install the advanced AI model via Settings > AI Model for sharper hair contours."
           : "Installeer het geavanceerde AI-model via Instellingen > AI Model voor scherpere haarcontouren."
    }
    static var openSettings: String    { en ? "Open Settings" : "Open Instellingen" }

    // MARK: Editor – Background picker context menu
    static var rename: String          { en ? "Rename…" : "Hernoem…" }
    static var setDefault: String      { en ? "Set as default" : "Maak standaard" }
    static var defaultCheck: String    { en ? "Default ✓" : "Standaard ✓" }

    // MARK: Editor – Color palette
    static var white: String           { en ? "White" : "Wit" }
    static var lightGray: String       { en ? "Light gray" : "Licht grijs" }
    static var warmWhite: String       { en ? "Warm white" : "Warm wit" }
    static var softBlue: String        { en ? "Soft blue" : "Zacht blauw" }
    static var softGreen: String       { en ? "Soft green" : "Zacht groen" }
    static var peach: String           { en ? "Peach" : "Perzik" }
    static var deepBlue: String        { en ? "Deep blue" : "Diep blauw" }
    static var anthracite: String      { en ? "Anthracite" : "Antraciet" }

    // MARK: Editor – Add background popover
    static var uploadImage: String     { en ? "Upload image…" : "Upload afbeelding…" }
    static var chooseColor: String     { en ? "Choose a color" : "Kies een kleur" }
    static var color: String           { en ? "Color" : "Kleur" }

    // MARK: Settings – Backgrounds tab
    static var backgrounds: String     { en ? "Backgrounds" : "Achtergronden" }
    static var addImage: String        { en ? "Add image" : "Voeg afbeelding toe" }
    static var addColor: String        { en ? "Add color" : "Voeg kleur toe" }
    static var setAsDefault: String    { en ? "Set as default" : "Stel in als standaard" }

    // MARK: Settings – Export presets tab
    static var exportPresets: String   { en ? "Export Presets" : "Export presets" }
    static var new: String             { en ? "New" : "Nieuw" }
    static var addPreset: String       { en ? "Add" : "Voeg toe" }
    static var width: String           { en ? "Width" : "Breedte" }
    static var height: String          { en ? "Height" : "Hoogte" }
    static var shape: String           { en ? "Shape" : "Vorm" }
    static var square: String          { en ? "Square" : "Vierkant" }
    static var circle: String          { en ? "Circle" : "Cirkel" }

    // MARK: Settings – AI Model tab
    static var aiHairQuality: String   { en ? "AI Hair Quality" : "AI Haarkwaliteit" }
    static var advancedCutoutModel: String { en ? "Advanced cutout model" : "Geavanceerd uitknipmodel" }
    static var advancedModelDesc: String {
        en ? "Uses a specialized AI model (BiRefNet) for better hair quality when removing backgrounds. Especially visible with fine hair, curls, and hair against a busy background."
           : "Gebruikt een gespecialiseerd AI-model (BiRefNet) voor betere haarkwaliteit bij het vrijstaand maken. Vooral zichtbaar bij fijn haar, krullen en haar tegen een drukke achtergrond."
    }
    static var modelNotInstalled: String { en ? "Model not installed" : "Model niet geinstalleerd" }
    static var downloadModelPrompt: String {
        en ? "Download the BiRefNet model (~250 MB) for better hair quality when removing backgrounds."
           : "Download het BiRefNet model (~250 MB) voor betere haarkwaliteit bij het vrijstaand maken."
    }
    static var installModel: String    { en ? "Install model" : "Installeer model" }
    static var downloading: String     { en ? "Downloading…" : "Downloaden..." }
    static var modelAvailable: String  { en ? "Model available" : "Model beschikbaar" }
    static func sizeOnDisk(_ size: String) -> String {
        en ? "Size on disk: \(size)" : "Grootte op schijf: \(size)"
    }
    static var useAdvancedModel: String {
        en ? "Use advanced model for cutout"
           : "Gebruik geavanceerd model bij uitknippen"
    }
    static var advancedModelToggleHelp: String {
        en ? "When enabled, new and re-cut portraits are processed with the advanced model. Existing portraits are not automatically reprocessed — use 'Re-cutout' in the editor."
           : "Wanneer ingeschakeld worden nieuwe en opnieuw uitgeknipte portretten verwerkt met het geavanceerde model. Bestaande portretten worden niet automatisch opnieuw verwerkt — gebruik 'Opnieuw uitknippen' in de editor."
    }

    // MARK: Settings – Updates tab
    static var updates: String         { "Updates" }
    static var currentVersion: String  { en ? "Current version" : "Huidige versie" }
    static var autoCheckUpdates: String {
        en ? "Check for updates automatically"
           : "Controleer automatisch op updates"
    }
    static var checkNow: String        { en ? "Check now" : "Controleer nu" }
    static func lastChecked(_ date: String) -> String {
        en ? "Last checked: \(date) ago" : "Laatst gecontroleerd: \(date) geleden"
    }
    static func versionReady(_ version: String) -> String {
        en ? "Version \(version) is ready to install"
           : "Versie \(version) is klaar om te installeren"
    }

    // MARK: Settings – Language tab
    static var language: String        { en ? "Language" : "Taal" }
    static var languageDesc: String {
        en ? "Choose the display language for the app."
           : "Kies de weergavetaal voor de app."
    }

    // MARK: Export sheet
    static var exportPortrait: String  { en ? "Export portrait" : "Exporteer portret" }
    static var exportHere: String      { en ? "Export here" : "Exporteer hier" }
    static var noImageToExport: String { en ? "No image to export." : "Geen afbeelding om te exporteren." }
    static func exportFailed(_ names: String) -> String {
        en ? "Failed: \(names)" : "Mislukt: \(names)"
    }
    static func filesSaved(_ count: Int) -> String {
        en ? "\(count) file\(count == 1 ? "" : "s") saved"
           : "\(count) bestand\(count == 1 ? "" : "en") opgeslagen"
    }
    static var portrait: String        { en ? "Portrait" : "Portret" }
    static func exportCount(_ count: Int) -> String {
        en ? "Export\(count > 0 ? " (\(count))" : "")"
           : "Exporteer\(count > 0 ? " (\(count))" : "")"
    }

    // MARK: Library
    static var searchPlaceholder: String { en ? "Search by name or tag" : "Zoek op naam of tag" }
    static var noPortraitsYet: String  { en ? "No portraits yet" : "Nog geen portretten" }
    static var noResults: String       { en ? "No results" : "Geen resultaten" }
    static var importToStart: String   { en ? "Import a photo to get started." : "Importeer een foto om te beginnen." }
    static var adjustSearch: String    { en ? "Adjust your search." : "Pas je zoekopdracht aan." }
    static var processing: String      { en ? "Processing…" : "Verwerken…" }
    static var unnamed: String         { en ? "(unnamed)" : "(naamloos)" }

    // MARK: Main window
    static var importPhoto: String     { en ? "Import photo" : "Importeer foto" }
    static var importPhotoHelp: String { en ? "Import a new portrait photo" : "Importeer een nieuwe portretfoto" }

    // MARK: Import drop zone
    static var dropHere: String        { en ? "Drop a portrait photo here" : "Sleep een portretfoto hierheen" }
    static var orUseButton: String     { en ? "or use the + button at the top" : "of gebruik de + knop bovenin" }

    // MARK: Sidebar update card
    static func updatedTo(_ version: String) -> String {
        en ? "Updated to \(version)" : "Bijgewerkt naar \(version)"
    }
    static var restartToApply: String  { en ? "Restart to apply" : "Herstart om toe te passen" }

    // MARK: Import flow errors
    static var dropPhotoNotFound: String     { en ? "Could not find the dropped photo." : "Kon de gesleepte foto niet vinden." }
    static var dropImageUnreadable: String   { en ? "Could not read the dropped image." : "Kon de gesleepte afbeelding niet lezen." }
    static var imported: String              { en ? "Imported" : "Geïmporteerd" }
    static var unknownFileType: String       { en ? "Unknown file type dropped." : "Onbekend bestandstype gesleept." }
    static func cannotReadFile(_ err: String) -> String {
        en ? "Cannot read file: \(err)" : "Kan bestand niet lezen: \(err)"
    }
    static var cannotDecodeImage: String     { en ? "Cannot decode image." : "Kan afbeelding niet decoderen." }
    static var noOriginalForRecutout: String {
        en ? "No original photo saved — cannot re-cutout."
           : "Geen originele foto bewaard — kan niet opnieuw uitknippen."
    }
    static var cannotDecodeOriginal: String  { en ? "Cannot decode original image." : "Kan originele afbeelding niet decoderen." }
    static var portraitNotFound: String      { en ? "Portrait no longer found." : "Portret niet meer gevonden." }
    static var noOriginalForUpscale: String  {
        en ? "No original photo saved — cannot upscale."
           : "Geen originele foto bewaard — kan niet opschalen."
    }
    static var upscaleFailed: String         { en ? "Upscale failed." : "Opschalen mislukt." }
    static var cannotSaveUpscaled: String    { en ? "Cannot save upscaled image." : "Kan opgeschaalde afbeelding niet opslaan." }
    static func recutoutFailed(_ err: String) -> String {
        en ? "Re-cutout failed: \(err)" : "Opnieuw uitknippen mislukt: \(err)"
    }
    static func upscaleFailedErr(_ err: String) -> String {
        en ? "Upscale failed: \(err)" : "Opschalen mislukt: \(err)"
    }
    static var noCutoutAvailable: String     { en ? "No cutout available." : "Geen uitknip beschikbaar." }
    static var magicRetouchFailed: String    { en ? "Magic Retouch failed." : "Magic Retouch mislukt." }
    static func processingFailed(_ err: String) -> String {
        en ? "Processing failed: \(err)" : "Verwerken mislukt: \(err)"
    }

    // MARK: Model manager errors
    static func modelLoadFailed(_ err: String) -> String {
        en ? "Failed to load model: \(err)" : "Model laden mislukt: \(err)"
    }
    static func downloadFailed(_ err: String) -> String {
        en ? "Download failed: \(err)" : "Download mislukt: \(err)"
    }
    static var downloadNoFile: String {
        en ? "Download failed: no file received" : "Download mislukt: geen bestand ontvangen"
    }
    static func installFailed(_ err: String) -> String {
        en ? "Installation failed: \(err)" : "Installatie mislukt: \(err)"
    }
    static func extractionFailed(_ code: Int32) -> String {
        en ? "Extraction failed (ditto exit \(code))" : "Uitpakken mislukt (ditto exit \(code))"
    }
    static var modelNotFoundAfterExtract: String {
        en ? "Model not found after extraction" : "Model niet gevonden na uitpakken"
    }

    // MARK: Seed data
    static var defaultBg: String       { en ? "Default" : "Standaard" }

    // MARK: Library export/import
    static var exportLibrary: String   { en ? "Export Library…" : "Exporteer bibliotheek…" }
    static var importLibrary: String   { en ? "Import Library…" : "Importeer bibliotheek…" }
    static var exportLibraryTitle: String { en ? "Export Library" : "Exporteer bibliotheek" }
    static var importLibraryTitle: String { en ? "Import Library" : "Importeer bibliotheek" }
    static var selectAll: String       { en ? "Select All" : "Selecteer alles" }
    static var deselectAll: String     { en ? "Deselect All" : "Deselecteer alles" }
    static var includeBackgrounds: String { en ? "Include backgrounds" : "Inclusief achtergronden" }
    static var includeExportPresets: String { en ? "Include export presets" : "Inclusief export-presets" }
    static var exporting: String       { en ? "Exporting…" : "Exporteren…" }
    static var importing: String       { en ? "Importing…" : "Importeren…" }
    static var exportComplete: String  { en ? "Export complete" : "Export voltooid" }
    static var importComplete: String  { en ? "Import complete" : "Import voltooid" }
    static func estimatedSize(_ size: String) -> String {
        en ? "Estimated size: \(size)" : "Geschatte grootte: \(size)"
    }
    static func portraitsCount(_ n: Int) -> String {
        en ? "\(n) portrait\(n == 1 ? "" : "s")"
           : "\(n) portret\(n == 1 ? "" : "ten")"
    }
    static func backgroundsCount(_ n: Int) -> String {
        en ? "\(n) background\(n == 1 ? "" : "s")"
           : "\(n) achtergrond\(n == 1 ? "" : "en")"
    }
    static func presetsCount(_ n: Int) -> String {
        en ? "\(n) preset\(n == 1 ? "" : "s")"
           : "\(n) preset\(n == 1 ? "" : "s")"
    }

    // Import conflict resolution
    static var importSkip: String      { en ? "Skip duplicates" : "Sla duplicaten over" }
    static var importReplace: String   { en ? "Replace existing" : "Vervang bestaande" }
    static var importCopy: String      { en ? "Import as copies" : "Importeer als kopieën" }
    static var conflictsFound: String  { en ? "Conflicts found" : "Conflicten gevonden" }
    static func conflictMessage(_ n: Int) -> String {
        en ? "\(n) item\(n == 1 ? "" : "s") already exist\(n == 1 ? "s" : "") in your library."
           : "\(n) item\(n == 1 ? "" : "s") bestaa\(n == 1 ? "t" : "n") al in je bibliotheek."
    }
    static var importButton: String    { en ? "Import" : "Importeer" }
    static func importResult(_ imported: Int, _ skipped: Int) -> String {
        let imp = en ? "\(imported) imported" : "\(imported) geïmporteerd"
        if skipped > 0 {
            let sk = en ? "\(skipped) skipped" : "\(skipped) overgeslagen"
            return "\(imp), \(sk)"
        }
        return imp
    }
    static func importErrors(_ n: Int) -> String {
        en ? "\(n) error\(n == 1 ? "" : "s") occurred during import."
           : "\(n) fout\(n == 1 ? "" : "en") opgetreden tijdens import."
    }
    static var updateRequired: String {
        en ? "Please update Avatar to open this library."
           : "Werk Avatar bij om deze bibliotheek te openen."
    }
    static var invalidLibraryFile: String {
        en ? "This file is not a valid Avatar library."
           : "Dit bestand is geen geldige Avatar-bibliotheek."
    }

    // MARK: Cloud workspaces
    static var signInWithGoogle: String { en ? "Sign in with Google" : "Inloggen met Google" }
    static var signOut: String         { en ? "Sign Out" : "Uitloggen" }
    static var workspaces: String      { "Workspaces" }
    static var newWorkspace: String    { en ? "New Workspace" : "Nieuwe workspace" }
    static var workspaceSettings: String { en ? "Workspace Settings" : "Workspace-instellingen" }
    static var shareWorkspace: String  { en ? "Invite" : "Uitnodigen" }
    static var share: String           { en ? "Invite" : "Nodig uit" }
    static var owner: String           { en ? "Owner" : "Eigenaar" }
    static var lastSynced: String      { en ? "Last synced" : "Laatst gesynchroniseerd" }
    static var shareSuccess: String    { en ? "Invitation sent" : "Uitnodiging verstuurd" }
    static var addToWorkspace: String  { en ? "Add items" : "Items toevoegen" }
    static var addToWorkspaceDesc: String {
        en ? "Add your local portraits and backgrounds to this workspace for syncing."
           : "Voeg je lokale portretten en achtergronden toe aan deze workspace om te synchroniseren."
    }
    static var addAllPortraits: String { en ? "Add all portraits" : "Voeg alle portretten toe" }
    static var addAllBackgrounds: String { en ? "Add all backgrounds" : "Voeg alle achtergronden toe" }
    static var syncing: String         { en ? "Syncing…" : "Synchroniseren…" }
    static var syncComplete: String    { en ? "Sync complete" : "Synchronisatie voltooid" }
    static var syncError: String       { en ? "Sync error" : "Synchronisatiefout" }
    static var conflictDetected: String { en ? "Conflict detected" : "Conflict gedetecteerd" }
    static var keepLocal: String       { en ? "Keep local" : "Behoud lokaal" }
    static var keepRemote: String      { en ? "Keep remote" : "Behoud extern" }

    // Workspace switcher
    static var myLibrary: String       { en ? "My Library" : "Mijn bibliotheek" }
    static var noPortraitsInWorkspace: String { en ? "No portraits in this workspace" : "Geen portretten in deze workspace" }
    static var addPortraitsHint: String { en ? "Open workspace settings to add portraits" : "Open workspace-instellingen om portretten toe te voegen" }
    static var account: String         { en ? "Account" : "Account" }
    static var createWorkspace: String { en ? "Create" : "Aanmaken" }
    static var inviteMembers: String   { en ? "Invite" : "Uitnodigen" }
    static var driveFolder: String     { en ? "Drive folder" : "Drive-map" }
    static var openInDrive: String     { en ? "Open in Google Drive" : "Openen in Google Drive" }
    static var myDrive: String         { en ? "My Drive" : "Mijn Drive" }
    static var chooseFolder: String    { en ? "Choose" : "Kies" }
    static var changeFolder: String    { en ? "Change" : "Wijzigen" }
    static var changeLocation: String  { en ? "Change location" : "Locatie wijzigen" }
    static var chooseDriveFolder: String { en ? "Choose Drive folder" : "Kies Drive-map" }
    static var chooseFolderSubtitle: String { en ? "Your workspace files will be synced to this folder" : "Je workspace-bestanden worden naar deze map gesynchroniseerd" }
    static var selectFolder: String    { en ? "Select this folder" : "Selecteer deze map" }
    static var noFoldersFound: String  { en ? "No subfolders" : "Geen submappen" }
    static var tryAgain: String        { en ? "Try again" : "Probeer opnieuw" }

    // MARK: Move to workspace
    static var moveTo: String          { en ? "Move to…" : "Verplaats naar…" }
    static var moveToWorkspace: String { en ? "Move to workspace" : "Verplaats naar workspace" }
    static var noWorkspacesAvailable: String { en ? "No other workspaces" : "Geen andere workspaces" }
    static func movedCount(_ n: Int, _ ws: String) -> String {
        en ? "\(n) portrait\(n == 1 ? "" : "s") moved to \(ws)"
           : "\(n) portret\(n == 1 ? "" : "ten") verplaatst naar \(ws)"
    }

    // MARK: Batch operations
    static func selectedCount(_ n: Int) -> String {
        en ? "\(n) portraits selected" : "\(n) portretten geselecteerd"
    }
    static var batchAlign: String {
        en ? "Auto-align selected" : "Selectie auto-uitlijnen"
    }
    static func batchAlignQuestion(_ n: Int) -> String {
        en ? "Auto-align \(n) portraits?" : "\(n) portretten auto-uitlijnen?"
    }
    static func batchUpscaleCount(_ eligible: Int, _ total: Int) -> String {
        en ? "Upscale 2× (\(eligible) of \(total))"
           : "Opschalen 2× (\(eligible) van \(total))"
    }
    static func batchRetouchCount(_ eligible: Int, _ total: Int) -> String {
        en ? "Magic Retouch (\(eligible) of \(total))"
           : "Magic Retouch (\(eligible) van \(total))"
    }
    static func batchUndoRetouch(_ n: Int) -> String {
        en ? "Undo Retouch (\(n))" : "Retouch ongedaan (\(n))"
    }
    static var batchApplyAdjustments: String {
        en ? "Apply" : "Toepassen"
    }
    static var batchResetAdjustments: String {
        en ? "Reset All" : "Alles herstellen"
    }
    static var batchSetBackground: String {
        en ? "Set Background" : "Achtergrond instellen"
    }
    static func batchDelete(_ n: Int) -> String {
        en ? "Delete \(n) portraits" : "Verwijder \(n) portretten"
    }
    static func batchDeleteConfirm(_ n: Int) -> String {
        en ? "Delete \(n) portraits? This cannot be undone."
           : "\(n) portretten verwijderen? Dit kan niet ongedaan worden gemaakt."
    }
    static func batchImportErrors(succeeded: Int, failed: Int) -> String {
        en ? "\(succeeded) imported, \(failed) failed."
           : "\(succeeded) geïmporteerd, \(failed) mislukt."
    }
}
