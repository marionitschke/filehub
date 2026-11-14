import SwiftUI

/// Edits a new or existing connection. Nothing is saved until "Sichern".
struct ServerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: ServerProfile
    @State private var draft: ServerProfile
    @State private var password = ""
    @State private var hasPassword = false
    @State private var removePassword = false
    @State private var knownHost = false
    @State private var problem: String?

    init(original: ServerProfile) {
        self.original = original
        _draft = State(initialValue: original)
    }

    private var isNew: Bool { model.isNew(original) }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Neue Verbindung" : "Verbindung bearbeiten")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("z. B. DiaryHub live"))
                    Picker("Protokoll", selection: $draft.proto) {
                        ForEach(TransferProtocol.allCases) { Text($0.label).tag($0) }
                    }
                    .darculaSegments()
                    .onChange(of: draft.proto) { old, new in
                        if draft.port == old.defaultPort { draft.port = new.defaultPort }
                    }
                    TextField("Server", text: $draft.host, prompt: Text("z. B. w0123456.kasserver.com"))
                    TextField("Port", value: $draft.port, format: .number.grouping(.never))
                    TextField("Benutzer", text: $draft.user)
                } footer: {
                    Text(draft.proto == .sftp
                         ? "SFTP läuft über SSH. Beim ersten Verbinden zeigt FileHub den Fingerabdruck des Servers zum Vergleich."
                         : "FTPS heißt FTP mit TLS (explizit, Port 21). Steuer- und Datenkanal sind verschlüsselt, das Zertifikat muss gültig sein.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Anmeldung") {
                    if draft.proto == .sftp {
                        Picker("Art", selection: $draft.auth) {
                            ForEach(AuthMethod.allCases) { Text($0.label).tag($0) }
                        }
                        .darculaSegments()
                    }
                    if draft.usesPassword {
                        SecureField("Passwort", text: $password,
                                    prompt: Text(hasPassword ? "gespeichert – leer lassen zum Behalten" : "wird im Schlüsselbund gesichert"))
                            .disabled(removePassword)
                        if hasPassword {
                            Toggle("Gespeichertes Passwort entfernen (beim Verbinden fragen)", isOn: $removePassword)
                        }
                    } else {
                        HStack {
                            TextField("Schlüsseldatei", text: $draft.keyPath)
                            Button("Wählen …") {
                                if let url = Dialogs.chooseKeyFile() {
                                    draft.keyPath = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                                }
                            }
                        }
                        Text("Hat der Schlüssel eine Passphrase, einmal im Terminal `ssh-add --apple-use-keychain \(draft.keyPath)` ausführen. Der öffentliche Teil (.pub) gehört auf den Server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if draft.proto == .sftp, knownHost {
                        HStack {
                            Label("Hostschlüssel bestätigt", systemImage: "checkmark.shield")
                                .foregroundStyle(Color(nsColor: Darcula.success))
                            Spacer()
                            Button("Vergessen …") {
                                if Dialogs.confirm(title: "Hostschlüssel vergessen?",
                                                   message: "Nur nötig, wenn der Hoster den Schlüssel nachweislich geändert hat. "
                                                    + "Beim nächsten Verbinden fragt FileHub den neuen Fingerabdruck ab.",
                                                   action: "Vergessen", destructive: true) {
                                    model.forgetHostKey(original)
                                    knownHost = false
                                }
                            }
                        }
                    }
                }

                Section("Startordner") {
                    TextField("Auf dem Server", text: $draft.remotePath, prompt: Text("Anmeldeordner"))
                    HStack {
                        TextField("Auf dem Mac", text: $draft.localPath, prompt: Text("Benutzerordner"))
                        Button("Wählen …") {
                            let start = draft.localPath.isEmpty ? nil : URL(fileURLWithPath: (draft.localPath as NSString).expandingTildeInPath)
                            if let url = Dialogs.chooseFolder(start: start, title: "Startordner auf dem Mac") {
                                draft.localPath = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                            }
                        }
                    }
                }

                Section {
                    TextField("Nie hochladen", text: $draft.neverUpload, prompt: Text("z. B. php/config.php, logs, backups"))
                    TextField("Zuletzt hochladen", text: $draft.uploadLast, prompt: Text("z. B. dist/version.txt, sw.js"))
                    TextField("Alte Daten beim Upload löschen", text: $draft.replaceOnUpload, prompt: Text("z. B. dist, assets/build"))
                } header: {
                    Text("Regeln beim Hochladen")
                } footer: {
                    Text("Muster getrennt durch Komma, passend auf das Ende des Zielpfads, * und ? erlaubt. Immer ausgelassen: "
                         + "\(SystemFiles.summary), dazu beim Hochladen \(SecretFiles.summary). "
                         + "„Alte Daten beim Upload löschen“: Liegt ein solcher Ordner direkt im Upload (z. B. dist, nicht vendor/lib/dist), "
                         + "löscht FileHub ihn vorher auf dem Server komplett, ohne Rückfrage (steht im Protokoll). "
                         + "Leer: nichts wird gelöscht.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: Darcula.danger))
                        .lineLimit(2)
                }
                Spacer()
                if !isNew {
                    Button("Löschen …", role: .destructive) {
                        model.deleteServer(original)
                        if model.editing == nil { dismiss() }
                    }
                    .destructiveAction()
                }
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .primaryAction()
            }
            .padding(14)
        }
        .frame(width: 580, height: 720)
        .darculaWindow()
        .task {
            let id = original.id, host = original.host, port = original.port
            let result = await Task.detached { (Keychain.hasPassword(for: id), HostKeys.isKnown(host: host, port: port)) }.value
            hasPassword = result.0
            knownHost = !host.isEmpty && result.1
        }
    }

    private func save() {
        do {
            try model.save(draft, password: draft.usesPassword ? password : nil, removePassword: draft.usesPassword && removePassword)
            dismiss()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
