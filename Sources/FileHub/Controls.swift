import AppKit
import SwiftUI

/// Buttons with visible states: hover shows what can be clicked, a click turns the button petrol
/// (or darker, if it already is), and a disabled button loses its fill so it never looks like a
/// neutral, active one.
struct HubButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        HubButtonBody(kind: kind, label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct HubButtonBody: View {
    let kind: HubButtonStyle.Kind
    let label: ButtonStyleConfiguration.Label
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovered = false

    private var metrics: (font: CGFloat, height: CGFloat, padding: CGFloat) {
        switch controlSize {
        case .mini, .small: (12, 24, 10)
        case .large, .extraLarge: (14, 34, 18)
        default: (13, 28, 12)
        }
    }

    private var base: NSColor {
        switch kind {
        case .primary: Darcula.main
        case .destructive: Darcula.dangerFill
        case .secondary: Darcula.raised
        }
    }

    private var fill: NSColor {
        guard isEnabled else { return .clear }
        if pressed { return kind == .secondary ? Darcula.selection : base.blended(withFraction: 0.3, of: .black)! }
        if hovered { return kind == .secondary ? Darcula.border : base.blended(withFraction: 0.15, of: .white)! }
        return base
    }

    private var stroke: NSColor {
        guard isEnabled else { return Darcula.raised }
        if kind != .secondary { return .clear }
        return pressed ? Darcula.ink : hovered ? Darcula.accent : Darcula.border
    }

    private var text: NSColor {
        guard isEnabled else { return Darcula.faint }
        return kind == .secondary && !pressed && !hovered ? Darcula.text : .white
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        label
            .font(.system(size: metrics.font, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, metrics.padding)
            .frame(minHeight: metrics.height)
            .foregroundStyle(Color(nsColor: text))
            .background(shape.fill(Color(nsColor: fill)))
            .overlay(shape.strokeBorder(Color(nsColor: stroke), lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
            .onChange(of: isEnabled) { _, enabled in if !enabled { hovered = false } }
    }
}

/// Square symbol button for the path bars: a large symbol, a field behind it on hover, petrol
/// with a white symbol while pressed.
struct HubIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HubIconBody(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct HubIconBody: View {
    let label: ButtonStyleConfiguration.Label
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let active = isEnabled && hovered
        label
            .font(.system(size: 15, weight: .medium))
            .frame(width: HubMetrics.control, height: HubMetrics.control)
            .foregroundStyle(Color(nsColor: !isEnabled ? Darcula.faint : pressed || active ? .white : Darcula.text))
            .background(shape.fill(Color(nsColor: !isEnabled ? .clear : pressed ? Darcula.selection : active ? Darcula.raised : .clear)))
            .overlay(shape.strokeBorder(Color(nsColor: isEnabled && pressed ? Darcula.ink : active ? Darcula.border : .clear), lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }
}

enum HubMetrics {
    /// Height of the symbol buttons and path fields in the path bars.
    static let control: CGFloat = 28
}

extension View {
    /// The look of an input field: dark fill, a border that lightens on hover and turns petrol
    /// while the field is in use.
    func hubField(hovered: Bool, active: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return padding(.horizontal, 8)
            .frame(height: HubMetrics.control)
            .background(shape.fill(Color(nsColor: hovered || active ? Darcula.raised : Darcula.surface)))
            .overlay(shape.strokeBorder(Color(nsColor: active ? Darcula.ink : hovered ? Darcula.accent : Darcula.raised),
                                        lineWidth: active ? 1.5 : 1))
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.12), value: active)
    }

    /// A neutral button with hover and click feedback.
    func secondaryAction() -> some View {
        buttonStyle(HubButtonStyle(kind: .secondary))
    }
}
