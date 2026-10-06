import SwiftUI

/// A rounded rectangle of Liquid Glass on macOS 26, and the standard material on earlier systems.
/// `interactive` adds the system hover and press response on macOS 26.
struct GlassCard<Content: View>: View {
    var interactive = false
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            content
                .padding(16)
                .glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: 16))
        } else {
            content
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// Groups glass cards so nearby ones can be drawn together. On earlier systems it is just the content.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 16) {
                content
            }
        } else {
            content
        }
    }
}

/// The primary action: prominent glass on macOS 26, and a bordered prominent button before that.
struct ProminentButton: View {
    var title: String
    var isDisabled = false
    var action: () -> Void

    var body: some View {
        Group {
            if #available(macOS 26, *) {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
        .disabled(isDisabled)
    }

    private var button: some View {
        Button(title, action: action)
    }
}
