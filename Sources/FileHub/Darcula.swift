import AppKit
import SwiftUI

/// The look of all Hub apps: Darcula as in WebStorm and DiaryHub – always dark, neutral grey
/// surfaces, a grey accent for controls and selections; the app's main color only marks primary
/// actions and its own symbols. Mirrors `shared/Darcula.swift` in the StudioHub repo.
enum Darcula {
    /// Window, lists.
    static let background = color(0x2B2B2B)
    /// Panels such as the log.
    static let surface = color(0x313335)
    /// Controls and raised areas on a surface; also the row lines of lists.
    static let raised = color(0x3C3F41)
    static let border = color(0x4B4F52)
    static let text = color(0xC4C7CA)
    static let muted = color(0x8F9395)
    static let faint = color(0x65696C)
    static let accent = color(0x8A8E91)
    static let danger = color(0xF26B6B)
    /// Filled danger buttons, with white text.
    static let dangerFill = color(0xB91C1C)
    static let warn = color(0xF59E0B)
    static let success = color(0x3FBF63)

    /// FileHub's main color, petrol as in the icon: primary actions.
    static let main = color(0x0F8FA8)
    /// The main color lightened for symbols and text on the dark background.
    static let ink = color(0x3DBCD3)
    /// Selected segments and table rows: the graphite selection is light grey, light text on it
    /// reaches only 2–3.4:1; 55 % main color on the surface keeps white text above 5.9:1.
    static let selection = main.blended(withFraction: 0.45, of: surface)!

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Must run before `NSApplication.shared` exists – AppKit reads the accent color once when it starts.
    /// Without Xcode there is no asset catalog for an app accent color; the argument domain is not
    /// saved and wins over the system setting, so the app's controls turn graphite.
    static func prepare() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleAccentColor"] = -1
        arguments["AppleAquaColorVariant"] = 6
        arguments["AppleHighlightColor"] = "0.847059 0.847059 0.862745 Graphite"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// Dark for every window, sheet, alert and menu, whatever the system uses.
    @MainActor
    static func applyAppearance() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

extension View {
    /// Darcula for a whole window or sheet: its background (titlebar included), and the palette's
    /// text colors as the primary, secondary and tertiary foreground styles.
    @ViewBuilder
    func darculaWindow() -> some View {
        let styled = foregroundStyle(Color(nsColor: Darcula.text), Color(nsColor: Darcula.muted), Color(nsColor: Darcula.faint))
        if #available(macOS 15, *) {
            styled.containerBackground(Color(nsColor: Darcula.background), for: .window)
        } else {
            styled.background(Color(nsColor: Darcula.background)).background(DarculaWindowStyler())
        }
    }

    /// A primary action in the app's main color with white text, like DiaryHub's primary buttons.
    func primaryAction() -> some View {
        modifier(FilledAction(color: Darcula.main))
    }

    /// A segmented picker whose selected segment shows the selection color with white text.
    func darculaSegments() -> some View {
        pickerStyle(.segmented).tint(Color(nsColor: Darcula.selection))
    }

    /// A destructive action, filled red with white text.
    func destructiveAction() -> some View {
        modifier(FilledAction(color: Darcula.dangerFill))
    }
}

/// Filled only while enabled: a disabled prominent button keeps its color and looks active.
private struct FilledAction: ViewModifier {
    let color: NSColor
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: color))
                .foregroundStyle(.white)
        } else {
            content
        }
    }
}

/// macOS 14 has no window container background: paint the window and let the titlebar show it.
private struct DarculaWindowStyler: NSViewRepresentable {
    final class StylerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.backgroundColor = Darcula.background
            window.titlebarAppearsTransparent = true
        }
    }

    func makeNSView(context: Context) -> StylerView { StylerView() }
    func updateNSView(_ nsView: StylerView, context: Context) {}
}
