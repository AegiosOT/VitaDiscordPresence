import AppKit
import PresenceKit
import SwiftUI

/// The menu bar symbol, which sums up the state at a glance.
enum MenuBarIcon: Equatable {
    /// A presence is showing on Discord.
    case presence
    /// The user has to do something: allow Local Network access, fix the client ID or the settings.
    case attention
    /// Anything else: stopped, connecting, or nothing to show.
    case standby

    init(snapshot: PresenceSnapshot, hasSettingsIssues: Bool) {
        if hasSettingsIssues || Self.needsAttention(snapshot) {
            self = .attention
        } else if snapshot.publishedActivity != nil {
            self = .presence
        } else {
            self = .standby
        }
    }

    /// A symbol when the menu bar should not show the app icon. The app icon itself covers presence and standby.
    var systemImage: String? {
        switch self {
        case .attention: "exclamationmark.triangle"
        case .presence, .standby: nil
        }
    }

    private static func needsAttention(_ snapshot: PresenceSnapshot) -> Bool {
        switch snapshot.vita {
        case .misconfigured, .failing(.localNetworkDenied, _), .failing(.severalVitas, _): true
        default: snapshot.discord == .unavailable(.invalidClientID)
        }
    }
}

/// The menu bar icon. Attention keeps the warning symbol. Everything else is the Vita from the app icon.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        image
            .accessibilityLabel("VitaPresence")
    }

    @ViewBuilder private var image: some View {
        if let symbol = model.menuBarIcon.systemImage {
            Image(systemName: symbol)
        } else if let icon = MenuBarArtwork.cached {
            Image(nsImage: icon)
                .renderingMode(.template)
        }
    }
}

/// Turns the app icon into a menu-bar template. The blue background and the screen drop out, and the shell stays.
enum MenuBarArtwork {
    /// Built once. Walking the app icon is more work than a menu bar redraw should repeat.
    static let cached = template(named: "AppIcon")

    static func template(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = NSImage(contentsOf: url) else { return nil }
        let side = 256
        guard let bitmap = rgbaBitmap(side: side), let data = bitmap.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        let count = side * side
        var background = [Bool](repeating: false, count: count)
        var queue = [(Int, Int)]()
        queue.reserveCapacity(side * 4)
        for x in 0..<side {
            queue.append((x, 0))
            queue.append((x, side - 1))
        }
        for y in 1..<(side - 1) {
            queue.append((0, y))
            queue.append((side - 1, y))
        }
        var head = 0
        while head < queue.count {
            let (x, y) = queue[head]
            head += 1
            let index = y * side + x
            if background[index] { continue }
            let (red, green, blue) = pixel(data, x, y, side)
            if !isBackground(red, green, blue) { continue }
            background[index] = true
            if x > 0 { queue.append((x - 1, y)) }
            if x + 1 < side { queue.append((x + 1, y)) }
            if y > 0 { queue.append((x, y - 1)) }
            if y + 1 < side { queue.append((x, y + 1)) }
        }

        // The screen is the largest region inside the shell that is not the black body.
        var seen = [Bool](repeating: false, count: count)
        var screen = [Bool](repeating: false, count: count)
        var best = [Int]()
        for y in 0..<side {
            for x in 0..<side {
                let start = y * side + x
                if background[start] || seen[start] { continue }
                let (red, green, blue) = pixel(data, x, y, side)
                if isBezel(red, green, blue) {
                    seen[start] = true
                    continue
                }
                var component = [Int]()
                var pending = [start]
                seen[start] = true
                var pendingHead = 0
                while pendingHead < pending.count {
                    let index = pending[pendingHead]
                    pendingHead += 1
                    component.append(index)
                    let cx = index % side
                    let cy = index / side
                    for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)] {
                        guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
                        let next = ny * side + nx
                        if seen[next] || background[next] { continue }
                        let (nr, ng, nb) = pixel(data, nx, ny, side)
                        if isBezel(nr, ng, nb) { continue }
                        seen[next] = true
                        pending.append(next)
                    }
                }
                if component.count > best.count { best = component }
            }
        }
        for index in best { screen[index] = true }

        let outputSide = 36
        guard let output = rgbaBitmap(side: outputSide), let outputData = output.bitmapData else { return nil }
        output.size = NSSize(width: 18, height: 18)
        for y in 0..<outputSide {
            for x in 0..<outputSide {
                let x0 = x * side / outputSide
                let x1 = max(x0 + 1, (x + 1) * side / outputSide)
                let y0 = y * side / outputSide
                let y1 = max(y0 + 1, (y + 1) * side / outputSide)
                var body = 0
                var hole = 0
                var samples = 0
                for yy in y0..<y1 {
                    for xx in x0..<x1 {
                        samples += 1
                        let index = yy * side + xx
                        if background[index] { continue }
                        if screen[index] { hole += 1 } else { body += 1 }
                    }
                }
                let alpha = hole > body ? 0 : 255 * body / max(samples, 1)
                let offset = (y * outputSide + x) * 4
                outputData[offset] = 0
                outputData[offset + 1] = 0
                outputData[offset + 2] = 0
                outputData[offset + 3] = UInt8(alpha)
            }
        }
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.addRepresentation(output)
        image.isTemplate = true
        return image
    }

    private static func rgbaBitmap(side: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4,
            bitsPerPixel: 32
        )
    }

    private static func pixel(_ data: UnsafeMutablePointer<UInt8>, _ x: Int, _ y: Int, _ side: Int) -> (Int, Int, Int) {
        let offset = (y * side + x) * 4
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }

    /// The icon's backdrop is a blue gradient. The console is not.
    private static func isBackground(_ red: Int, _ green: Int, _ blue: Int) -> Bool {
        blue - max(red, green) > 40
    }

    /// The black shell. The screen glass is bluer than this, so it is not included.
    private static func isBezel(_ red: Int, _ green: Int, _ blue: Int) -> Bool {
        max(red, green, blue) < 80 && abs(red - green) < 18 && abs(green - blue) < 18 && abs(red - blue) < 18
    }
}
