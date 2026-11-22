import SwiftUI
import AppKit
import UniformTypeIdentifiers

@_silgen_name("MeowRefreshCursor") func MeowRefreshCursor() -> Int32

// Palette resolves per effective appearance, so it follows NSApp.appearance
// (system / light / dark) without re-rendering logic in each view.
func adaptive(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    })
}
// Dark palette: pudding-inspired — chocolate browns with custard yellow,
// caramel highlights and cream text.
let cream = adaptive((0.99, 0.97, 0.93), (0.14, 0.10, 0.07))          // sidebar, drop zone
let accent = adaptive((0.74, 0.39, 0.13), (0.98, 0.84, 0.42))         // custard yellow
let accentPressed = adaptive((0.65, 0.29, 0.08), (0.90, 0.72, 0.28))
let onAccent = adaptive((1, 1, 1), (0.24, 0.15, 0.09))                // text on primary buttons
let apricot = adaptive((1, 0.87, 0.67), (0.42, 0.28, 0.16))           // caramel selection / hover
let apricotPressed = adaptive((0.96, 0.68, 0.39), (0.54, 0.36, 0.20))
let ink = adaptive((0.26, 0.26, 0.28), (1.0, 0.95, 0.84))             // cream text
let canvas = adaptive((0.98, 0.98, 0.97), (0.18, 0.13, 0.09))         // main background
let surface = adaptive((1, 1, 1), (0.25, 0.18, 0.13))                 // cards, buttons
let appearanceModes = ["system", "light", "dark"]
let projectURL = URL(string: "https://github.com/lx3211/AniOnMac")!
let projectAuthor = "lx3211"
let roles = ["arrow", "pointing", "text", "wait"]
let symbols = ["arrow": "cursorarrow", "pointing": "hand.point.up.left", "text": "character.cursor.ibeam", "wait": "hourglass"]

struct Slot: Codable, Identifiable, Equatable {
    var role: String
    var asset: String = ""
    var preview: String = ""
    var filename: String = ""
    var size: Double = 32
    var hotspot: [Double]? = nil
    /// Asset/preview before background removal, so it can be restored.
    var originalAsset: String? = nil
    var originalPreview: String? = nil
    var id: String { role }
}
struct Profile: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var slots: [Slot] = roles.map { Slot(role: $0) }
}
struct Library: Codable {
    var profiles: [Profile] = []
    var selected: String = ""
    var backupsByTheme: [String: String] = [:]
    var undoProfiles: [String: Profile] = [:]
    var appliedProfiles: [String: Profile] = [:]
    /// Theme whose cursors are currently registered with macOS (shown as "In use").
    var inUse: String? = nil
    /// "system" or a resource file stem such as "zh-Hant" / "en".
    var language = "system"
    /// "system", "light" or "dark".
    var appearance = "system"
    /// Legacy flag kept readable/writable for older library.json files.
    var english: Bool {
        get { language == "en" }
        set { language = newValue ? "en" : "zh-Hant" }
    }
    enum CodingKeys: String, CodingKey { case profiles, selected, backupsByTheme, undoProfiles, appliedProfiles, english, language, appearance, inUse }
    init() {}
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(selected, forKey: .selected)
        try c.encode(backupsByTheme, forKey: .backupsByTheme)
        try c.encode(undoProfiles, forKey: .undoProfiles)
        try c.encode(appliedProfiles, forKey: .appliedProfiles)
        try c.encode(language, forKey: .language)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(english, forKey: .english)
        try c.encodeIfPresent(inUse, forKey: .inUse)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        selected = try c.decodeIfPresent(String.self, forKey: .selected) ?? ""
        backupsByTheme = try c.decodeIfPresent([String: String].self, forKey: .backupsByTheme) ?? [:]
        undoProfiles = try c.decodeIfPresent([String: Profile].self, forKey: .undoProfiles) ?? [:]
        appliedProfiles = try c.decodeIfPresent([String: Profile].self, forKey: .appliedProfiles) ?? [:]
        if let saved = try c.decodeIfPresent(String.self, forKey: .language) { language = saved }
        // Legacy "english": false was only the old default, so it follows the
        // system language; an explicit true keeps English.
        else if try c.decodeIfPresent(Bool.self, forKey: .english) == true { language = "en" }
        let mode = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        appearance = appearanceModes.contains(mode) ? mode : "system"
        inUse = try c.decodeIfPresent(String.self, forKey: .inUse)
    }
}
struct PreviewInfo: Decodable {
    var aligned_canvas_px: [Double]
    var hotspot_points: [Double]
    var playback_frames: [Int]
    var frame_duration_seconds: Double
}
struct PreviewAsset {
    var info: PreviewInfo
    var frames: [NSImage]
}
struct AppFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

func runProcess(_ executable: URL, _ arguments: [String]) async throws -> String {
    try await Task.detached {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw AppFailure(message: text.isEmpty ? "Process failed" : text) }
        return text
    }.value
}

@MainActor final class Studio: ObservableObject {
    @Published var library = Library()
    @Published var role = "arrow"
    @Published var busy = false
    @Published var status = "ready"
    @Published var error: String?
    // Only a successful apply in this running session establishes this snapshot.
    @Published var activeApplication: Profile?
    var isApplied: Bool {
        guard let current = profile, let applied = activeApplication else { return false }
        return current.id == applied.id && current.slots == applied.slots
    }
    var canApply: Bool { !busy && !isApplied && (profile?.slots.contains { !$0.asset.isEmpty } ?? false) }
    @Published var ready = false
    @Published var cache: [String: PreviewAsset] = [:]
    let root: URL
    let resources = Bundle.main.resourceURL!
    var profile: Profile? { library.profiles.first { $0.id == library.selected } }
    var slot: Slot? { profile?.slots.first { $0.role == role } }
    var converter: URL { resources.appendingPathComponent("anicore") }
    /// Every bundled <code>.json resource with a "languageName" entry is a selectable
    /// language, so adding a translation needs no code change.
    lazy var languages: [(code: String, name: String)] = {
        let files = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let table = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)),
                  let name = table["languageName"] else { return nil }
            return (url.deletingPathExtension().lastPathComponent, name)
        }.sorted { a, b in
            let order = ["zh-Hant", "en", "ja", "ko"]
            let ia = order.firstIndex(of: a.code) ?? order.count, ib = order.firstIndex(of: b.code) ?? order.count
            return ia != ib ? ia < ib : a.code < b.code
        }
    }()
    /// Resolve "system" against the user's preferred languages, falling back to English.
    var resolvedLanguage: String {
        let codes = languages.map(\.code)
        if library.language != "system", codes.contains(library.language) { return library.language }
        for preferred in Locale.preferredLanguages {
            if let exact = codes.first(where: { preferred.lowercased().hasPrefix($0.lowercased()) }) { return exact }
            let base = preferred.split(separator: "-").first.map(String.init) ?? preferred
            if let family = codes.first(where: { $0.split(separator: "-").first.map(String.init) == base }) { return family }
        }
        return codes.contains("en") ? "en" : (codes.first ?? "en")
    }
    private var translationCache: (code: String, table: [String: String])?
    var translations: [String: String] {
        let code = resolvedLanguage
        if let cached = translationCache, cached.code == code { return cached.table }
        let path = resources.appendingPathComponent(code + ".json")
        let table = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: path))) ?? [:]
        translationCache = (code, table)
        return table
    }
    func t(_ key: String) -> String { translations[key] ?? key }
    func setLanguage(_ code: String) {
        let menuBefore = Self.menuLanguage
        library.language = code
        syncMenuLanguage()
        save()
        if Self.menuLanguage != menuBefore { status = "languageRelaunch" }
    }
    /// AppKit localizes the menu bar from AppleLanguages, read once at launch.
    /// Mirror the in-app choice there ("system" clears the per-app override).
    static var menuLanguage: [String]? { UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "io.anionmac.app")?["AppleLanguages"] as? [String] }
    func syncMenuLanguage() {
        if library.language == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([library.language], forKey: "AppleLanguages") }
    }
    func setAppearance(_ mode: String) {
        library.appearance = appearanceModes.contains(mode) ? mode : "system"
        applyAppearance()
        save()
    }
    func applyAppearance() {
        switch library.appearance {
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp?.appearance = NSAppearance(named: .darkAqua)
        default: NSApp?.appearance = nil
        }
    }
    func refresh() {
        let result = MeowRefreshCursor()
        if result != 0 { status = "refreshWarning" }
    }
    var tool: URL { resources.appendingPathComponent("cursorctl") }

    init() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--data-dir"), args.count > index + 1 {
            root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AniOnMac", isDirectory: true)
        }
        Task { await load() }
    }
    func persist() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }
    func save() {
        do { try persist() } catch { self.error = t("saveFailed") + "\n" + error.localizedDescription }
    }
    func load() async {
        busy = true
        defer { busy = false }
        do {
            // Migrate only on this Mac, never package user data in the app.
            if !FileManager.default.fileExists(atPath: root.path), !CommandLine.arguments.contains("--data-dir") {
                let candidates = ["CursorShift", "MeowCursor"].map { root.deletingLastPathComponent().appendingPathComponent($0) }
                if let old = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("library.json").path) }) {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let oldLibrary = try JSONDecoder().decode(Library.self, from: Data(contentsOf: old.appendingPathComponent("library.json")))
                    for relative in Set(oldLibrary.backupsByTheme.values) {
                        let source = old.appendingPathComponent(relative).standardizedFileURL
                        guard source.path.hasPrefix(old.standardizedFileURL.path + "/"), FileManager.default.fileExists(atPath: source.path) else { continue }
                        let destination = root.appendingPathComponent(relative)
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: source, to: destination)
                    }
                    for name in ["assets", "previews", "library.json"] {
                        let source = old.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(name)) }
                    }
                }
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: file.path) {
                library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: file))
                guard !library.profiles.isEmpty, library.profiles.allSatisfy({ Set($0.slots.map(\.role)) == Set(roles) && $0.slots.count == 4 }) else {
                    throw AppFailure(message: t("invalidLibrary"))
                }
                applyAppearance()
                syncMenuLanguage()
                if profile == nil { library.selected = library.profiles[0].id }
                for p in library.profiles {
                    for s in p.slots where !s.preview.isEmpty {
                        do { try loadPreview(s) }
                        catch { self.error = t("previewFailed") + "\n" + error.localizedDescription }
                    }
                }
            } else {
                let initial = Profile(name: t("newTheme"))
                library.profiles = [initial]
                library.selected = initial.id
                try persist()
            }
            ready = true
            status = "ready"
        } catch { self.error = error.localizedDescription; status = "loadFailed" }
    }
    func loadPreview(_ slot: Slot) throws {
        let dir = root.appendingPathComponent(slot.preview)
        let info = try JSONDecoder().decode(PreviewInfo.self, from: Data(contentsOf: dir.appendingPathComponent("preview.json")))
        let count = (info.playback_frames.max() ?? 0) + 1
        var frames: [NSImage] = []
        for n in 0..<count {
            guard let image = NSImage(contentsOf: dir.appendingPathComponent(String(format: "frame-%03d.png", n))) else {
                throw AppFailure(message: t("missingPreview") + " " + slot.filename)
            }
            frames.append(image)
        }
        cache[slot.preview] = PreviewAsset(info: info, frames: frames)
    }
    func imported(_ url: URL, role: String, size: Double) async throws -> Slot {
        guard url.pathExtension.lowercased() == "ani" else { throw AppFailure(message: t("chooseANI")) }
        let id = UUID().uuidString
        let asset = "assets/\(id).ani"
        let preview = "previews/\(id)"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let copied = root.appendingPathComponent(asset)
        try FileManager.default.copyItem(at: url, to: copied)
        do {
            let output = try await runProcess(converter, ["preview", copied.path, root.appendingPathComponent(preview).path])
            let data = Data(output.utf8)
            _ = try JSONDecoder().decode(PreviewInfo.self, from: data)
            try data.write(to: root.appendingPathComponent(preview).appendingPathComponent("preview.json"), options: .atomic)
            let result = Slot(role: role, asset: asset, preview: preview, filename: url.lastPathComponent, size: size)
            try loadPreview(result)
            return result
        } catch {
            try? FileManager.default.removeItem(at: copied)
            try? FileManager.default.removeItem(at: root.appendingPathComponent(preview))
            throw error
        }
    }
    func importFile(_ url: URL) {
        guard !busy, let p = profile, let s = slot else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await imported(url, role: s.role, size: s.size)
                guard let pi = library.profiles.firstIndex(where: { $0.id == p.id }), let si = library.profiles[pi].slots.firstIndex(where: { $0.role == s.role }) else { return }
                recordEditUndo(library.profiles[pi])
                library.profiles[pi].slots[si] = result
                try persist()
                status = "imported"
            } catch { self.error = error.localizedDescription }
        }
    }
    /// Milliseconds per frame when building an animation from still images.
    @Published var frameInterval = 100
    static let frameIntervals = [50, 83, 100, 150, 200, 300, 500]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "webp", "bmp", "gif"]

    /// Ordered image frames from files or folders, in Finder order (1, 2, … 10).
    static func imageFrames(_ urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                found += items.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            } else if imageExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Accept one .ani, or several images / a folder of images to animate.
    func importItems(_ urls: [URL]) {
        if urls.count == 1, urls[0].pathExtension.lowercased() == "ani" { importFile(urls[0]); return }
        let frames = Self.imageFrames(urls)
        guard !frames.isEmpty else { error = t("chooseANI"); return }
        // Several stills: let the user check and reorder them on the timeline first.
        // One image (static) or one animated GIF keeps its own order and imports directly.
        if frames.count > 1 { timeline = frames } else { importFrames(frames) }
    }
    /// Frames waiting on the timeline sheet (nil when it is closed).
    @Published var timeline: [URL]? = nil

    func importFrames(_ frames: [URL]) {
        guard !busy, let p = profile, let s = slot else { return }
        guard frames.count <= 24 else { error = t("tooManyFrames"); return }
        busy = true
        Task {
            let job = root.appendingPathComponent("work/\(UUID().uuidString)")
            defer { busy = false; try? FileManager.default.removeItem(at: job) }
            do {
                try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
                // Wait and text cursors are usually centred; arrow and hand point from the top-left.
                let hotspot = ["wait", "text"].contains(s.role) ? [0.5, 0.5] : [0.0, 0.0]
                let jiffies = max(1, min(600, Int((Double(frameInterval) * 60 / 1000).rounded())))
                let config: [String: Any] = ["images": frames.map(\.path), "jiffies": jiffies, "hotspot": hotspot]
                let input = job.appendingPathComponent("compose.json")
                try JSONSerialization.data(withJSONObject: config).write(to: input)
                let ani = job.appendingPathComponent(frames.count == 1 ? "\(frames[0].deletingPathExtension().lastPathComponent).ani" : "animation.ani")
                _ = try await runProcess(converter, ["compose", input.path, ani.path])
                var result = try await imported(ani, role: s.role, size: s.size)
                result.filename = frames.count == 1 ? frames[0].lastPathComponent
                    : "\(frames[0].lastPathComponent) – \(frames[frames.count - 1].lastPathComponent) · \(frames.count) " + t("frames")
                guard let pi = library.profiles.firstIndex(where: { $0.id == p.id }), let si = library.profiles[pi].slots.firstIndex(where: { $0.role == s.role }) else { return }
                recordEditUndo(library.profiles[pi])
                library.profiles[pi].slots[si] = result
                try persist()
                status = "imported"
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Updates
    static let releasesAPI = URL(string: "https://api.github.com/repos/lx3211/AniOnMac/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/lx3211/AniOnMac/releases/latest")!
    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// "v0.2.0" > "0.1.1" by numeric components.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @Published var checkingUpdates = false
    /// Commit this build came from (written by build.sh), for "new pushes on GitHub" checks.
    var buildCommit: String? { (Bundle.main.object(forInfoDictionaryKey: "AniOnMacCommit") as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var buildDate: Date? { (Bundle.main.object(forInfoDictionaryKey: "AniOnMacCommitDate") as? String).flatMap { ISO8601DateFormatter().date(from: $0) } }

    func githubJSON(_ path: String) async throws -> (Int, Any?) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/lx3211/AniOnMac" + path)!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data))
    }

    /// 1. A newer release → offer the download.  2. Otherwise compare this build's
    /// commit with the latest push on GitHub and report how far behind it is.
    func checkForUpdates() {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        Task {
            defer { checkingUpdates = false }
            let alert = NSAlert()
            do {
                let (releaseCode, release) = try await githubJSON("/releases/latest")
                let releaseInfo = releaseCode == 200 ? release as? [String: Any] : nil
                let releaseTag = releaseInfo?["tag_name"] as? String
                // When this build *is* the latest release, only pushes after that release count as new.
                let releaseDate = (releaseTag.map { !Self.isNewer($0, than: appVersion) && !Self.isNewer(appVersion, than: $0) } ?? false)
                    ? (releaseInfo?["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } : nil
                if let tag = releaseTag, Self.isNewer(tag, than: appVersion) {
                    alert.messageText = t("updateAvailable") + " " + tag
                    alert.informativeText = t("updateCurrent") + " " + appVersion
                    alert.addButton(withTitle: t("updateDownload")); alert.addButton(withTitle: t("cancel"))
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.releasesPage) }
                    return
                }
                let (code, commits) = try await githubJSON("/commits?per_page=1")
                guard code == 200, let latest = (commits as? [[String: Any]])?.first, let sha = latest["sha"] as? String,
                      let info = latest["commit"] as? [String: Any] else { throw AppFailure(message: "GitHub HTTP \(code)") }
                let message = ((info["message"] as? String) ?? "").split(separator: "\n").first.map(String.init) ?? ""
                let dateText = ((info["committer"] as? [String: Any])?["date"] as? String) ?? ""
                let remoteDate = ISO8601DateFormatter().date(from: dateText)
                var behind: Int?
                if let local = buildCommit {
                    if sha.hasPrefix(local) || local.hasPrefix(sha) { behind = 0 }
                    else {
                        let (compareCode, compare) = try await githubJSON("/compare/\(local)...\(sha)")
                        if compareCode == 200, let c = compare as? [String: Any] { behind = (c["ahead_by"] as? Int) ?? ((c["status"] as? String) == "identical" ? 0 : nil) }
                    }
                }
                // Not comparable (unknown build commit or a commit GitHub doesn't have): fall back to dates.
                var isNew = behind.map { $0 > 0 } ?? (remoteDate.map { $0 > (buildDate ?? .distantPast) } ?? false)
                if let releaseDate, let remoteDate, remoteDate <= releaseDate { isNew = false; behind = 0 }
                let when = remoteDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? dateText
                if isNew {
                    alert.messageText = t("updatePushes")
                    var lines = [t("updateLatestPush") + "：" + message, when]
                    if let behind, behind > 0 { lines.insert(t("updateBehind") + " \(behind)", at: 0) }
                    alert.informativeText = lines.joined(separator: "\n")
                    alert.addButton(withTitle: t("updateView")); alert.addButton(withTitle: t("cancel"))
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://github.com/lx3211/AniOnMac/commits")!) }
                } else {
                    alert.messageText = t("updateLatest")
                    alert.informativeText = t("updateCurrent") + " " + appVersion + (buildCommit.map { " (\($0.prefix(7)))" } ?? "") + "\n" + t("updateLatestPush") + "：" + message
                    alert.addButton(withTitle: t("ok")); alert.runModal()
                }
            } catch {
                alert.alertStyle = .warning
                alert.messageText = t("updateFailed"); alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: t("ok")); alert.runModal()
            }
        }
    }

    // MARK: Background removal
    /// While on, clicking the (enlarged) preview removes that colour instead of moving the hotspot.
    @Published var wandActive = false
    @Published var wandTolerance = 48.0

    /// Run the converter's background removal on the current slot and swap in the result,
    /// keeping size, hotspot override, filename and the pre-removal original.
    func knockout(mode: String, point: [Double]? = nil) {
        guard !busy, let p = profile, let s = slot, !s.asset.isEmpty else { return }
        busy = true
        Task {
            let job = root.appendingPathComponent("work/\(UUID().uuidString)")
            defer { busy = false; try? FileManager.default.removeItem(at: job) }
            do {
                try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
                var config: [String: Any] = ["mode": mode, "tolerance": wandTolerance]
                if let point { config["point"] = point }
                let input = job.appendingPathComponent("knockout.json")
                try JSONSerialization.data(withJSONObject: config).write(to: input)
                let output = job.appendingPathComponent("cutout.ani")
                let reply = try await runProcess(converter, ["knockout", root.appendingPathComponent(s.asset).path, input.path, output.path])
                let info = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? [:]
                if (info["removed_pixels"] as? Int ?? 0) == 0 && (info["subject_cutouts"] as? Int ?? 0) == 0 { status = "nothingRemoved"; return }
                var result = try await imported(output, role: s.role, size: s.size)
                result.filename = s.filename
                result.hotspot = s.hotspot
                result.originalAsset = s.originalAsset ?? s.asset
                result.originalPreview = s.originalPreview ?? s.preview
                guard let pi = library.profiles.firstIndex(where: { $0.id == p.id }), let si = library.profiles[pi].slots.firstIndex(where: { $0.role == s.role }) else { return }
                recordEditUndo(library.profiles[pi])
                library.profiles[pi].slots[si] = result
                try persist()
                status = "backgroundRemoved"
            } catch { self.error = error.localizedDescription }
        }
    }

    func restoreOriginal() {
        guard let pi = library.profiles.firstIndex(where: { $0.id == library.selected }), let si = library.profiles[pi].slots.firstIndex(where: { $0.role == role }) else { return }
        var s = library.profiles[pi].slots[si]
        guard let asset = s.originalAsset, let preview = s.originalPreview else { return }
        recordEditUndo(library.profiles[pi])
        s.asset = asset; s.preview = preview; s.originalAsset = nil; s.originalPreview = nil
        library.profiles[pi].slots[si] = s
        do { try loadPreview(s) } catch { self.error = t("previewFailed") + "\n" + error.localizedDescription }
        wandActive = false
        status = "originalRestored"
        save()
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ani") ?? .data, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = t("chooseHint")
        panel.begin { response in if response == .OK { let urls = panel.urls; Task { @MainActor in self.importItems(urls) } } }
    }
    func select(_ id: String) { library.selected = id; save() }
    func rename(_ name: String) {
        guard let i = library.profiles.firstIndex(where: { $0.id == library.selected }) else { return }
        library.profiles[i].name = name; save()
    }
    func size(_ value: Double) {
        guard let pi = library.profiles.firstIndex(where: { $0.id == library.selected }), let si = library.profiles[pi].slots.firstIndex(where: { $0.role == role }) else { return }
        library.profiles[pi].slots[si].size = value.rounded(); save()
    }
    func add(copy: Bool) {
        var p = copy ? (profile ?? Profile(name: t("newTheme"))) : Profile(name: t("newTheme"))
        p.id = UUID().uuidString
        p.name = copy ? p.name + " " + t("copySuffix") : t("newTheme")
        library.profiles.append(p); library.selected = p.id; save()
    }
    func remove() {
        guard library.profiles.count > 1 else { return }
        let removed = library.selected
        if let backup = library.backupsByTheme.removeValue(forKey: removed) { try? FileManager.default.removeItem(at: root.appendingPathComponent(backup)) }
        library.undoProfiles.removeValue(forKey: removed)
        library.appliedProfiles.removeValue(forKey: removed)
        if library.inUse == removed { library.inUse = nil }
        library.profiles.removeAll { $0.id == removed }
        library.selected = library.profiles[0].id; save()
    }
    func setHotspot(_ point: [Double]?) {
        guard let pi = library.profiles.firstIndex(where: { $0.id == library.selected }), let si = library.profiles[pi].slots.firstIndex(where: { $0.role == role }) else { return }
        library.profiles[pi].slots[si].hotspot = point?.map { min(0.999999, max(0, $0)) }
        save()
    }
    func hotNormalized(_ slot: Slot) -> [Double] {
        if let h = slot.hotspot { return h }
        guard let info = cache[slot.preview]?.info else { return [0, 0] }
        let maximum = info.aligned_canvas_px.max()!
        return zip(info.hotspot_points, info.aligned_canvas_px).map { $0.0 / (128 * $0.1 / maximum) }
    }
    func allSizes() {
        guard let pi = library.profiles.firstIndex(where: { $0.id == library.selected }), let size = slot?.size else { return }
        for i in library.profiles[pi].slots.indices { library.profiles[pi].slots[i].size = size }
        save(); status = "sizesUpdated"
    }
    func recordEditUndo(_ p: Profile) {
        library.undoProfiles[p.id] = p
        if let backup = library.backupsByTheme.removeValue(forKey: p.id) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(backup))
        }
    }
    func clearSlot() {
        guard let pi = library.profiles.firstIndex(where: { $0.id == library.selected }), let si = library.profiles[pi].slots.firstIndex(where: { $0.role == role }) else { return }
        recordEditUndo(library.profiles[pi])
        library.profiles[pi].slots[si] = Slot(role: role)
        save()
    }
    func performApply(cape: URL, theme: String) async throws {
        let backup = "backups/\(theme).cape"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("backups"), withIntermediateDirectories: true)
        if let p = profile { library.undoProfiles[theme] = library.appliedProfiles[theme] ?? library.undoProfiles[theme] ?? p }
        library.backupsByTheme[theme] = backup
        try persist()
        activeApplication = nil
        _ = try await runProcess(tool, ["apply-replace", cape.path, root.appendingPathComponent(backup).path])
        if let p = profile { library.appliedProfiles[theme] = p; activeApplication = p }
        library.inUse = theme
        try persist()
        status = "applied"
        refresh()
    }
    func apply() {
        guard canApply, let p = profile else { return }
        busy = true
        Task {
            let job = root.appendingPathComponent("work/\(UUID().uuidString)")
            defer { busy = false; try? FileManager.default.removeItem(at: job) }
            do {
                try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
                let config: [String: Any] = ["id": p.id, "name": p.name, "slots": p.slots.filter { !$0.asset.isEmpty }.map { slot -> [String: Any] in
                    var d: [String: Any] = ["role": slot.role, "path": root.appendingPathComponent(slot.asset).path, "size": slot.size]
                    if let hotspot = slot.hotspot { d["hotspot"] = hotspot }
                    return d
                }]
                let input = job.appendingPathComponent("input.json")
                try JSONSerialization.data(withJSONObject: config).write(to: input)
                _ = try await runProcess(converter, ["export", input.path, job.appendingPathComponent("converted").path])
                try await performApply(cape: job.appendingPathComponent("converted/theme.cape"), theme: p.id)
            } catch { self.error = error.localizedDescription; status = "applyFailed" }
        }
    }
    var lastBackup: String? {
        guard let path = library.backupsByTheme[library.selected], FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else { return nil }
        return path
    }
    var canUndo: Bool { lastBackup != nil || library.undoProfiles[library.selected] != nil }
    func restore() {
        guard !busy, canUndo else { return }
        let backup = lastBackup
        let theme = library.selected
        busy = true
        Task {
            defer { busy = false }
            do {
                if let backup { activeApplication = nil; _ = try await runProcess(tool, ["restore", root.appendingPathComponent(backup).path]) }
                if let previous = library.undoProfiles.removeValue(forKey: theme), let index = library.profiles.firstIndex(where: { $0.id == theme }) {
                    library.profiles[index] = previous
                    if backup != nil { library.appliedProfiles[theme] = previous }
                }
                if backup != nil, library.inUse == theme { library.inUse = nil }
                library.backupsByTheme.removeValue(forKey: theme); try persist()
                if let backup { try? FileManager.default.removeItem(at: root.appendingPathComponent(backup)) }
                status = "restored"
                if backup != nil { refresh() }
            } catch { self.error = error.localizedDescription }
        }
    }
    func restoreNative() {
        guard !busy else { return }
        busy = true
        Task {
            let job = root.appendingPathComponent("work/\(UUID().uuidString)")
            defer { busy = false; try? FileManager.default.removeItem(at: job) }
            do {
                try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
                let cape = job.appendingPathComponent("native.cape")
                _ = try await runProcess(tool, ["defaults-export", cape.path])
                // Native reset is independent of the selected custom theme.
                activeApplication = nil
                _ = try await runProcess(tool, ["apply-replace", cape.path, root.appendingPathComponent("native-reset-recovery.cape").path])
                library.inUse = nil; try? persist()
                status = "nativeRestored"; refresh()
            } catch { self.error = error.localizedDescription; status = "applyFailed" }
        }
    }
}
