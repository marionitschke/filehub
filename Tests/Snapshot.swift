// For scripts/snapshot.sh only: demo data without network or keychain, window images as PNG
// (sRGB, 2x) plus the framed README image screenshot.png, then the app quits. screencapture needs
// the screen recording permission, so the app draws its windows itself (glass surfaces stay empty).
import AppKit
import SwiftUI

@MainActor
enum Snapshot {
    static var dir = ""
    static var counter = 0

    static func capture(_ label: String) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
                                             pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            // Render at 2x regardless of the screen, for sharp README images.
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            paintWindowButtons(window, frameView: view, into: rep)
            // The PNG would otherwise carry the display's color profile.
            let image = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
            let url = URL(fileURLWithPath: "\(dir)/\(String(format: "%02d", counter))-\(label)-w\(index).png")
            try? image.representation(using: .png, properties: [:])?.write(to: url)
            if label == "verbunden", index == 0 { framed(image, to: URL(fileURLWithPath: "\(dir)/screenshot.png")) }
        }
        counter += 1
    }

    /// The app does not get the focus from a script and would draw an inactive window (grey
    /// buttons and traffic lights): make AppKit believe it is the active key window.
    static func pretendActive() {
        let getters: [(AnyClass, String)] = [(NSApplication.self, "isActive")]
            + ["isKeyWindow", "isMainWindow", "_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus",
               "_hasKeyAppearance", "_hasMainAppearance", "hasKeyAppearance", "hasMainAppearance"].map { (NSWindow.self, $0) }
        for (type, name): (AnyClass, String) in getters {
            guard let method = class_getInstanceMethod(type, NSSelectorFromString(name)) else { continue }
            let always: @convention(block) (AnyObject) -> Bool = { _ in true }
            method_setImplementation(method, imp_implementationWithBlock(always))
        }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        for window in NSApp.windows {
            NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }
    }

    /// The traffic lights stay grey even then; paint them in their active colors.
    static func paintWindowButtons(_ window: NSWindow, frameView: NSView, into rep: NSBitmapImageRep) {
        guard window.sheetParent == nil else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (type, fill, stroke) in [(NSWindow.ButtonType.closeButton, 0xFF5F57, 0xE0443E),
                                     (.miniaturizeButton, 0xFEBC2E, 0xDEA123), (.zoomButton, 0x28C840, 0x1AAB29)] {
            guard let button = window.standardWindowButton(type), !button.isHidden else { continue }
            let frame = button.convert(button.bounds, to: frameView)
            let side = min(frame.width, frame.height)
            let path = NSBezierPath(ovalIn: NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
                .insetBy(dx: 0.25, dy: 0.25))
            Darcula.color(UInt32(fill)).setFill()
            path.fill()
            Darcula.color(UInt32(stroke)).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The README image: the window with rounded corners, a fine edge and a shadow on transparency.
    static func framed(_ rep: NSBitmapImageRep, to url: URL) {
        guard let image = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let margin = 80.0, radius = 26.0
        let rect = CGRect(x: margin, y: margin, width: Double(image.width), height: Double(image.height))
        guard let context = CGContext(data: nil, width: image.width + Int(2 * margin), height: image.height + Int(2 * margin),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let outline = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 44, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        context.addPath(outline)
        context.setFillColor(Darcula.background.cgColor)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(outline)
        context.clip()
        context.draw(image, in: rect)
        context.restoreGState()
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil))
        context.setStrokeColor(Darcula.border.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        guard let result = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])?.write(to: url)
    }

    static func fileTables(in view: NSView) -> [FileTableView] {
        view.subviews.flatMap { ($0 as? FileTableView).map { [$0] } ?? fileTables(in: $0) }
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func row(_ base: String, _ name: String, dir: Bool = false, size: Int64? = nil, days: Double = 0) -> FileRow {
        FileRow(id: base + "/" + name, name: name, isDirectory: dir, isLink: false, size: dir ? nil : size,
                modified: Date().addingTimeInterval(-days * 86_400), isSystem: SystemFiles.isSystem(name),
                mode: base.hasPrefix("/www") || base.hasPrefix("/home") ? (dir ? 0o755 : 0o644) : nil)
    }

    /// Upload of 214 files (3.1 MB), 87 done after 6 seconds.
    static func demoJob() -> Job {
        var job = Job(title: "Hochladen nach htdocs", total: 214, sizes: Array(repeating: 15_200, count: 214))
        job.started = Date().addingTimeInterval(-6)
        var labels = Array(repeating: "", count: 214)
        labels[87] = "dist/css/board.min.css · 24 KB"
        job.step(87, labels: labels)
        return job
    }

    static func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await pause(0.2)
        }
        return condition()
    }

    static func report(_ ok: Bool, _ label: String) {
        print("\(ok ? "✓" : "✗") E2E: \(label)")
        fflush(stdout)
    }

    /// Real run through the AppModel against the Docker test server (SFTP with test key, no
    /// keychain): connect, upload by plan, open folders, download.
    static func endToEnd(fixture: URL, key: String) async {
        let model = AppModel.shared
        var profile = ServerProfile()
        profile.name = "Prüf-Server"
        profile.host = "127.0.0.1"
        profile.port = 2222
        profile.user = "filehub"
        profile.auth = .key
        profile.keyPath = key
        model.setDemo(servers: [profile], local: fixture, localRows: [], remotePath: "/", remoteRows: [], info: nil, job: nil, log: [])
        model.loadLocal(fixture)
        model.connect()
        report(await waitFor(20) { model.isOnline && !model.remoteRows.isEmpty }, "verbunden, Anmeldeordner gelistet")
        let home = model.remotePath
        model.upload([fixture.appendingPathComponent("site")])
        _ = await waitFor(2) { model.job != nil }
        report(await waitFor(30) { model.job == nil && model.remoteRows.contains { $0.name == "site" } }, "Ordner „site“ hochgeladen")
        model.openRemote(FileRow(id: home + "/site", name: "site", isDirectory: true, isLink: false, size: nil, modified: nil))
        report(await waitFor(10) { model.remotePath == home + "/site" && !model.remoteRows.isEmpty }, "Server-Ordner geöffnet")
        let names = Set(model.remoteRows.map(\.name))
        report(names == [".htaccess", "index.html", "dist"], "nur erlaubte Dateien auf dem Server: \(names.sorted())")
        await pause(0.5)
        capture("e2e-server")
        model.openRemote(FileRow(id: home + "/site/dist", name: "dist", isDirectory: true, isLink: false, size: nil, modified: nil))
        report(await waitFor(10) { model.remotePath == home + "/site/dist" && !model.remoteRows.isEmpty }
               && model.remoteRows.map(\.name) == ["app.js"], "altes dist ohne Rückfrage ersetzt: \(model.remoteRows.map(\.name))")
        report(model.log.contains { $0.text == "Vorher gelöscht: \(home)/site/dist (1 Datei)" }, "Löschen von dist im Protokoll")
        model.openRemote(FileRow(id: home + "/site", name: "site", isDirectory: true, isLink: false, size: nil, modified: nil))
        _ = await waitFor(10) { model.remotePath == home + "/site" && model.remoteRows.contains { $0.name == "dist" } }
        let downloads = fixture.appendingPathComponent("zurück")
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        model.loadLocal(downloads)
        _ = await waitFor(5) { model.localURL.lastPathComponent == "zurück" }
        model.download([home + "/site/dist", home + "/site/index.html"])
        _ = await waitFor(2) { model.job != nil }
        let back = downloads.appendingPathComponent("dist/app.js")
        report(await waitFor(30) { model.job == nil && FileManager.default.fileExists(atPath: back.path) }, "heruntergeladen")
        report(!FileManager.default.fileExists(atPath: downloads.appendingPathComponent("dist/.DS_Store").path), "keine .DS_Store zurück")
        await pause(0.5)
        capture("e2e-mac")
        report(!model.log.contains { $0.isError }, "keine Fehler im Protokoll")
        for line in model.log { print("  Protokoll: \(line.text)") }
        model.disconnect()
        await pause(0.5)
    }

    static func hdiutil(_ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: Shell.run("/usr/bin/hdiutil", arguments).ok)
            }
        }
    }

    /// External volume (exFAT image) as start folder: missing at first, then attached; upload from
    /// it without ._ files, not enough space for a download, unplugging and ejecting.
    static func volumeEndToEnd(image: String, name: String, key: String) async {
        let model = AppModel.shared
        let volume = URL(fileURLWithPath: "/Volumes/" + name, isDirectory: true)
        let start = volume.appendingPathComponent("web", isDirectory: true)
        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        var profile = ServerProfile()
        profile.name = "Prüf-Server"
        profile.host = "127.0.0.1"
        profile.port = 2222
        profile.user = "filehub"
        profile.auth = .key
        profile.keyPath = key
        profile.localPath = start.path
        model.setDemo(servers: [profile], local: homeURL, localRows: [], remotePath: "/", remoteRows: [], info: nil, job: nil, log: [])
        model.connect()
        report(await waitFor(20) { model.isOnline && !model.remoteRows.isEmpty }, "SSD: verbunden ohne Laufwerk")
        let home = model.remotePath
        report(model.log.contains { $0.text.contains("nicht angeschlossen") }, "SSD: Hinweis „nicht angeschlossen“")

        report(await hdiutil(["attach", "-noverify", "-noautoopen", image]), "SSD: angeschlossen")
        report(await waitFor(10) { model.localURL == start.standardizedFileURL && model.localRows.contains { $0.name == "site" } },
               "SSD: Mac-Spalte springt in den Startordner")
        report(model.localVolume?.name == name && model.volumes.contains { $0.name == name && $0.ejectable },
               "SSD: als Laufwerk erkannt (\(model.volumes.map(\.name)))")

        model.upload([start.appendingPathComponent("site")])
        _ = await waitFor(2) { model.job != nil }
        report(await waitFor(30) { model.job == nil && model.remoteRows.contains { $0.name == "site" } }, "SSD: Ordner hochgeladen")
        model.openRemote(FileRow(id: home + "/site", name: "site", isDirectory: true, isLink: false, size: nil, modified: nil))
        _ = await waitFor(10) { model.remotePath == home + "/site" && !model.remoteRows.isEmpty }
        let names = Set(model.remoteRows.map(\.name))
        report(names == [".htaccess", "index.html", "dist"], "SSD: keine ._-Dateien auf dem Server: \(names.sorted())")
        model.openRemote(FileRow(id: home + "/site/dist", name: "dist", isDirectory: true, isLink: false, size: nil, modified: nil))
        _ = await waitFor(10) { model.remotePath == home + "/site/dist" && !model.remoteRows.isEmpty }
        report(model.remoteRows.map(\.name) == ["app.js"], "SSD: dist ohne ._-Dateien: \(model.remoteRows.map(\.name))")

        model.loadRemote(home)
        _ = await waitFor(10) { model.remotePath == home && model.remoteRows.contains { $0.name == "big.bin" } }
        model.download([home + "/big.bin"])
        report(await waitFor(15) { model.notice?.title == "Nicht genug Platz" }, "SSD: zu wenig Platz erkannt (\(model.notice?.message ?? "-"))")
        model.notice = nil
        _ = await waitFor(5) { model.job == nil }
        report(!FileManager.default.fileExists(atPath: start.appendingPathComponent("big.bin").path), "SSD: nichts angefangen")

        report(await hdiutil(["detach", volume.path]), "SSD: abgezogen")
        report(await waitFor(10) { model.localURL == homeURL && !model.volumes.contains { $0.name == name } },
               "SSD: Mac-Spalte zurück im Benutzerordner")
        report(model.log.contains { $0.text.contains("nicht mehr da") }, "SSD: Hinweis im Protokoll")

        _ = await hdiutil(["attach", "-noverify", "-noautoopen", image])
        _ = await waitFor(10) { model.volumes.contains { $0.name == name } }
        if let place = model.volumes.first(where: { $0.name == name }) {
            model.openPlace(place)
            _ = await waitFor(5) { model.localVolume?.name == name }
            await pause(0.5)
            capture("e2e-ssd")
            model.eject(place)
        }
        report(await waitFor(15) { !model.volumes.contains { $0.name == name } && model.localURL == homeURL
                   && model.log.contains { $0.text.contains("ausgeworfen") } },
               "SSD: ausgeworfen")
        report(!model.log.contains { $0.isError }, "SSD: keine Fehler im Protokoll")
        for line in model.log { print("  Protokoll: \(line.text)") }
        model.disconnect()
        await pause(0.5)
    }

    static func start() {
        guard let target = ProcessInfo.processInfo.environment["FILEHUB_SNAPSHOT"] else { return }
        dir = target
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            if let image = env["FILEHUB_E2E_VOLUME_IMAGE"], let name = env["FILEHUB_E2E_VOLUME_NAME"], let key = env["FILEHUB_E2E_KEY"] {
                await volumeEndToEnd(image: image, name: name, key: key)
                NSApp.terminate(nil)
                return
            }
            if let fixture = env["FILEHUB_E2E_FIXTURE"], let key = env["FILEHUB_E2E_KEY"] {
                await endToEnd(fixture: URL(fileURLWithPath: fixture, isDirectory: true), key: key)
                NSApp.terminate(nil)
                return
            }
            pretendActive()
            let model = AppModel.shared
            var live = ServerProfile()
            live.name = "Website live"
            live.proto = .ftps
            live.port = 21
            live.host = "ftp.example.com"
            live.user = "web123"
            live.neverUpload = "php/config.php, logs, backups"
            live.replaceOnUpload = "dist, assets/build"
            var watch = ServerProfile()
            watch.name = "Blog"
            watch.host = "ssh.example.de"
            watch.user = "deploy"
            watch.auth = .key
            let base = "/Users/Shared/Sites/website/public"
            let local = [row(base, ".htaccess", size: 2_140, days: 30), row(base, ".user.ini", size: 320, days: 30),
                         row(base, "dist", dir: true, days: 0.1), row(base, "images", dir: true, days: 3),
                         row(base, "includes", dir: true, days: 2), row(base, "php", dir: true, days: 2),
                         row(base, "index.php", size: 18_400, days: 0.1), row(base, "manifest.php", size: 1_200, days: 9),
                         row(base, "sw.js", size: 6_800, days: 0.1)]
            let remote = [row("/www/htdocs", ".DS_Store", size: 6_148, days: 120), row("/www/htdocs", ".htaccess", size: 2_140, days: 30),
                          row("/www/htdocs", "backups", dir: true, days: 1), row("/www/htdocs", "dist", dir: true, days: 6),
                          row("/www/htdocs", "images", dir: true, days: 3), row("/www/htdocs", "logs", dir: true, days: 0.5),
                          row("/www/htdocs", "index.php", size: 18_100, days: 6), row("/www/htdocs", "sw.js", size: 6_700, days: 6)]
            let info = ConnectionInfo(summary: "FTPS · TLSv1.3 · Zertifikat geprüft",
                                      details: ["Protokoll: FTP über TLS (explizit), Daten verschlüsselt",
                                                "TLS: TLSv1.3, AEAD-AES256-GCM-SHA384", "Zertifikat: CN=ftp.example.com"],
                                      home: "/")
            let log = ["Verbunden mit Website live (web123@ftp.example.com): FTPS · TLSv1.3 · Zertifikat geprüft",
                       "Hochladen nach /www/htdocs: 214 Dateien (3,1 MB); 6 Systemdateien ausgelassen, 1 nach „Nie hochladen“ ausgelassen",
                       "Vorher gelöscht: /www/htdocs/dist",
                       "Hochgeladen: 214 Dateien (3,1 MB) nach /www/htdocs."]
            model.setDemo(servers: [live, watch], local: URL(fileURLWithPath: base), localRows: local, remotePath: "/www/htdocs",
                          remoteRows: remote, info: info, job: nil, log: log)
            model.localSelection = [base + "/dist", base + "/index.php"]
            await pause(2.5)
            // The focused Mac column, as while working in it.
            if let window = NSApp.windows.first(where: \.isVisible), let frame = window.contentView,
               let table = fileTables(in: frame).first {
                window.makeFirstResponder(table)
                await pause(0.5)
            }
            capture("verbunden")

            model.setDemo(servers: [live, watch], local: URL(fileURLWithPath: base), localRows: local, remotePath: "/www/htdocs",
                          remoteRows: remote, info: info,
                          job: demoJob(), log: log)
            await pause(1.2)
            capture("hochladen")

            model.setDemo(servers: [live, watch], local: URL(fileURLWithPath: base), localRows: local, remotePath: "/",
                          remoteRows: [], info: nil, job: nil, log: [])
            await pause(1.2)
            capture("getrennt")

            model.editing = live
            await pause(1.8)
            capture("bearbeiten")
            model.editing = nil
            await pause(0.8)

            model.setDemo(servers: [], local: URL(fileURLWithPath: base), localRows: local, remotePath: "/",
                          remoteRows: [], info: nil, job: nil, log: [])
            await pause(1.2)
            capture("leer")
            NSApp.terminate(nil)
        }
    }
}
