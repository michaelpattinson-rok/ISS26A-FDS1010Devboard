import AppKit

/// End text editing before dispatching a click elsewhere in the same window.
@MainActor
enum TextClickAway {
    static func handle(_ event: NSEvent) -> NSEvent {
        guard let window = event.window, !(window is NSSavePanel),
              let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor || editor.isEditable else { return event }

        if let content = window.contentView {
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            if isTextInput(content.hitTest(point), currentEditor: editor) { return event }
        }
        // Follow the standard end-editing path so formatted values are committed.
        // Leave the mouse event available to its original target.
        window.makeFirstResponder(nil)
        return event
    }

    private static func isTextInput(_ view: NSView?, currentEditor: NSTextView) -> Bool {
        var ancestor = view
        while let hit = ancestor {
            if hit === currentEditor { return true }
            if let field = hit as? NSTextField, field.isEditable && field.isEnabled { return true }
            if let editor = hit as? NSTextView, editor.isEditable { return true }
            if let scroll = hit as? NSScrollView,
               let editor = scroll.documentView as? NSTextView, editor.isEditable { return true }
            ancestor = hit.superview
        }
        return false
    }
}
