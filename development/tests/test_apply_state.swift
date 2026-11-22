import Foundation

@main struct ApplyStateTests {
    @MainActor static func main() {
        let studio = Studio()
        var theme = Profile(name: "Test")
        theme.slots[0].asset = "assets/test.ani"
        studio.library.profiles = [theme]
        studio.library.selected = theme.id
        precondition(studio.canApply)
        studio.activeApplication = theme
        precondition(studio.isApplied && !studio.canApply)
        studio.library.english = true
        studio.library.profiles[0].name = "Renamed"
        precondition(studio.isApplied, "Language and name do not change cursor settings")
        studio.library.profiles[0].slots[0].size = 48
        precondition(!studio.isApplied && studio.canApply)
        studio.library.profiles[0].slots = theme.slots
        precondition(studio.isApplied, "Returning to applied settings needs no reapply")
        studio.library.profiles[0].slots[0].hotspot = [0.2, 0.3]
        precondition(studio.canApply)
        studio.library.profiles[0].slots = theme.slots
        studio.library.profiles[0].slots[0].asset = "assets/replacement.ani"
        precondition(studio.canApply)
        studio.library.profiles[0].slots[0] = Slot(role: "arrow")
        precondition(!studio.canApply && !studio.isApplied)
        studio.library.profiles[0] = theme
        studio.activeApplication = nil
        precondition(studio.canApply, "Native reset or system restore invalidates applied state")
        studio.busy = true
        precondition(!studio.canApply)
        studio.busy = false

        // Older library.json files only carry the "english" flag.
        let legacy = #"{"profiles":[],"english":true}"#.data(using: .utf8)!
        var migrated = try! JSONDecoder().decode(Library.self, from: legacy)
        precondition(migrated.language == "en" && migrated.appearance == "system")
        precondition(try! JSONDecoder().decode(Library.self, from: #"{"profiles":[]}"#.data(using: .utf8)!).language == "system")
        precondition(try! JSONDecoder().decode(Library.self, from: #"{"profiles":[],"english":false}"#.data(using: .utf8)!).language == "system",
                     "The old default follows the system language")
        precondition(Library().language == "system" && Library().appearance == "system")
        migrated.appearance = "dark"; migrated.language = "zh-Hant"
        let roundTrip = try! JSONDecoder().decode(Library.self, from: JSONEncoder().encode(migrated))
        precondition(roundTrip.appearance == "dark" && roundTrip.language == "zh-Hant" && !roundTrip.english)
        precondition(try! JSONDecoder().decode(Library.self, from: #"{"profiles":[],"appearance":"neon"}"#.data(using: .utf8)!).appearance == "system")
        var tagged = Library(); tagged.inUse = "theme-1"
        precondition(try! JSONDecoder().decode(Library.self, from: JSONEncoder().encode(tagged)).inUse == "theme-1", "In-use tag persists")
        precondition(Library().inUse == nil)
        precondition(Studio.isNewer("v0.2.0", than: "0.1.1") && Studio.isNewer("0.1.10", than: "0.1.9"))
        precondition(!Studio.isNewer("v0.1.1", than: "0.1.1") && !Studio.isNewer("0.1", than: "0.1.0") && !Studio.isNewer("0.0.9", than: "0.1.1"))
        let frames = Studio.imageFrames([URL(fileURLWithPath: "/tmp/10.png"), URL(fileURLWithPath: "/tmp/2.png"), URL(fileURLWithPath: "/tmp/1.gif"), URL(fileURLWithPath: "/tmp/x.txt")])
        precondition(frames.map(\.lastPathComponent) == ["1.gif", "2.png", "10.png"], "Finder order, images only")
        print("PASS: apply state, edits, reverted edits, empty theme, language, reset and busy state, settings migration, update versions, frame order")
    }
}
