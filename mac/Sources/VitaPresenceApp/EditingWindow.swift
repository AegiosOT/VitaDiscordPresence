import AppKit

/// A window that handles the standard editing shortcuts itself. Text fields normally get ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z
/// and ⇧⌘Z from the Edit menu, which a menu bar app may not have, so this window sends the same actions along
/// the responder chain. ⌘W closes it. Other key equivalents, and actions nothing handles, go to `super`.
final class EditingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = Self.action(for: event), NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The action a standard editing shortcut sends, or `nil` for any other key.
    static func action(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown, let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        switch (event.modifierFlags.intersection([.command, .shift, .option, .control]), key) {
        case ([.command], "x"): return #selector(NSText.cut(_:))
        case ([.command], "c"): return #selector(NSText.copy(_:))
        case ([.command], "v"): return #selector(NSText.paste(_:))
        case ([.command], "a"): return #selector(NSText.selectAll(_:))
        // NSWindow implements these, but AppKit's headers don't declare them.
        case ([.command], "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        case ([.command], "w"): return #selector(NSWindow.performClose(_:))
        default: return nil
        }
    }
}
