import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HSplitView {
                LocalPane()
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                RemotePane()
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            ActivityPanel()
                .frame(height: 168)
        }
        .navigationTitle("FileHub")
        .navigationSubtitle(model.connectionInfo?.summary ?? "")
        .toolbar { Toolbar() }
        .alert(model.notice?.title ?? "", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        ), presenting: model.notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .sheet(item: $model.editing) { profile in
            ServerEditor(original: profile)
                .environment(model)
        }
    }
}

struct Toolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .navigation) {
            if model.servers.isEmpty {
                Button {
                    model.newServer()
                } label: {
                    Label("Verbindung anlegen", systemImage: "plus")
                }
                .help("Erste Verbindung anlegen (⌘N)")
            } else {
                Picker("Verbindung", selection: $model.activeID) {
                    ForEach(model.servers) { server in
                        Text("\(server.displayName) · \(server.proto.short)").tag(Optional(server.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 240)
                .disabled(model.job != nil)
                .help("Verbindung wählen")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isOnline || model.connection == .connecting {
                Button {
                    model.disconnect()
                } label: {
                    Label("Trennen", systemImage: "xmark.circle")
                        .labelStyle(.titleAndIcon)
                }
                .help("Verbindung trennen (⇧⌘K)")
            } else {
                Button {
                    model.connect()
                } label: {
                    Label("Verbinden", systemImage: "lock.circle")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.activeServer == nil)
                .help("Mit der gewählten Verbindung verbinden (⌘K)")
            }
            Button {
                model.editServer()
            } label: {
                Label("Bearbeiten", systemImage: "slider.horizontal.3")
            }
            .disabled(model.activeServer == nil || model.job != nil)
            .help("Verbindung bearbeiten (⌘E)")
            Button {
                model.newServer()
            } label: {
                Label("Neue Verbindung", systemImage: "plus")
            }
            .disabled(model.job != nil)
            .help("Neue Verbindung anlegen (⌘N)")
        }
    }
}

// MARK: Columns

/// Column header: symbol, title, hint on the right.
struct PaneTitle<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
    }
}

struct LocalPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PaneTitle(symbol: model.localVolume?.symbol ?? "laptopcomputer",
                      title: model.localVolume.map { "Mac · \($0.name)" } ?? "Mac") {
                Text(Fmt.count(model.localRows.count, "Objekt", "Objekte"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.up", help: "Übergeordneter Ordner", disabled: model.localURL.path == "/") { model.localUp() }
                IconButton(symbol: "house", help: "Startordner der Verbindung (sonst Benutzerordner)") { model.localHome() }
                PlacesMenu()
                Button {
                    model.chooseLocalFolder()
                } label: {
                    Text(Places.display(model.localURL))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .help("Anderen Ordner wählen …")
                IconButton(symbol: "arrow.clockwise", help: "Neu einlesen (⌘R)") { model.loadLocal() }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            Divider()
            FileTable(side: .local, rows: model.localRows, selection: $model.localSelection,
                      dropEnabled: model.isOnline && model.job == nil,
                      onOpen: { model.openLocal($0) },
                      onDrop: { payload, folder in
                          if case .remote(let paths) = payload {
                              model.download(paths, into: folder.map { URL(fileURLWithPath: $0.id, isDirectory: true) })
                          }
                      },
                      onDelete: nil,
                      onFocus: { model.focusedPane = .local },
                      menu: { FileMenus.local($0, model: model) })
                .overlay {
                    if model.localRows.isEmpty {
                        Text("Leerer Ordner").foregroundStyle(.secondary)
                    }
                }
            Divider()
            HStack(spacing: 10) {
                Button("Im Finder zeigen") { model.revealLocal() }
                Spacer()
                Button {
                    model.uploadSelection()
                } label: {
                    Label("Hochladen", systemImage: "arrow.right.circle.fill")
                }
                .primaryAction()
                .disabled(!model.canTransfer || model.localSelection.isEmpty)
                .help("Auswahl in den aktuellen Server-Ordner hochladen – oder einfach nach rechts ziehen")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
    }
}

/// Places and mounted volumes (SSD, USB stick, network share) for the Mac column.
struct PlacesMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section("Ordner") {
                ForEach(Places.folders()) { place in
                    Button { model.openPlace(place) } label: { Label(place.name, systemImage: place.symbol) }
                }
            }
            Section("Laufwerke") {
                ForEach(model.volumes) { place in
                    Button { model.openPlace(place) } label: { Label(place.name, systemImage: place.symbol) }
                }
            }
            let ejectable = model.volumes.filter(\.ejectable)
            if !ejectable.isEmpty {
                Divider()
                Menu("Auswerfen") {
                    ForEach(ejectable) { place in
                        Button { model.eject(place) } label: { Label(place.name, systemImage: "eject") }
                    }
                }
            }
            Divider()
            Button("Anderer Ordner …") { model.chooseLocalFolder() }
        } label: {
            Image(systemName: "externaldrive")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ordner und angeschlossene Laufwerke")
    }
}

struct RemotePane: View {
    @Environment(AppModel.self) private var model
    @State private var pathText = ""
    @State private var showDetails = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PaneTitle(symbol: "server.rack", title: model.connectedServer?.displayName ?? model.activeServer?.displayName ?? "Server") {
                status
            }
            if model.isOnline {
                online
            } else {
                offline
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.connection {
        case .online(let info):
            Button {
                showDetails.toggle()
            } label: {
                Label(info.summary, systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: Darcula.success))
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help("Sicherheit der Verbindung")
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Verschlüsselte Verbindung", systemImage: "lock.fill")
                        .font(.headline)
                        .foregroundStyle(Color(nsColor: Darcula.success))
                    ForEach(info.details, id: \.self) { line in
                        Text(line).font(.caption).textSelection(.enabled)
                    }
                }
                .padding(14)
                .frame(minWidth: 320, alignment: .leading)
            }
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verbinde …").font(.caption).foregroundStyle(.secondary)
            }
        case .failed:
            Label("Nicht verbunden", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color(nsColor: Darcula.warn))
        case .offline:
            Label("Nicht verbunden", systemImage: "lock.open")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var online: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.up", help: "Übergeordneter Ordner", disabled: model.remotePath == "/" || model.job != nil) { model.remoteUp() }
                IconButton(symbol: "house", help: "Startordner der Verbindung", disabled: model.job != nil) { model.remoteHome() }
                TextField("Pfad", text: $pathText)
                    .textFieldStyle(.plain)
                    .onSubmit { model.goRemote(pathText) }
                    .disabled(model.job != nil)
                    .help("Pfad eingeben und mit ↩ öffnen")
                if model.remoteLoading {
                    ProgressView().controlSize(.small)
                }
                IconButton(symbol: "arrow.clockwise", help: "Neu einlesen (⌘R)", disabled: model.job != nil) { model.loadRemote() }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .onAppear { pathText = model.remotePath }
            .onChange(of: model.remotePath) { _, path in pathText = path }
            Divider()
            FileTable(side: .remote, rows: model.remoteRows, selection: $model.remoteSelection,
                      dropEnabled: model.canTransfer,
                      onOpen: { model.openRemote($0) },
                      onDrop: { payload, folder in
                          if case .local(let urls) = payload { model.upload(urls, into: folder?.id) }
                      },
                      onDelete: { model.deleteRemote() },
                      onFocus: { model.focusedPane = .remote },
                      menu: { FileMenus.remote($0, model: model) })
                .overlay {
                    if model.remoteRows.isEmpty, !model.remoteLoading {
                        Text("Leerer Ordner – Dateien hierher ziehen").foregroundStyle(.secondary)
                    }
                }
            Divider()
            HStack(spacing: 10) {
                Button("Neuer Ordner") { model.newRemoteFolder() }
                    .disabled(!model.canTransfer)
                    .help("Ordner im aktuellen Server-Ordner anlegen (⇧⌘N)")
                Button("Umbenennen") { model.renameRemote() }
                    .disabled(!model.canTransfer || model.remoteSelection.count != 1)
                    .help("Ausgewählten Eintrag auf dem Server umbenennen")
                Button("Löschen") { model.deleteRemote() }
                    .destructiveAction()
                    .disabled(!model.canTransfer || model.remoteSelection.isEmpty)
                    .help("Auswahl samt Inhalt vom Server löschen (mit Rückfrage)")
                Spacer()
                Button {
                    model.downloadSelection()
                } label: {
                    Label("Herunterladen", systemImage: "arrow.left.circle.fill")
                }
                .primaryAction()
                .disabled(!model.canTransfer || model.remoteSelection.isEmpty)
                .help("Auswahl in den aktuellen Mac-Ordner laden – oder einfach nach links ziehen")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
    }

    private var offline: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "externaldrive.badge.wifi")
                .font(.system(size: 40))
                .foregroundStyle(Color(nsColor: Darcula.ink))
            if let server = model.activeServer {
                Text("\(server.proto.label)\n\(server.user)@\(server.host):\(server.port)")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if model.connection == .connecting {
                    ProgressView()
                } else {
                    Button("Verbinden") { model.connect() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .primaryAction()
                }
                if case .failed(let message) = model.connection {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: Darcula.warn))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                        .textSelection(.enabled)
                }
            } else {
                Text("Noch keine Verbindung").font(.title3)
                Text("FileHub verbindet nur verschlüsselt: SFTP (SSH) oder FTPS (FTP über TLS).")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Verbindung anlegen …") { model.newServer() }
                    .controlSize(.large)
                    .primaryAction()
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Context menus

/// Context menus of the two lists: the usual actions for the clicked rows, or for the folder.
@MainActor
enum FileMenus {
    static func local(_ rows: [FileRow], model: AppModel) -> [FileMenuItem?] {
        let target = model.isOnline ? "„\(RemotePath.name(model.remotePath))“" : "den Server"
        guard !rows.isEmpty else {
            return [
                FileMenuItem(title: "Neuer Ordner …", symbol: "folder.badge.plus") { model.newLocalFolder() },
                FileMenuItem(title: "Im Finder zeigen", symbol: "macwindow") { model.revealLocal() },
                FileMenuItem(title: "Pfad kopieren", symbol: "doc.on.doc") { model.copyPaths(.local) },
                nil,
                FileMenuItem(title: "Aktualisieren", symbol: "arrow.clockwise") { model.loadLocal() },
            ]
        }
        let single = rows.count == 1 ? rows[0] : nil
        return [
            single?.isDirectory == true ? FileMenuItem(title: "Öffnen", symbol: "folder") { model.openLocal(rows[0]) } : nil,
            FileMenuItem(title: "Nach \(target) hochladen", symbol: "arrow.up.circle", enabled: model.canTransfer) { model.uploadSelection() },
            nil,
            FileMenuItem(title: "Im Finder zeigen", symbol: "macwindow") { model.revealLocal() },
            FileMenuItem(title: "Pfad kopieren", symbol: "doc.on.doc") { model.copyPaths(.local) },
            nil,
            FileMenuItem(title: "Umbenennen …", symbol: "pencil", enabled: single != nil && model.job == nil) { model.renameLocal() },
            FileMenuItem(title: "Neuer Ordner …", symbol: "folder.badge.plus") { model.newLocalFolder() },
            FileMenuItem(title: "In den Papierkorb legen", symbol: "trash", enabled: model.job == nil) { model.trashLocal() },
            nil,
            FileMenuItem(title: "Aktualisieren", symbol: "arrow.clockwise") { model.loadLocal() },
        ]
    }

    static func remote(_ rows: [FileRow], model: AppModel) -> [FileMenuItem?] {
        let can = model.canTransfer
        guard !rows.isEmpty else {
            return [
                FileMenuItem(title: "Neuer Ordner …", symbol: "folder.badge.plus", enabled: can) { model.newRemoteFolder() },
                FileMenuItem(title: "Pfad kopieren", symbol: "doc.on.doc") { model.copyPaths(.remote) },
                nil,
                FileMenuItem(title: "Aktualisieren", symbol: "arrow.clockwise", enabled: can) { model.loadRemote() },
            ]
        }
        let single = rows.count == 1 ? rows[0] : nil
        let opens = single.map { $0.isDirectory || $0.isLink } == true
        let transferable = rows.contains { !$0.isSystem }
        return [
            opens ? FileMenuItem(title: "Öffnen", symbol: "folder", enabled: can) { model.openRemote(rows[0]) } : nil,
            FileMenuItem(title: "Nach „\(model.localURL.lastPathComponent)“ herunterladen", symbol: "arrow.down.circle",
                         enabled: can && transferable) { model.downloadSelection() },
            nil,
            FileMenuItem(title: "Umbenennen …", symbol: "pencil", enabled: can && single != nil) { model.renameRemote() },
            FileMenuItem(title: "Rechte ändern …", symbol: "lock", enabled: can && rows.contains { !$0.isLink }) {
                model.changeRemoteMode()
            },
            FileMenuItem(title: "Pfad kopieren", symbol: "doc.on.doc") { model.copyPaths(.remote) },
            nil,
            FileMenuItem(title: "Neuer Ordner …", symbol: "folder.badge.plus", enabled: can) { model.newRemoteFolder() },
            FileMenuItem(title: "Löschen …", symbol: "trash", enabled: can) { model.deleteRemote() },
            nil,
            FileMenuItem(title: "Aktualisieren", symbol: "arrow.clockwise", enabled: can) { model.loadRemote() },
        ]
    }
}

// MARK: Activity and log

struct ActivityPanel: View {
    @Environment(AppModel.self) private var model

    /// Summary of the active connection's upload rules.
    private var uploadRules: String {
        let base = "Nie übertragen: .DS_Store, ._* und andere Systemdateien"
        guard let server = model.connectedServer ?? model.activeServer, !server.replacePatterns.isEmpty else { return base }
        let folders = server.replacePatterns.patterns.map { $0.joined(separator: "/") }.joined(separator: ", ")
        return base + " · vor dem Hochladen gelöscht: \(folders)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let job = model.job {
                    if job.total > 0 {
                        ProgressView(value: job.fraction)
                            .frame(width: 180)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(job.title).font(.callout.weight(.medium)).lineLimit(1)
                        .fixedSize()
                    Text(job.detail).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(job.current.isEmpty ? 1 : 2)
                    if !job.current.isEmpty {
                        // Truncate long paths in the middle so the folder and the file name stay visible.
                        Label(job.current, systemImage: "doc")
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(job.current)
                    }
                    Spacer(minLength: 8)
                    Button("Abbrechen") { model.cancelJob() }
                        .controlSize(.small)
                } else {
                    Text("Protokoll").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(uploadRules)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Button("Leeren") { model.clearLog() }
                        .controlSize(.small)
                        .disabled(model.log.isEmpty)
                }
            }
            .frame(height: 22)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.log) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Fmt.time(line.time))
                                    .foregroundStyle(.tertiary)
                                Text(line.text)
                                    .foregroundStyle(Color(nsColor: line.isError ? Darcula.danger : Darcula.text))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.log.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: Darcula.surface))
    }
}
