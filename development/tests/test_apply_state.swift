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
        print("PASS: apply state, edits, reverted edits, empty theme, language, reset and busy state")
    }
}
