import SwiftUI
import AppKit
import UniformTypeIdentifiers

@_silgen_name("MeowHoverCursor") func MeowHoverCursor(_ inside: Int32)
// AppKit owns cursor updates separately from SwiftUI's visual hover state.
/// The Purin face shown next to the app name (also the source of the app icon).
let brandLogo = Bundle.main.image(forResource: "logo") ?? NSImage()
struct SecondaryCopy: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
    }
}
struct ButtonCursorRegion: NSViewRepresentable {
    var enabled: Bool
    func makeNSView(context: Context) -> Region { Region() }
    func updateNSView(_ view: Region, context: Context) {
        if view.enabled != enabled {
            view.enabled = enabled
            view.window?.invalidateCursorRects(for: view)
        }
    }
    final class RegisteredHand: NSCursor {
        override func set() { MeowHoverCursor(1) }
    }
    final class Region: NSView {
        var enabled = true
        private let hand = RegisteredHand(image: NSCursor.pointingHand.image, hotSpot: NSCursor.pointingHand.hotSpot)
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() {
            if enabled { addCursorRect(visibleRect, cursor: hand) }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .cursorUpdate, .mouseEnteredAndExited], owner: self, userInfo: nil))
        }
        override func cursorUpdate(with event: NSEvent) { if enabled { hand.set() } }
        override func mouseEntered(with event: NSEvent) { if enabled { hand.set() } }
        override func mouseExited(with event: NSEvent) { MeowHoverCursor(0) }
    }
}
struct SmallActionStyle: ButtonStyle {
    var primary = false
    var row = false
    var selected = false
    var borderless = false
    func makeBody(configuration: Configuration) -> some View {
        Action(configuration: configuration, primary: primary, row: row, selected: selected, borderless: borderless)
    }
    struct Action: View {
        let configuration: ButtonStyle.Configuration
        let primary: Bool
        let row: Bool
        let selected: Bool
        let borderless: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) var enabled
        @Environment(\.accessibilityReduceMotion) var reduceMotion
        var pressed: Bool { enabled && configuration.isPressed }
        var fill: Color {
            if pressed { return primary ? accentPressed : apricotPressed }
            if hovered && enabled { return primary ? accent.opacity(0.85) : apricot }
            return primary ? accent : (selected ? apricot.opacity(0.65) : (borderless ? Color.clear : surface))
        }
        var body: some View {
            configuration.label
                .padding(.horizontal, row ? 0 : 9).padding(.vertical, row ? 0 : 5)
                .foregroundStyle(primary ? onAccent : ink)
                .background(fill, in: RoundedRectangle(cornerRadius: row ? 10 : 6))
                .overlay(RoundedRectangle(cornerRadius: row ? 10 : 6)
                    .stroke(accent.opacity(borderless ? 0 : (pressed ? 0.95 : (hovered && enabled ? 0.7 : 0.25))), lineWidth: pressed ? 1.5 : 1))
                .shadow(color: .black.opacity(borderless || pressed ? 0 : (hovered && enabled ? 0.10 : 0.04)), radius: 2, y: pressed ? 0 : 1)
                .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .background(ButtonCursorRegion(enabled: enabled))
                .onHover { inside in hovered = inside }
                .onChange(of: enabled) { if !enabled && hovered { MeowHoverCursor(0) } }
                .onDisappear { if hovered { MeowHoverCursor(0) } }
        }
    }
}

struct CursorPreview: View {
    let asset: PreviewAsset
    let size: Double
    /// Frames already drawn in a pixel/jagged style at this size; shown without smoothing.
    var styled: [NSImage]? = nil
    var hotspot: [Double]?
    var mark = false
    var update: (([Double]) -> Void)?
    /// Single-click picking (magic wand) instead of dragging the hotspot.
    var pick: (([Double]) -> Void)?
    var body: some View {
        let info = asset.info
        let maximum = info.aligned_canvas_px.max()!
        let w = size * info.aligned_canvas_px[0] / maximum
        let h = size * info.aligned_canvas_px[1] / maximum
        let hot = hotspot ?? [info.hotspot_points[0] / (128 * info.aligned_canvas_px[0] / maximum), info.hotspot_points[1] / (128 * info.aligned_canvas_px[1] / maximum)]
        TimelineView(.animation(minimumInterval: max(0.016, info.frame_duration_seconds))) { time in
            let steps = info.playback_frames
            let index = Int(time.date.timeIntervalSinceReferenceDate / max(0.016, info.frame_duration_seconds)) % steps.count
            ZStack(alignment: .topLeading) {
                Image(nsImage: (styled ?? asset.frames)[steps[index]]).resizable().interpolation(styled == nil ? .high : .none).frame(width: w, height: h)
                if mark {
                    Path { p in
                        let x = hot[0] * w, y = hot[1] * h
                        p.move(to: CGPoint(x: x - 5, y: y)); p.addLine(to: CGPoint(x: x + 5, y: y))
                        p.move(to: CGPoint(x: x, y: y - 5)); p.addLine(to: CGPoint(x: x, y: y + 5))
                    }.stroke(accent, lineWidth: 1)
                }
            }.frame(width: w, height: h).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard pick == nil else { return }
                    update?([min(0.999999, max(0, value.location.x / w)), min(0.999999, max(0, value.location.y / h))])
                }.onEnded { value in
                    pick?([min(1, max(0, value.location.x / w)), min(1, max(0, value.location.y / h))])
                })
        }
    }
}

struct ContentView: View {
    @ObservedObject var studio: Studio
    @State var path = ""
    @State var targeted = false
    @State var showHotspot = true
    @State var confirmDelete = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                header
                rolePicker
                ScrollView {
                    if let slot = studio.slot { editor(slot) }
                }
                footer
            }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity).background(canvas)
        }.foregroundStyle(ink).tint(accent)
            .frame(minWidth: 1060, minHeight: 780)
            .disabled(studio.busy || !studio.ready)
            .overlay { if studio.busy { VStack(spacing: 12) { ProgressView(); Text(studio.t("processing")) }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } }
            .sheet(isPresented: Binding(get: { studio.timeline != nil }, set: { if !$0 { studio.timeline = nil } })) {
                TimelineSheet(studio: studio, frames: studio.timeline ?? [])
            }
            .sheet(isPresented: $studio.calibrating) {
                if let slot = studio.slot, let asset = studio.cache[slot.preview] {
                    CalibrationSheet(studio: studio, asset: asset, size: slot.size, start: studio.hotNormalized(slot), styled: studio.styledFrames(slot))
                }
            }
            .alert(studio.t("errorTitle"), isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
                Button(studio.t("ok")) { studio.error = nil }
            } message: { Text(studio.t("errorDetail") + "\n\n" + (studio.error ?? "")) }
            .alert(studio.t("deleteTitle"), isPresented: $confirmDelete) {
                Button(studio.t("cancel"), role: .cancel) {}
                Button(studio.t("delete"), role: .destructive) { studio.remove() }
            } message: { Text(studio.t("deleteMessage")) }
            // Don't start with the caret in the theme name: keystrokes typed
            // while the app launches would silently rename the theme.
            .onAppear { DispatchQueue.main.async { NSApp.windows.forEach { $0.makeFirstResponder(nil) } } }
            .onChange(of: studio.ready) { if studio.ready { DispatchQueue.main.async { NSApp.windows.forEach { $0.makeFirstResponder(nil) } } } }
            .onChange(of: studio.role) { path = ""; studio.wandActive = false }
            .onChange(of: studio.library.selected) { path = ""; studio.wandActive = false }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand
            HStack(spacing: 10) {
                Image(nsImage: brandLogo)
                    .resizable().interpolation(.high).scaledToFit().frame(width: 34, height: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AniOnMac").font(.title3.bold())
                    Text("v" + studio.appVersion).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }.padding(.top, 14).padding(.bottom, 18)

            // Theme list
            HStack(spacing: 6) {
                Text(studio.t("myThemes")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(studio.library.profiles.count)").font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1).background(apricot.opacity(0.7), in: Capsule())
                Spacer()
                // Theme actions grouped like a Finder sidebar toolbar.
                HStack(spacing: 0) {
                    themeAction("plus", studio.t("addTheme")) { studio.add(copy: false) }
                    Divider().frame(height: 14)
                    themeAction("plus.square.on.square", studio.t("duplicate")) { studio.add(copy: true) }
                    Divider().frame(height: 14)
                    themeAction("trash", studio.t("delete")) { confirmDelete = true }.disabled(studio.library.profiles.count < 2)
                }.background(surface, in: Capsule()).overlay(Capsule().stroke(accent.opacity(0.25)))
            }.padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(studio.library.profiles.enumerated()), id: \.element.id) { index, p in themeRow(p, number: index + 1) }
                }
            }

            Divider().padding(.vertical, 14)

            // Footer
            VStack(alignment: .leading, spacing: 8) {
                Label(studio.t("autoSave"), systemImage: "checkmark.circle").modifier(SecondaryCopy())
                    .help(studio.t("copyHint").replacingOccurrences(of: "\n", with: "，"))
                HStack(spacing: 6) {
                    Button(studio.t("aboutShort")) { showAbout(studio) }.buttonStyle(.link)
                    Text("·").foregroundStyle(.secondary)
                    Link(destination: projectURL) { Text("GitHub") }.help(studio.t("authorLine") + " · " + projectURL.absoluteString)
                    Text("·").foregroundStyle(.secondary)
                    Button { studio.checkForUpdates() } label: {
                        Label(studio.t("checkUpdates"), systemImage: "arrow.triangle.2.circlepath")
                    }.buttonStyle(.link).disabled(studio.checkingUpdates)
                }.font(.system(size: 11)).tint(accent).lineLimit(1)
            }.padding(.top, 14)
        }.padding(.horizontal, 16).padding(.bottom, 16).frame(width: 248).frame(maxHeight: .infinity).background(cream)
    }
    func themeAction(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 22).contentShape(Rectangle())
                .accessibilityLabel(label)
        }.buttonStyle(.borderless).foregroundStyle(accent).help(label)
    }
    func themeRow(_ p: Profile, number: Int) -> some View {
        let selected = p.id == studio.library.selected
        let inUse = p.id == studio.library.inUse
        let filled = p.slots.filter { !$0.asset.isEmpty }.count
        return Button { studio.select(p.id) } label: {
            HStack(spacing: 9) {
                Text(String(format: "%02d", number)).font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(selected ? accent : Color.secondary).frame(width: 18)
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(surface.opacity(0.9))
                    if let slot = p.slots.first(where: { !$0.preview.isEmpty }), let asset = studio.cache[slot.preview] {
                        CursorPreview(asset: asset, size: 24).allowsHitTesting(false)
                    } else { Image(systemName: "cursorarrow").foregroundStyle(.secondary) }
                }.frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(p.name.isEmpty ? studio.t("untitled") : p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if inUse {
                            Text(studio.t("inUse")).font(.system(size: 9, weight: .bold)).foregroundStyle(onAccent).lineLimit(1).fixedSize()
                                .padding(.horizontal, 5).padding(.vertical, 1).background(accent, in: Capsule())
                                .accessibilityLabel(studio.t("inUse"))
                        }
                    }
                    Text("\(filled) / 4 · " + studio.t("modes")).modifier(SecondaryCopy()).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 8).padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(SmallActionStyle(row: true, selected: selected, borderless: true)).frame(maxWidth: .infinity)
            .help(inUse ? studio.t("inUseHint") : "")
    }
    var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(studio.t("themeName"), text: Binding(get: { studio.profile?.name ?? "" }, set: { studio.rename($0) }))
                    .font(.system(size: 26, weight: .semibold)).textFieldStyle(.plain).accessibilityLabel(studio.t("themeName"))
                Text(studio.t("subtitle")).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Menu {
                    Picker(studio.t("appearance"), selection: Binding(get: { studio.library.appearance }, set: { studio.setAppearance($0) })) {
                        ForEach(appearanceModes, id: \.self) { mode in Text(studio.t("appearance_" + mode)).tag(mode) }
                    }.pickerStyle(.inline).labelsHidden()
                } label: {
                    Label(studio.t("appearance_" + studio.library.appearance), systemImage: "circle.lefthalf.filled")
                }.menuStyle(.borderlessButton).fixedSize().help(studio.t("appearance"))
                Menu {
                    Picker(studio.t("language"), selection: Binding(get: { studio.library.language }, set: { studio.setLanguage($0) })) {
                        Text(studio.t("languageSystem")).tag("system")
                        ForEach(studio.languages, id: \.code) { lang in Text(lang.name).tag(lang.code) }
                    }.pickerStyle(.inline).labelsHidden()
                } label: {
                    Label(studio.library.language == "system" ? studio.t("languageSystem") : studio.t("languageName"), systemImage: "globe")
                }.menuStyle(.borderlessButton).fixedSize().help(studio.t("language"))
            }
        }
    }
    var rolePicker: some View {
        HStack(spacing: 8) {
            ForEach(roles, id: \.self) { role in
                Button { studio.role = role } label: {
                    HStack(spacing: 8) {
                        Group {
                            if let slot = studio.profile?.slots.first(where: { $0.role == role }), let asset = studio.cache[slot.preview] {
                                CursorPreview(asset: asset, size: 28).allowsHitTesting(false)
                            } else {
                                Image(systemName: symbols[role]!)
                            }
                        }.frame(width: 32, height: 32).accessibilityHidden(true)
                        Text(studio.t(role))
                    }.font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(SmallActionStyle(row: true, selected: studio.role == role, borderless: true))
            }
        }
    }
    func editor(_ slot: Slot) -> some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(studio.t("importHeading")).font(.caption.weight(.semibold)).foregroundStyle(accent)
                    Spacer()
                    if !slot.asset.isEmpty { Button(studio.t("clearMode")) { studio.clearSlot() }.buttonStyle(SmallActionStyle()).font(.caption) }
                }
                dropZone(slot)
                HStack {
                    TextField(studio.t("pathPlaceholder"), text: $path).textFieldStyle(.roundedBorder).onSubmit { importPath() }
                    Button(studio.t("import")) { importPath() }.buttonStyle(SmallActionStyle()).disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Divider()
                HStack {
                    Text(studio.t("sizeHeading")).font(.caption.weight(.semibold)).foregroundStyle(accent)
                    Spacer(); Text("\(Int(slot.size)) pt").monospacedDigit()
                }
                Slider(value: Binding(get: { studio.slot?.size ?? 32 }, set: { studio.size($0) }), in: 8...128, step: 1).accessibilityLabel(studio.t("sizeHeading"))
                HStack(spacing: 12) {
                    Button(studio.t("resetSize")) { studio.size(32) }
                    Button(studio.t("allSizes")) { studio.allSizes() }
                }.buttonStyle(SmallActionStyle()).font(.caption)
                HStack(spacing: 10) {
                    Text(studio.t("styleHeading")).font(.caption)
                    Picker(studio.t("styleHeading"), selection: Binding(get: { studio.slot?.style ?? "smooth" }, set: { studio.setStyle($0) })) {
                        ForEach(["smooth", "pixel", "jagged"], id: \.self) { Text(studio.t("style." + $0)).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }.disabled(slot.asset.isEmpty)
                Text(studio.t("styleHint." + (slot.style ?? "smooth"))).modifier(SecondaryCopy()).fixedSize(horizontal: false, vertical: true)
                Divider()
                hotspotEditor(slot)
                Divider()
                backgroundEditor(slot)
                if slot.role == "pointing" { Text(studio.t("pointingHint")).modifier(SecondaryCopy()) }
            }.frame(maxWidth: .infinity)
            previewPanel(slot).frame(maxWidth: .infinity)
        }.padding(22).background(surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
    }
    func dropZone(_ slot: Slot) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 25, weight: .light)).foregroundStyle(accent)
            Text(studio.t("dropHint")).font(.system(size: 14, weight: .medium))
            Text(slot.filename.isEmpty ? studio.t("animationHint") : slot.filename).modifier(SecondaryCopy()).lineLimit(2)
            HStack(spacing: 10) {
                Button(studio.t("chooseFile")) { studio.chooseFile() }.buttonStyle(SmallActionStyle()).controlSize(.large)
                Picker(studio.t("frameInterval"), selection: $studio.frameInterval) {
                    ForEach(Studio.frameIntervals, id: \.self) { ms in Text("\(ms) ms").tag(ms) }
                }.pickerStyle(.menu).fixedSize().font(.caption).help(studio.t("frameIntervalHint"))
            }
        }.frame(maxWidth: .infinity).frame(height: 170).background(targeted ? apricot.opacity(0.6) : cream, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                guard !providers.isEmpty else { return false }
                // Collect every dropped file, then import once: one .ani, or images/folders as frames.
                let group = DispatchGroup()
                let lock = NSLock()
                var urls: [URL] = []
                for provider in providers {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url: URL? = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        if let url { lock.lock(); urls.append(url); lock.unlock() }
                        group.leave()
                    }
                }
                group.notify(queue: .main) { let dropped = urls; Task { @MainActor in studio.importItems(dropped) } }
                return true
            }
    }
    func backgroundEditor(_ slot: Slot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(studio.t("backgroundHeading")).font(.caption.weight(.semibold)).foregroundStyle(accent)
                Spacer()
                if slot.originalAsset != nil {
                    Button(studio.t("restoreOriginal")) { studio.restoreOriginal() }.buttonStyle(SmallActionStyle()).font(.caption)
                }
            }
            HStack(spacing: 10) {
                Button { studio.wandActive = false; studio.knockout(mode: "auto") } label: {
                    Label(studio.t("autoRemove"), systemImage: "person.crop.rectangle")
                }.buttonStyle(SmallActionStyle())
                Button { studio.wandActive.toggle() } label: {
                    Label(studio.t("magicWand"), systemImage: "wand.and.stars")
                }.buttonStyle(SmallActionStyle(selected: studio.wandActive))
            }.font(.caption).disabled(slot.asset.isEmpty)
            HStack(spacing: 8) {
                Text(studio.t("tolerance")).font(.caption)
                Slider(value: $studio.wandTolerance, in: 8...160, step: 1).accessibilityLabel(studio.t("tolerance"))
                Text("\(Int(studio.wandTolerance))").font(.caption).monospacedDigit().frame(width: 28, alignment: .trailing)
            }.disabled(slot.asset.isEmpty)
            Text(studio.t(studio.wandActive ? "wandActiveHint" : "backgroundHint")).modifier(SecondaryCopy()).fixedSize(horizontal: false, vertical: true)
        }
    }
    func hotspotEditor(_ slot: Slot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(studio.t("hotspotHeading")).font(.caption.weight(.semibold)).foregroundStyle(accent)
                Spacer()
                Button { studio.calibrating = true } label: { Label(studio.t("calibrate"), systemImage: "scope") }
                    .buttonStyle(SmallActionStyle()).font(.caption).help(studio.t("calibrateTip"))
                    .disabled(slot.asset.isEmpty || studio.cache[slot.preview] == nil)
                Button(studio.t("resetHotspot")) { studio.setHotspot(nil) }.buttonStyle(SmallActionStyle()).font(.caption)
            }
            HStack {
                ForEach(0..<2, id: \.self) { axis in
                    Text(axis == 0 ? "X" : "Y").font(.caption)
                    TextField("0", value: hotspotBinding(slot, axis), format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).accessibilityLabel(axis == 0 ? "Hotspot X" : "Hotspot Y")
                }
                Text("pt").modifier(SecondaryCopy())
            }.disabled(slot.asset.isEmpty)
            Text(studio.t("hotspotHint")).modifier(SecondaryCopy()).fixedSize(horizontal: false, vertical: true)
        }
    }
    func hotspotBinding(_ slot: Slot, _ axis: Int) -> Binding<Double> {
        let info = studio.cache[slot.preview]?.info
        let dimensions = info?.aligned_canvas_px ?? [1, 1]
        let length = slot.size * dimensions[axis] / dimensions.max()!
        return Binding(get: { studio.hotNormalized(studio.slot ?? slot)[axis] * length }, set: { value in
            guard value.isFinite else { return }
            var hot = studio.hotNormalized(studio.slot ?? slot); hot[axis] = value / length; studio.setHotspot(hot)
        })
    }
    func previewPanel(_ slot: Slot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(studio.t("preview")).font(.headline); Spacer()
                Text(studio.t("actualSize")).font(.caption).foregroundStyle(accent).padding(7).background(cream, in: Capsule())
            }
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(surface)
                if studio.wandActive { Checkerboard().clipShape(RoundedRectangle(cornerRadius: 16)) }
                if let asset = studio.cache[slot.preview] {
                    if studio.wandActive {
                        // Enlarged so a colour can be picked precisely; transparency shows as a checkerboard.
                        CursorPreview(asset: asset, size: 240, hotspot: studio.hotNormalized(slot), mark: false,
                                      pick: { studio.knockout(mode: "wand", point: $0) })
                            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                    } else {
                        CursorPreview(asset: asset, size: slot.size, styled: studio.styledFrames(slot), hotspot: studio.hotNormalized(slot), mark: showHotspot, update: { studio.setHotspot($0) })
                    }
                } else { Text(studio.t("noCursor")).font(.callout).foregroundStyle(.secondary) }
            }.frame(height: 310).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.gray.opacity(0.12)))
            Toggle(studio.t("showHotspot"), isOn: $showHotspot).toggleStyle(.checkbox).font(.caption)
            Text(studio.t("previewHint") + "\n" + studio.t("markerHint")).modifier(SecondaryCopy()).fixedSize(horizontal: false, vertical: true)
        }
    }
    func importPath() {
        var input = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("\"") && input.hasSuffix("\"") { input = String(input.dropFirst().dropLast()) }
        let url = input.hasPrefix("file://") ? URL(string: input) : URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        if let url { studio.importItems([url]) }
    }
    /// Bottom toolbar: status on the left, every system-level action grouped on the right.
    var footer: some View {
        VStack(spacing: 12) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: statusSymbol).foregroundStyle(statusSymbol == "exclamationmark.triangle.fill" ? Color.orange : accent)
                    .font(.system(size: 13)).accessibilityHidden(true)
                Text(studio.t(studio.status)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                Button { studio.restoreNative() } label: { Label(studio.t("nativeReset"), systemImage: "arrow.counterclockwise.circle").padding(.horizontal, 4) }
                    .buttonStyle(SmallActionStyle()).help(studio.t("nativeHint"))
                Button { studio.restore() } label: { Label(studio.t("undo"), systemImage: "arrow.uturn.backward").padding(.horizontal, 4) }
                    .buttonStyle(SmallActionStyle()).disabled(!studio.canUndo)
                Button { studio.apply() } label: { Label(studio.t(studio.isApplied ? "alreadyApplied" : "apply"), systemImage: "checkmark").padding(.horizontal, 10) }
                    .buttonStyle(SmallActionStyle(primary: true)).disabled(!studio.canApply)
                    .keyboardShortcut(.return, modifiers: .command)
            }.controlSize(.large)
        }
    }
    var statusSymbol: String {
        switch studio.status {
        case "applyFailed", "loadFailed", "refreshWarning", "nothingRemoved": return "exclamationmark.triangle.fill"
        case "applied", "alreadyApplied", "nativeRestored", "imported", "backgroundRemoved", "restored", "originalRestored", "calibrateDone": return "checkmark.circle.fill"
        default: return "info.circle"
        }
    }
}


@MainActor func showAbout(_ studio: Studio) {
    let body = NSMutableParagraphStyle(); body.alignment = .center; body.paragraphSpacing = 6
    let text = NSMutableAttributedString()
    let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: body]
    text.append(NSAttributedString(string: studio.t("aboutDescription") + "\n", attributes: plain))
    text.append(NSAttributedString(string: studio.t("authorLine") + "\n", attributes: plain))
    text.append(NSAttributedString(string: projectURL.absoluteString, attributes: plain.merging([.link: projectURL]) { $1 }))
    NSApp.orderFrontStandardAboutPanel(options: [.credits: text])
    NSApp.activate(ignoringOtherApps: true)
}

@main struct CursorApp: App {
    @StateObject var studio = Studio()
    var body: some Scene {
        Window("AniOnMac", id: "main") { ContentView(studio: studio) }.defaultSize(width: 1160, height: 900)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .appInfo) {
                    Button(studio.t("about")) { showAbout(studio) }
                    Button(studio.t("checkUpdates") + "…") { studio.checkForUpdates() }.disabled(studio.checkingUpdates)
                }
                CommandGroup(replacing: .help) { Link(studio.t("projectPage"), destination: projectURL) }
            }
    }
}

/// Transparency checkerboard shown behind the enlarged preview while removing backgrounds.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}

/// Timeline for several still images: check the order (filename 1, 2, 3… by default),
/// drag or nudge frames to reorder, drop unwanted ones, preview, then build the animation.
struct TimelineSheet: View {
    @ObservedObject var studio: Studio
    @State var frames: [URL]
    @State private var dragging: URL?
    private let thumbs: [URL: NSImage]

    init(studio: Studio, frames: [URL]) {
        self.studio = studio
        _frames = State(initialValue: frames)
        thumbs = Dictionary(uniqueKeysWithValues: frames.map { ($0, NSImage(contentsOf: $0) ?? NSImage()) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(studio.t("timelineTitle")).font(.title3.weight(.semibold))
                Spacer()
                Text("\(frames.count) / 24 " + studio.t("frames")).monospacedDigit()
                    .foregroundStyle(frames.count > 24 ? Color.red : .secondary)
            }
            Text(studio.t("timelineHint")).modifier(SecondaryCopy()).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 18) {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(frames.enumerated()), id: \.element) { index, url in frameCard(index, url) }
                    }.padding(4)
                }.frame(height: 150)
                VStack(spacing: 8) {
                    ZStack {
                        Checkerboard().clipShape(RoundedRectangle(cornerRadius: 12))
                        TimelineView(.animation(minimumInterval: Double(studio.frameInterval) / 1000)) { context in
                            let step = frames.isEmpty ? 0 : Int(context.date.timeIntervalSinceReferenceDate * 1000 / Double(studio.frameInterval)) % frames.count
                            if !frames.isEmpty, let image = thumbs[frames[step]] { Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(10) }
                        }
                    }.frame(width: 130, height: 130).overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.25)))
                    Text(studio.t("preview")).modifier(SecondaryCopy())
                }
            }
            HStack(spacing: 10) {
                Button(studio.t("sortByName")) { frames = Studio.imageFrames(frames) }.buttonStyle(SmallActionStyle())
                Button(studio.t("reverseOrder")) { frames.reverse() }.buttonStyle(SmallActionStyle())
                Picker(studio.t("frameInterval"), selection: $studio.frameInterval) {
                    ForEach(Studio.frameIntervals, id: \.self) { ms in Text("\(ms) ms").tag(ms) }
                }.pickerStyle(.menu).fixedSize()
                Spacer()
                Button(studio.t("cancel")) { studio.timeline = nil }.buttonStyle(SmallActionStyle()).keyboardShortcut(.cancelAction)
                Button(studio.t("createAnimation")) {
                    let chosen = frames
                    studio.timeline = nil
                    studio.importFrames(chosen)
                }.buttonStyle(SmallActionStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(frames.isEmpty || frames.count > 24)
            }.font(.caption)
        }.padding(22).frame(width: 760).background(canvas).foregroundStyle(ink).tint(accent)
    }

    func frameCard(_ index: Int, _ url: URL) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                Checkerboard().clipShape(RoundedRectangle(cornerRadius: 10))
                if let image = thumbs[url] { Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(6) }
                Text("\(index + 1)").font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(onAccent)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(accent, in: Capsule()).padding(4)
            }.frame(width: 84, height: 84)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.2)))
            Text(url.lastPathComponent).font(.caption2).lineLimit(1).truncationMode(.middle).frame(width: 84)
            HStack(spacing: 4) {
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.left").accessibilityLabel(studio.t("moveEarlier")) }.disabled(index == 0).help(studio.t("moveEarlier"))
                Button { frames.remove(at: index) } label: { Image(systemName: "xmark").accessibilityLabel(studio.t("removeFrame")) }.help(studio.t("removeFrame"))
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.right").accessibilityLabel(studio.t("moveLater")) }.disabled(index == frames.count - 1).help(studio.t("moveLater"))
            }.buttonStyle(.borderless).font(.caption2)
        }
        .onDrag { dragging = url; return NSItemProvider(object: url.absoluteString as NSString) }
        .onDrop(of: [.text], delegate: FrameDrop(target: url, frames: $frames, dragging: $dragging))
    }

    func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard frames.indices.contains(target) else { return }
        frames.swapAt(index, target)
    }
}

/// Live reordering while a frame card is dragged across the timeline.
struct FrameDrop: DropDelegate {
    let target: URL
    @Binding var frames: [URL]
    @Binding var dragging: URL?
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target, let from = frames.firstIndex(of: dragging), let to = frames.firstIndex(of: target) else { return }
        withAnimation(.easeOut(duration: 0.12)) { frames.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

/// Hotspot calibration. Inside the pad the pointer is the cursor being edited, at its real size.
/// The user puts the tip they see on each dot and clicks; the click lands on the current hotspot,
/// so the average gap says where the hotspot should be.
struct CalibrationSheet: View {
    @ObservedObject var studio: Studio
    let start: [Double]
    let width: Double, height: Double
    let cursor: NSCursor
    @State private var offsets: [CGPoint] = []
    @State private var slipped = false
    static let targets: [CGPoint] = [CGPoint(x: 0.2, y: 0.28), CGPoint(x: 0.8, y: 0.28), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.2, y: 0.74), CGPoint(x: 0.8, y: 0.74)]

    init(studio: Studio, asset: PreviewAsset, size: Double, start: [Double], styled: [NSImage]? = nil) {
        self.studio = studio
        self.start = start
        let dims = asset.info.aligned_canvas_px, maximum = dims.max()!
        width = size * dims[0] / maximum
        height = size * dims[1] / maximum
        let frame = (styled ?? asset.frames)[asset.info.playback_frames.first ?? 0]
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in frame.draw(in: rect); return true }
        let hot = NSPoint(x: min(width - 1, max(0, start[0] * width)), y: min(height - 1, max(0, start[1] * height)))
        cursor = NSCursor(image: image, hotSpot: hot)
    }

    var done: Bool { offsets.count >= Self.targets.count }

    /// Mean offset (dot minus click, in points) without the click furthest from the rest, and the corrected hotspot.
    var solved: (dx: Double, dy: Double, hot: [Double]) {
        var used = offsets
        if used.count >= 4 {
            let mx = used.map(\.x).reduce(0, +) / Double(used.count), my = used.map(\.y).reduce(0, +) / Double(used.count)
            if let worst = used.indices.max(by: { a, b in
                hypot(used[a].x - mx, used[a].y - my) < hypot(used[b].x - mx, used[b].y - my) }) { used.remove(at: worst) }
        }
        guard !used.isEmpty else { return (0, 0, start) }
        let dx = used.map(\.x).reduce(0, +) / Double(used.count), dy = used.map(\.y).reduce(0, +) / Double(used.count)
        return (dx, dy, [min(0.999999, max(0, start[0] + dx / max(1, width))), min(0.999999, max(0, start[1] + dy / max(1, height)))])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(studio.t("calibrateTitle")).font(.title3.weight(.semibold))
                Spacer()
                Text(studio.t("calibrateProgress", "\(min(offsets.count + 1, Self.targets.count))", "\(Self.targets.count)"))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Text(studio.t("calibrateHint")).modifier(SecondaryCopy()).fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14).fill(surface)
                    CalibrationPad(cursor: cursor) { point in click(point, in: geo.size) }
                    if done {
                        result.frame(width: geo.size.width, height: geo.size.height).allowsHitTesting(false)
                    } else {
                        let t = Self.targets[offsets.count]
                        target.position(x: t.x * geo.size.width, y: t.y * geo.size.height).allowsHitTesting(false)
                    }
                }
            }.frame(height: 320).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.gray.opacity(0.18)))
            if slipped { Text(studio.t("calibrateTooFar")).font(.caption).foregroundStyle(.orange) }
            HStack(spacing: 10) {
                Button(studio.t("calibrateAgain")) { offsets = []; slipped = false }.buttonStyle(SmallActionStyle())
                Spacer()
                Button(studio.t("cancel")) { studio.calibrating = false }.buttonStyle(SmallActionStyle()).keyboardShortcut(.cancelAction)
                Button(studio.t("useHotspot")) {
                    let hot = solved.hot
                    studio.calibrating = false
                    studio.setHotspot(hot)
                    studio.status = "calibrateDone"
                }.buttonStyle(SmallActionStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(!done)
            }.font(.caption)
        }.padding(22).frame(width: 600).background(canvas).foregroundStyle(ink).tint(accent)
    }

    var target: some View {
        ZStack {
            Circle().stroke(accent, lineWidth: 2)
            Circle().fill(accent).frame(width: 6, height: 6)
            Rectangle().fill(accent.opacity(0.45)).frame(width: 1)
            Rectangle().fill(accent.opacity(0.45)).frame(height: 1)
        }.frame(width: 30, height: 30)
    }

    var result: some View {
        let r = solved
        func signed(_ v: Double) -> String { (v >= 0 ? "+" : "") + String(format: "%.1f", v) + " pt" }
        return VStack(spacing: 8) {
            Text(abs(r.dx) < 1 && abs(r.dy) < 1 ? studio.t("calibrateAccurate") : studio.t("calibrateResult", signed(r.dx), signed(r.dy)))
                .font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            Text(studio.t("calibrateNewHotspot", String(format: "%.1f pt", r.hot[0] * width), String(format: "%.1f pt", r.hot[1] * height)))
                .modifier(SecondaryCopy())
        }.padding(20)
    }

    func click(_ point: CGPoint, in size: CGSize) {
        guard !done else { return }
        let t = Self.targets[offsets.count]
        let offset = CGPoint(x: t.x * size.width - point.x, y: t.y * size.height - point.y)
        slipped = hypot(offset.x, offset.y) > max(width, height) + 24
        if !slipped { offsets.append(offset) }
    }
}

/// The calibration pad: shows the given cursor and reports clicks (top-left origin, in points).
struct CalibrationPad: NSViewRepresentable {
    let cursor: NSCursor
    let click: (CGPoint) -> Void
    func makeNSView(context: Context) -> Pad { Pad() }
    func updateNSView(_ view: Pad, context: Context) {
        view.cursor = cursor
        view.click = click
        view.window?.invalidateCursorRects(for: view)
    }
    final class Pad: NSView {
        var cursor = NSCursor.arrow
        var click: ((CGPoint) -> Void)?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil))
        }
        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func mouseMoved(with event: NSEvent) { cursor.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
        override func mouseDown(with event: NSEvent) {
            cursor.set()
            click?(convert(event.locationInWindow, from: nil))
        }
    }
}
