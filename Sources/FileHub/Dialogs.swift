import AppKit

/// Modal AppKit dialogs (SwiftUI alerts have no password fields or checkboxes).
@MainActor
enum Dialogs {
    static func confirm(title: String, message: String, action: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// First connection to an SFTP server: show the fingerprints, trust only after confirmation.
    static func confirmHostKey(server: ServerProfile, fingerprints: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(server.host) ist noch unbekannt"
        alert.informativeText = "Vergleiche die Fingerabdrücke mit den Angaben deines Hosters (z. B. im Kundenmenü oder per "
            + "`ssh-keygen -lf` auf dem Server). Nur bestätigen, wenn sie übereinstimmen – sonst kann jemand die Verbindung "
            + "umleiten. Danach prüft FileHub bei jeder Verbindung, dass der Server derselbe ist."
        let text = NSTextField(wrappingLabelWithString: fingerprints.joined(separator: "\n"))
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isSelectable = true
        text.frame = NSRect(x: 0, y: 0, width: 420, height: CGFloat(18 * max(fingerprints.count, 1)))
        alert.accessoryView = text
        alert.addButton(withTitle: "Abbrechen")
        alert.addButton(withTitle: "Fingerabdruck stimmt – verbinden")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Password for a connection; nil if cancelled.
    static func askPassword(server: ServerProfile, retry: Bool) -> (password: String, save: Bool)? {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 300, height: 24))
        field.placeholderString = "Passwort"
        let save = NSButton(checkboxWithTitle: "Im Schlüsselbund von macOS sichern", target: nil, action: nil)
        save.state = .on
        save.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        box.addSubview(field)
        box.addSubview(save)
        let alert = NSAlert()
        alert.messageText = retry ? "Anmeldung abgelehnt" : "Passwort für \(server.displayName)"
        alert.informativeText = retry
            ? "\(server.host) hat das Passwort für „\(server.user)“ abgelehnt. Bitte neu eingeben."
            : "\(server.proto.short)-Passwort von „\(server.user)“ auf \(server.host)."
        alert.accessoryView = box
        alert.addButton(withTitle: "Verbinden")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return (field.stringValue, save.state == .on)
    }

    static func text(title: String, message: String, value: String, action: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = value
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Permission bits as the usual grid of checkboxes plus the octal number; nil if cancelled.
    static func permissions(title: String, message: String, mode: Int) -> Int? {
        let editor = ModeEditor(mode: mode)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = editor.view
        alert.addButton(withTitle: "Ändern")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = editor.field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return editor.mode
    }

    static func chooseFolder(start: URL?, title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseKeyFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Privaten SSH-Schlüssel wählen"
        panel.message = "Die Datei ohne „.pub“, z. B. id_ed25519. Sie verlässt den Mac nie."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Export and import

    /// New password, entered twice; nil if cancelled.
    static func newPassword(servers: [String]) -> String? {
        let minimum = SetupTransfer.minPasswordLength
        var hint = "Mindestens \(minimum) Zeichen. Du brauchst es auf dem anderen Mac beim Importieren."
        while true {
            let first = secureField("Passwort", y: 30)
            let second = secureField("Passwort wiederholen", y: 0)
            first.nextKeyView = second
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
            box.addSubview(first)
            box.addSubview(second)
            let alert = NSAlert()
            alert.messageText = "Verbindungen exportieren"
            alert.informativeText = "Die Datei enthält \(Fmt.names(servers)) samt Passwörtern und wird mit diesem Passwort "
                + "verschlüsselt. \(hint)"
            alert.accessoryView = box
            alert.addButton(withTitle: "Weiter")
            alert.addButton(withTitle: "Abbrechen")
            alert.window.initialFirstResponder = first
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let password = first.stringValue
            if password.count < minimum {
                hint = "Das Passwort war zu kurz: mindestens \(minimum) Zeichen."
            } else if password != second.stringValue {
                hint = "Die beiden Eingaben stimmten nicht überein."
            } else {
                return password
            }
        }
    }

    static func password(file: String) -> String? {
        let field = secureField("Passwort", y: 0)
        let alert = NSAlert()
        alert.messageText = "Verbindungen importieren"
        alert.informativeText = "Passwort für „\(file)“, wie beim Exportieren vergeben."
        alert.accessoryView = field
        alert.addButton(withTitle: "Importieren")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func saveLocation() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Verbindungen exportieren"
        panel.nameFieldStringValue = SetupTransfer.fileName
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// AirDrop puts received files into Downloads.
    static func openLocation() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Verbindungen importieren"
        panel.message = "„\(SetupTransfer.fileName)“ wählen – auf einem anderen Mac mit „Verbindung → Verbindungen exportieren …“ angelegt."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func secureField(_ placeholder: String, y: CGFloat) -> NSSecureTextField {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: y, width: 300, height: 24))
        field.placeholderString = placeholder
        return field
    }
}

/// Checkboxes for owner, group and others plus the octal field, kept in sync.
@MainActor
final class ModeEditor: NSObject, NSTextFieldDelegate {
    private(set) var mode: Int
    let field = NSTextField()
    private var boxes: [NSButton] = []
    let view: NSView

    init(mode: Int) {
        self.mode = mode & 0o777
        let grid = NSGridView()
        view = grid
        super.init()
        grid.rowSpacing = 6
        grid.columnSpacing = 14
        grid.addRow(with: [NSGridCell.emptyContentView] + ["Lesen", "Schreiben", "Ausführen"].map(Self.label))
        for (row, who) in ["Besitzer", "Gruppe", "Alle"].enumerated() {
            var cells: [NSView] = [Self.label(who)]
            for column in 0..<3 {
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled))
                box.tag = 8 - (row * 3 + column)
                boxes.append(box)
                cells.append(box)
            }
            grid.addRow(with: cells)
        }
        field.delegate = self
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        field.setAccessibilityLabel("Rechte als Zahl")
        grid.addRow(with: [Self.label("Als Zahl"), field])
        grid.row(at: 4).topPadding = 6
        grid.cell(atColumnIndex: 1, rowIndex: 4).xPlacement = .leading
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3), verticalRange: NSRange(location: 4, length: 1))
        for column in 1...3 { grid.column(at: column).xPlacement = .center }
        grid.column(at: 0).xPlacement = .leading
        grid.frame.size = grid.fittingSize
        show()
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = Darcula.muted
        return label
    }

    private func show() {
        for box in boxes { box.state = mode & (1 << box.tag) == 0 ? .off : .on }
        field.stringValue = FileMode.octal(mode)
    }

    @objc private func toggled(_ sender: NSButton) {
        mode = boxes.reduce(0) { $0 | ($1.state == .on ? 1 << $1.tag : 0) }
        field.stringValue = FileMode.octal(mode)
    }

    func controlTextDidChange(_ notification: Notification) {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard (1...4).contains(text.count), let value = Int(text, radix: 8) else { return }
        mode = value & 0o777
        for box in boxes { box.state = mode & (1 << box.tag) == 0 ? .off : .on }
    }
}
