import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreImage

struct ConversionError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ConversionError(text: message) }
}
struct Bytes {
    var data: Data
    func uint(_ offset: Int, _ length: Int = 4) throws -> Int {
        try require(offset >= 0 && offset + length <= data.count, "Truncated ANI data")
        return (0..<length).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
    }
    func chunks(_ start: Int, _ end: Int) throws -> [(String, Data)] {
        var result: [(String, Data)] = [], offset = start
        while offset < end {
            try require(offset + 8 <= end, "Truncated RIFF header")
            let size = try uint(offset + 4), next = offset + 8 + size
            try require(next <= end, "RIFF chunk exceeds container")
            result.append((String(decoding: data[offset..<offset + 4], as: UTF8.self), data.subdata(in: offset + 8..<next)))
            offset = next + size % 2
        }
        return result
    }
}
func le(_ value: Int, _ length: Int) -> Data { Data((0..<length).map { UInt8((value >> ($0 * 8)) & 255) }) }
struct ANIFrame { let image: CGImage; let x: Int; let y: Int }
struct ANI {
    let frames: [ANIFrame]
    let sequence: [Int]
    let rates: [Int]
    init(url: URL) throws {
        let b = Bytes(data: try Data(contentsOf: url))
        try require(b.data.count >= 12 && b.data.count <= 64 * 1024 * 1024, "ANI size must be between 12 bytes and 64 MiB")
        try require(String(decoding: b.data.prefix(4), as: UTF8.self) == "RIFF" && String(decoding: b.data[8..<12], as: UTF8.self) == "ACON", "Expected a Windows ANI file")
        try require(try b.uint(4) + 8 == b.data.count, "RIFF size mismatch")
        var fields: [String: Data] = [:], images: [ANIFrame] = []
        for (tag, payload) in try b.chunks(12, b.data.count) {
            if tag == "LIST", String(decoding: payload.prefix(4), as: UTF8.self) == "fram" {
                for (kind, frame) in try Bytes(data: payload).chunks(4, payload.count) where kind == "icon" {
                    try require(images.count < 1024, "Too many ANI frames")
                    images.append(try Self.decodeCUR(frame))
                }
            } else if ["anih", "rate", "seq "].contains(tag) {
                try require(fields[tag] == nil, "Duplicate ANI metadata")
                fields[tag] = payload
            }
        }
        guard let header = fields["anih"], header.count == 36 else { throw ConversionError(text: "Unsupported ANI header") }
        let h = Bytes(data: header), count = try h.uint(4), steps = try h.uint(8), flags = try h.uint(32)
        try require(try h.uint(0) == 36 && flags & 1 == 1 && count == images.count && count > 0 && steps > 0 && steps <= 4096, "Invalid ANI frame count or flags")
        func values(_ field: String, fallback: [Int]) throws -> [Int] {
            guard let raw = fields[field] else { return fallback }
            try require(raw.count == steps * 4, "Invalid ANI sequence or rate count")
            return try (0..<steps).map { try Bytes(data: raw).uint($0 * 4) }
        }
        if flags & 2 != 0 { try require(fields["seq "] != nil, "Missing ANI sequence") }
        let sequence = flags & 2 != 0 ? try values("seq ", fallback: []) : Array(0..<count)
        let rates = try values("rate", fallback: Array(repeating: try h.uint(28), count: steps))
        try require(sequence.count == steps && sequence.allSatisfy { $0 < count }, "Invalid animation sequence")
        try require(rates.allSatisfy { $0 > 0 && $0 <= 36000 }, "Invalid animation timing")
        self.frames = images; self.sequence = sequence; self.rates = rates
    }
    static func decodeCUR(_ data: Data) throws -> ANIFrame {
        let b = Bytes(data: data), count = try b.uint(4, 2)
        try require(try b.uint(0, 2) == 0 && b.uint(2, 2) == 2 && count > 0 && count <= 128 && 6 + 16 * count <= data.count, "Expected CUR frames with hotspots")
        var best: (Int, Int, Int, Int, Data)?
        for i in 0..<count {
            let o = 6 + 16 * i
            let w0 = try b.uint(o, 1), h0 = try b.uint(o + 1, 1)
            let w = w0 == 0 ? 256 : w0, h = h0 == 0 ? 256 : h0
            let x = try b.uint(o + 4, 2), y = try b.uint(o + 6, 2), size = try b.uint(o + 8), start = try b.uint(o + 12)
            try require(start >= 6 + 16 * count && start + size <= data.count && x < w && y < h, "Invalid CUR bounds or hotspot")
            if best == nil || w * h > best!.0 * best!.1 { best = (w, h, x, y, data.subdata(in: start..<start + size)) }
        }
        let (w, h, x, y, pixels) = best!
        var ico = le(0, 2) + le(1, 2) + le(1, 2)
        ico.append(contentsOf: [UInt8(w % 256), UInt8(h % 256), 0, 0])
        ico += le(1, 2) + le(32, 2) + le(pixels.count, 4) + le(22, 4) + pixels
        let encoded = pixels.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) ? pixels : ico
        guard let source = CGImageSourceCreateWithData(encoded as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConversionError(text: "macOS could not decode the CUR image") }
        try require(image.width == w && image.height == h, "CUR dimensions disagree")
        return ANIFrame(image: image, x: x, y: y)
    }
}
func canvas(_ w: Int, _ h: Int) throws -> CGContext {
    try require(w > 0 && h > 0 && w * h <= 32 * 1024 * 1024, "Cursor bitmap is too large")
    guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ConversionError(text: "Cannot create bitmap") }
    context.interpolationQuality = .high
    return context
}
func png(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ConversionError(text: "Cannot encode PNG") }
    CGImageDestinationAddImage(dest, image, nil)
    try require(CGImageDestinationFinalize(dest), "PNG encoding failed")
    return data as Data
}
func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
let cursorIDs = ["arrow": "com.apple.coregraphics.Arrow", "pointing": "com.apple.cursor.13", "text": "com.apple.coregraphics.IBeam", "wait": "com.apple.coregraphics.Wait"]

func convert(_ source: URL, to output: URL, size: Double, hotspot: [Double]? = nil) throws -> ([String: Any], [String: Any]) {
    try require(size.isFinite && size >= 8 && size <= 128, "Size must be 8–128 points")
    let ani = try ANI(url: source)
    let left = ani.frames.map(\.x).max()!, top = ani.frames.map(\.y).max()!
    let width = left + ani.frames.map { $0.image.width - $0.x }.max()!
    let height = top + ani.frames.map { $0.image.height - $0.y }.max()!
    let scale = size / Double(max(width, height))
    let points = [Double(width) * scale, Double(height) * scale]
    var hot = [Double(left) * scale, Double(top) * scale]
    if let h = hotspot {
        try require(h.count == 2 && h.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 1 }, "Hotspot must lie inside the image")
        hot = [h[0] * points[0], h[1] * points[1]]
    }
    let tick = ani.rates.reduce(0, gcd)
    let total = ani.rates.reduce(0) { $0 + $1 / tick }
    try require(total <= 25, "This version of AniOnMac accepts at most 25 animation steps; preserving this ANI timing would exceed that limit")
    var playback = zip(ani.sequence, ani.rates).flatMap { Array(repeating: $0.0, count: $0.1 / tick) }
    // 25-step registration fails on the tested WindowServer. Prefer removing
    // an adjacent duplicate; otherwise resample by omitting the last step.
    if playback.count == 25 {
        let repeated = (1..<playback.count).first { playback[$0] == playback[$0 - 1] }
        playback.remove(at: repeated ?? (playback.count - 1))
    }
    let outputSteps = playback.count
    let frameDuration = Double(tick * total) / 60 / Double(outputSteps)
    try require(!FileManager.default.fileExists(atPath: output.path), "Output folder already exists")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var aligned: [CGImage] = []
    for (index, frame) in ani.frames.enumerated() {
        let context = try canvas(width, height)
        context.draw(frame.image, in: CGRect(x: left - frame.x, y: height - (top - frame.y) - frame.image.height, width: frame.image.width, height: frame.image.height))
        let image = context.makeImage()!
        aligned.append(image)
        try png(image).write(to: output.appendingPathComponent(String(format: "frame-%03d.png", index)))
    }
    var reps: [Data] = []
    for density in [1, 2] {
        let w = max(1, Int((points[0] * Double(density)).rounded())), h = max(1, Int((points[1] * Double(density)).rounded()))
        let context = try canvas(w, h * outputSteps)
        for (step, index) in playback.enumerated() {
            context.draw(aligned[index], in: CGRect(x: 0, y: (outputSteps - 1 - step) * h, width: w, height: h))
        }
        reps.append(try png(context.makeImage()!))
    }
    let metadata: [String: Any] = ["aligned_canvas_px": [width, height], "hotspot_points": hot, "playback_frames": playback, "frame_duration_seconds": frameDuration, "source_steps": total]
    let cursor: [String: Any] = ["PointsWide": points[0], "PointsHigh": points[1], "HotSpotX": hot[0], "HotSpotY": hot[1], "FrameCount": outputSteps, "FrameDuration": frameDuration, "Representations": reps]
    return (metadata, cursor)
}

/// Build a standard Windows ANI from ordered still images (e.g. 1.png, 2.png…)
/// or from one animated GIF / APNG / WebP. Every frame is centred on one shared
/// canvas (longest side ≤ 256 px, aspect kept) and stored as a PNG-compressed
/// CUR so `ANI(url:)` reads it back.
let maxComposeFrames = 24

/// All frames of an image file, with per-frame delays when it is animated.
func readFrames(_ url: URL) throws -> [(image: CGImage, delay: Double?)] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
        throw ConversionError(text: "macOS could not decode \(url.lastPathComponent)")
    }
    let count = CGImageSourceGetCount(source)
    try require(count <= 1000, "\(url.lastPathComponent) has too many frames")
    return try (0..<count).map { index in
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw ConversionError(text: "macOS could not decode \(url.lastPathComponent)") }
        try require(image.width <= 4096 && image.height <= 4096, "\(url.lastPathComponent) is larger than 4096 px")
        guard count > 1, let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return (image, nil) }
        let groups: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)]
        for (group, unclamped, clamped) in groups {
            if let dict = props[group] as? [CFString: Any], let value = (dict[unclamped] ?? dict[clamped]) as? Double {
                return (image, value < 0.02 ? 0.1 : value)   // browsers treat ~0 delays as 100 ms
            }
        }
        return (image, 0.1)
    }
}

/// Cut out the subject with Vision's foreground mask (macOS 14+).
func subjectCutout(_ image: CGImage) -> CGImage? {
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil, let result = request.results?.first, !result.allInstances.isEmpty,
          let buffer = try? result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false) else { return nil }
    return CIContext().createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: image.width, height: image.height))
}

typealias RGB = (Double, Double, Double)

/// Un-premultiplied colour at (x, y) with y counted from the top; nil when (nearly) transparent.
func colorAt(_ context: CGContext, _ x: Int, _ y: Int) -> RGB? {
    guard x >= 0, y >= 0, x < context.width, y < context.height, let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let i = y * context.bytesPerRow + x * 4, a = Double(data[i + 3])
    guard a >= 128 else { return nil }
    return (Double(data[i]) * 255 / a, Double(data[i + 1]) * 255 / a, Double(data[i + 2]) * 255 / a)
}

/// Average of the opaque corners: the usual solid background colour.
func cornerKey(_ context: CGContext) -> RGB? {
    let w = context.width, h = context.height
    let colors = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)].compactMap { colorAt(context, $0.0, $0.1) }
    guard !colors.isEmpty else { return nil }
    let n = Double(colors.count)
    return (colors.reduce(0) { $0 + $1.0 } / n, colors.reduce(0) { $0 + $1.1 } / n, colors.reduce(0) { $0 + $1.2 } / n)
}

func borderSeeds(_ w: Int, _ h: Int) -> [Int] {
    (0..<w).flatMap { [$0, (h - 1) * w + $0] } + (0..<h).flatMap { [$0 * w, $0 * w + w - 1] }
}

/// Magic-wand removal: flood-fill from `seeds` through pixels within `tolerance`
/// of `key`, so the same colour inside the subject is kept; edges are feathered.
/// Returns the number of pixels made transparent.
@discardableResult
func floodRemove(_ context: CGContext, seeds: [Int], key: RGB, tolerance: Double) -> Int {
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
    let w = context.width, h = context.height, row = context.bytesPerRow
    func distance(_ i: Int) -> Double {
        let a = Double(data[i + 3]); if a < 8 { return 0 }
        let r = Double(data[i]) * 255 / a - key.0, g = Double(data[i + 1]) * 255 / a - key.1, b = Double(data[i + 2]) * 255 / a - key.2
        return (r * r + g * g + b * b).squareRoot()
    }
    var removed = [Bool](repeating: false, count: w * h), stack = seeds, count = 0
    while let p = stack.popLast() {
        if p < 0 || p >= w * h || removed[p] { continue }
        let x = p % w, y = p / w, i = y * row + x * 4
        if distance(i) > tolerance { continue }
        removed[p] = true
        if data[i + 3] > 0 { count += 1 }
        data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 0
        if x > 0 { stack.append(p - 1) }; if x < w - 1 { stack.append(p + 1) }
        if y > 0 { stack.append(p - w) }; if y < h - 1 { stack.append(p + w) }
    }
    for y in 0..<h { for x in 0..<w where !removed[y * w + x] {
        let near = (x > 0 && removed[y * w + x - 1]) || (x < w - 1 && removed[y * w + x + 1]) || (y > 0 && removed[(y - 1) * w + x]) || (y < h - 1 && removed[(y + 1) * w + x])
        guard near else { continue }
        let i = y * row + x * 4, keep = min(1, distance(i) / (tolerance * 2))
        for c in 0..<4 { data[i + c] = UInt8(Double(data[i + c]) * keep) }
    } }
    return count
}

/// Write a Windows ANI (PNG-compressed CUR frames, each with its own hotspot).
func writeANI(_ frames: [ANIFrame], sequence: [Int]? = nil, rates: [Int]? = nil, jiffies: Int, to output: URL) throws {
    try require(!frames.isEmpty && frames.allSatisfy { $0.image.width <= 256 && $0.image.height <= 256 }, "Cursor frames must be 1–256 px")
    var list = Data()
    for frame in frames {
        let w = frame.image.width, h = frame.image.height, pixels = try png(frame.image)
        var cur = le(0, 2) + le(2, 2) + le(1, 2)
        cur.append(contentsOf: [UInt8(w % 256), UInt8(h % 256), 0, 0])
        cur += le(min(frame.x, w - 1), 2) + le(min(frame.y, h - 1), 2) + le(pixels.count, 4) + le(22, 4) + pixels
        list += Data("icon".utf8) + le(cur.count, 4) + cur
        if cur.count % 2 == 1 { list.append(0) }
    }
    let steps = sequence?.count ?? rates?.count ?? frames.count
    let header = [36, frames.count, steps, 0, 0, 0, 0, jiffies, sequence == nil ? 1 : 3].reduce(Data()) { $0 + le($1, 4) }
    var body = Data("ACON".utf8) + Data("anih".utf8) + le(36, 4) + header
    if let sequence { body += Data("seq ".utf8) + le(sequence.count * 4, 4) + sequence.reduce(Data()) { $0 + le($1, 4) } }
    if let rates { body += Data("rate".utf8) + le(rates.count * 4, 4) + rates.reduce(Data()) { $0 + le($1, 4) } }
    body += Data("LIST".utf8) + le(4 + list.count, 4) + Data("fram".utf8) + list
    try require(!FileManager.default.fileExists(atPath: output.path), "Output file already exists")
    try (Data("RIFF".utf8) + le(body.count, 4) + body).write(to: output)
    _ = try ANI(url: output)
}

func compose(images: [URL], jiffies: Int, hotspot: [Double], to output: URL) throws -> [String: Any] {
    try require(!images.isEmpty, "Select at least one image")
    try require(jiffies >= 1 && jiffies <= 600, "Frame duration must be 1–600 jiffies (1/60 s)")
    try require(hotspot.count == 2 && hotspot.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 1 }, "Hotspot must lie inside the image")
    var decoded: [CGImage]
    var rate = jiffies
    let first = try readFrames(images[0])
    if images.count == 1, first.count > 1 {
        // One animated file (GIF / APNG / WebP): keep its own timing, sample evenly down to the frame limit.
        let total = first.reduce(0) { $0 + ($1.delay ?? 0.1) }
        let keep = min(first.count, maxComposeFrames)
        decoded = (0..<keep).map { first[$0 * first.count / keep].image }
        rate = max(1, min(600, Int((total * 60 / Double(keep)).rounded())))
    } else {
        decoded = try images.flatMap { try readFrames($0).map(\.image) }
        try require(decoded.count <= maxComposeFrames, "At most \(maxComposeFrames) images can form one animated cursor")
    }
    let sourceW = decoded.map(\.width).max()!, sourceH = decoded.map(\.height).max()!
    let fit = min(1, 256 / Double(max(sourceW, sourceH)))
    let w = max(1, Int((Double(sourceW) * fit).rounded())), h = max(1, Int((Double(sourceH) * fit).rounded()))
    let hx = min(w - 1, Int(hotspot[0] * Double(w))), hy = min(h - 1, Int(hotspot[1] * Double(h)))
    let frames: [ANIFrame] = try decoded.map { image in
        let context = try canvas(w, h)
        let iw = Double(image.width) * fit, ih = Double(image.height) * fit
        context.draw(image, in: CGRect(x: (Double(w) - iw) / 2, y: (Double(h) - ih) / 2, width: iw, height: ih))
        return ANIFrame(image: context.makeImage()!, x: hx, y: hy)
    }
    try writeANI(frames, jiffies: rate, to: output)
    return ["ani": output.path, "frames": frames.count, "canvas_px": [w, h], "jiffies": rate]
}

/// Background removal on an existing cursor, keeping frame order, timing and hotspots.
/// mode "auto": Vision subject cut-out, falling back to the edge colour per frame.
/// mode "wand": remove the connected region of the colour at `point` (normalized,
/// top-left origin, in the aligned canvas the preview shows).
func knockout(_ input: URL, mode: String, point: [Double]?, tolerance: Double, to output: URL) throws -> [String: Any] {
    try require(["auto", "wand"].contains(mode), "Unknown background removal mode")
    try require(tolerance.isFinite && tolerance >= 1 && tolerance <= 255, "Tolerance must be 1–255")
    let ani = try ANI(url: input)
    let left = ani.frames.map(\.x).max()!, top = ani.frames.map(\.y).max()!
    let width = left + ani.frames.map { $0.image.width - $0.x }.max()!
    let height = top + ani.frames.map { $0.image.height - $0.y }.max()!
    var aligned: (Double, Double)?
    if mode == "wand" {
        guard let p = point, p.count == 2, p.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw ConversionError(text: "Pick a point on the preview") }
        aligned = (p[0] * Double(width), p[1] * Double(height))
    }
    var key: RGB?, removed = 0, cutouts = 0
    var frames: [ANIFrame] = []
    for frame in ani.frames {
        let w = frame.image.width, h = frame.image.height
        let context = try canvas(w, h)
        if mode == "auto", let cut = subjectCutout(frame.image) {
            context.draw(cut, in: CGRect(x: 0, y: 0, width: w, height: h)); cutouts += 1
        } else {
            context.draw(frame.image, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let (ax, ay) = aligned {
                // Map the aligned-canvas point into this frame (frames are aligned on their hotspots).
                let fx = Int(ax) - (left - frame.x), fy = Int(ay) - (top - frame.y)
                if key == nil { key = colorAt(context, fx, fy) }
                if let key, fx >= 0, fy >= 0, fx < w, fy < h { removed += floodRemove(context, seeds: [fy * w + fx], key: key, tolerance: tolerance) }
            } else if let edge = cornerKey(context) {
                removed += floodRemove(context, seeds: borderSeeds(w, h), key: edge, tolerance: tolerance)
            }
        }
        frames.append(ANIFrame(image: context.makeImage()!, x: frame.x, y: frame.y))
    }
    let uniform = Set(ani.rates).count == 1 && ani.sequence == Array(0..<ani.frames.count)
    try writeANI(frames, sequence: uniform ? nil : ani.sequence, rates: uniform ? nil : ani.rates, jiffies: ani.rates.first ?? 6, to: output)
    return ["ani": output.path, "removed_pixels": removed, "subject_cutouts": cutouts, "frames": frames.count]
}

do {
    let args = CommandLine.arguments
    func json(_ path: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else { throw ConversionError(text: "Invalid configuration") }
        return value
    }
    func reply(_ response: [String: Any]) throws -> Never {
        print(String(decoding: try JSONSerialization.data(withJSONObject: response, options: .sortedKeys), as: UTF8.self))
        exit(0)
    }
    if args.count == 4, args[1] == "compose" {
        let config = try json(args[2])
        guard let paths = config["images"] as? [String] else { throw ConversionError(text: "Invalid compose configuration") }
        try reply(try compose(images: paths.map { URL(fileURLWithPath: $0) }, jiffies: config["jiffies"] as? Int ?? 6,
                              hotspot: config["hotspot"] as? [Double] ?? [0, 0], to: URL(fileURLWithPath: args[3])))
    }
    if args.count == 5, args[1] == "knockout" {
        let config = try json(args[3])
        try reply(try knockout(URL(fileURLWithPath: args[2]), mode: config["mode"] as? String ?? "auto", point: config["point"] as? [Double],
                               tolerance: config["tolerance"] as? Double ?? 48, to: URL(fileURLWithPath: args[4])))
    }
    try require(args.count == 4, "Usage: anicore preview ANI OUTPUT | export CONFIG OUTPUT | compose CONFIG OUTPUT.ani | knockout ANI CONFIG OUTPUT.ani")
    let input = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
    var response: [String: Any]
    if args[1] == "preview" {
        response = try convert(input, to: output, size: 128).0
    } else {
        try require(args[1] == "export", "Unknown converter command")
        guard let config = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [String: Any], let slots = config["slots"] as? [[String: Any]] else { throw ConversionError(text: "Invalid theme configuration") }
        try require(!slots.isEmpty && slots.count <= 4, "Select at least one cursor")
        var cursors: [String: Any] = [:]
        for slot in slots {
            guard let role = slot["role"] as? String, let identifier = cursorIDs[role], let path = slot["path"] as? String, let size = slot["size"] as? Double else { throw ConversionError(text: "Invalid cursor configuration") }
            try require(cursors[identifier] == nil, "Duplicate cursor mode")
            cursors[identifier] = try convert(URL(fileURLWithPath: path), to: output.appendingPathComponent(role), size: size, hotspot: slot["hotspot"] as? [Double]).1
        }
        let cape: [String: Any] = ["Cursors": cursors, "CapeName": config["name"] as? String ?? "Theme", "Version": 2.0, "MinimumVersion": 2.0]
        let path = output.appendingPathComponent("theme.cape")
        try PropertyListSerialization.data(fromPropertyList: cape, format: .xml, options: 0).write(to: path)
        response = ["cape": path.path]
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: response, options: .sortedKeys), as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
