// FileHub checks (scripts/check.sh). Without arguments: rules, listings, paths, encryption and
// the askpass bridge. With --server also real runs against the Docker test server
// (scripts/testserver.sh). Never touches a real server; uses its own folders and keychain service.
import Darwin
import Foundation

@main
enum Checks {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
        } else {
            failures += 1
            let extra = detail()
            print("✗ \(label)" + (extra.isEmpty ? "" : " – \(extra)"))
        }
    }

    static func main() {
        AskpassHelper.runIfRequested()
        signal(SIGPIPE, SIG_IGN)
        units()
        if CommandLine.arguments.contains("--server") { Integration.run() }
        print("\(passed) Prüfungen bestanden, \(failures) fehlgeschlagen.")
        exit(failures == 0 ? 0 : 1)
    }

    static func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("filehub-check-\(name)-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ text: String, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Units

    static func units() {
        // Listings
        let mlsd = """
        type=cdir;sizd=8;modify=20261108082336;UNIX.mode=0700; .
        type=pdir;sizd=8;modify=20261108082336;UNIX.mode=0700; ..
        type=file;size=220;modify=20260712165818;UNIX.mode=0644; .htaccess
        type=dir;sizd=30;modify=20261108082418;UNIX.mode=0700; dist
        type=file;size=5;modify=20261108082418; Name mit Leerzeichen.txt
        type=OS.unix=symlink;size=5; link
        type=file;size=1; ../böse
        """
        let entries = ListingParser.mlsd(mlsd, in: "/www")
        check(entries.map(\.name) == [".htaccess", "dist", "Name mit Leerzeichen.txt", "link"], "MLSD: Namen", "\(entries.map(\.name))")
        check(entries.first?.size == 220 && entries.first?.path == "/www/.htaccess", "MLSD: Größe und Pfad")
        check(entries[1].isDirectory && entries[1].size == nil, "MLSD: Ordner")
        check(entries[3].kind == .link, "MLSD: Verknüpfung")
        check(entries[0].mode == 0o644 && entries[1].mode == 0o700 && entries[2].mode == nil, "MLSD: Rechte aus UNIX.mode")
        let utc = TimeZone(identifier: "UTC")!
        check(entries.first?.modified == ISO8601DateFormatter().date(from: "2026-07-12T16:58:18Z"), "MLSD: Datum (UTC)")

        let now = ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!
        let list = """
        total 12
        -rw-r--r--    1 1000     1000          220 Jul 12 16:58 .bash_logout
        drwxr-xr-x    2 1000     1000         4096 Nov  8 07:12 dist
        -rw-r--r--    ? 1000     1000            6 Nov  8 09:25 a b*[1]"q\\z.txt
        lrwxrwxrwx    1 1000     1000            4 Dec 24  2025 web -> /var/www
        -rw-r--r-- 1 owner 1234 Dec 31 23:59 ohne gruppe.txt
        -rw-r--r--    1 1000     1000            9 Nov  8 07:12  zwei Leerzeichen
        drwxr-xr-x    2 1000     1000         4096 Nov  8 07:12 .
        """
        let unix = ListingParser.unix(list, in: "/", timeZone: utc, now: now)
        check(unix.map(\.name) == [".bash_logout", "dist", "a b*[1]\"q\\z.txt", "web", "ohne gruppe.txt", " zwei Leerzeichen"],
              "LIST: Namen", "\(unix.map(\.name))")
        check(unix[1].isDirectory && unix[0].size == 220, "LIST: Ordner und Größe")
        check(unix[3].kind == .link, "LIST: Verknüpfung ohne Ziel")
        check(unix[4].size == 1234, "LIST: ohne Gruppen-Spalte")
        check(unix[0].mode == 0o644 && unix[1].mode == 0o755 && unix[3].mode == 0o777, "LIST: Rechte",
              "\(unix.map { $0.mode.map(FileMode.octal) ?? "-" })")
        check(FileMode.parse(symbolic: "-rwsr-xr-T") == 0o754 && FileMode.parse(symbolic: "-rw?r--r--") == nil
              && FileMode.parse(symbolic: "-rw") == nil, "Rechte: s/T und Unsinn")
        check(FileMode.symbolic(0o640) == "rw-r-----" && FileMode.octal(0o5) == "005" && FileMode.octal(0o4755) == "755",
              "Rechte: Darstellung")

        // Progress, speed and time left
        let jobStart = Date(timeIntervalSince1970: 1_000_000)
        var job = Job(title: "Hochladen", total: 3, sizes: [100, 200, 700])
        job.started = jobStart
        job.step(1, labels: ["a", "b", "c"], now: jobStart.addingTimeInterval(1))
        check(job.fraction == 0.1 && job.current == "b" && !job.detail.contains("/s"), "Fortschritt: nach Bytes, Tempo erst nach 3 s",
              job.detail)
        job.step(2, labels: ["a", "b", "c"], now: jobStart.addingTimeInterval(10))
        check(job.fraction == 0.3 && job.detail.contains("/s") && job.detail.hasSuffix("noch 24 s"), "Fortschritt: Tempo und Restzeit",
              job.detail)
        var unsized = Job(title: "Herunterladen", total: 4)
        unsized.step(1, labels: [])
        check(unsized.fraction == 0.25 && unsized.detail == "1 von 4", "Fortschritt: ohne Größen nach Dateien", unsized.detail)
        check(Fmt.remaining(45) == "45 s" && Fmt.remaining(0.2) == "1 s" && Fmt.remaining(3700) == "1 Std. 2 Min."
              && Fmt.remaining(.infinity) == "–", "Restzeit-Format")
        let calendar = Calendar(identifier: .gregorian)
        var c = calendar
        c.timeZone = utc
        check(unix[4].modified.map { c.component(.year, from: $0) } == 2025, "LIST: Datum ohne Jahr in der Zukunft → Vorjahr")
        check(unix[3].modified.map { c.component(.year, from: $0) } == 2025, "LIST: Datum mit Jahr")

        // Paths
        check(RemotePath.normalize("//www/./a/../b/") == "/www/b", "Pfad normalisieren")
        check(RemotePath.parent("/www/dist") == "/www" && RemotePath.parent("/www") == "/" && RemotePath.parent("/") == "/", "Elternordner")
        check(RemotePath.join("/", "a") == "/a" && RemotePath.join("/a", "b") == "/a/b", "Pfade verbinden")
        check(!RemotePath.isSafeName("..") && !RemotePath.isSafeName("a/b") && !RemotePath.isSafeName("x\ny")
              && !RemotePath.isSafeName("") && RemotePath.isSafeName(".htaccess"), "Unsichere Namen")
        check(!RemotePath.isSafe("/a\r\nDELE /b"), "Zeilenumbruch im Pfad abgelehnt")

        // System files and patterns
        check(SystemFiles.isSystem(".DS_Store") && SystemFiles.isSystem(".ds_store") && SystemFiles.isSystem("._app.js")
              && SystemFiles.isSystem("Icon\r") && SystemFiles.isSystem("Thumbs.db") && SystemFiles.isSystem(".git"),
              "Systemdateien erkannt")
        check(!SystemFiles.isSystem(".htaccess") && !SystemFiles.isSystem(".user.ini") && !SystemFiles.isSystem("Icon.png"),
              "Punktdateien des Webservers bleiben")
        check(SystemFiles.isSystem("System Volume Information") && SystemFiles.isSystem("$RECYCLE.BIN")
              && SystemFiles.isSystem(".Trash-1000") && SystemFiles.isSystem("._.Trashes") && !SystemFiles.isSystem("trash.php"),
              "Reste von exFAT-/FAT-Laufwerken erkannt")
        places()
        let never = PathPatterns("php/config.php, logs\n*.map")
        check(never.matches("/www/php/config.php") && !never.matches("/www/config.php") && !never.matches("/www/xphp/config.php"),
              "Muster mit Ordner")
        check(never.matches("/www/logs") && never.matches("/a/b/app.js.map") && !never.matches("/www/logs.txt"), "Muster mit *")
        check(PathPatterns(" , ").isEmpty, "Leere Muster")

        uploadPlan()
        escaping()
        validation()
        crypto()
        askpass()
        downloadPlan()
        cachedSecrets()
        hardening()
    }

    /// Hardening: nothing from outside may inject options, commands or trust, and nothing may
    /// fill memory. Runs without network.
    static func hardening() {
        // curl config: a line break in a value stays part of the value.
        check(FTPSClient.quote("a\nb\r\tc\"d\\") == "\"a\\nb\\r\\tc\\\"d\\\\\"", "curl: Zeilenumbruch maskiert",
              FTPSClient.quote("a\nb\r\tc\"d\\"))
        check(FTPSClient.isSafeConfig(["url = \(FTPSClient.quote("/x\ninsecure"))"]) && !FTPSClient.isSafeConfig(["output = \"/x\ninsecure\""]),
              "curl: Zeile mit echtem Umbruch abgelehnt")
        check(FTPSClient.isSafeSecret("Pä$$wört 123!") && !FTPSClient.isSafeSecret("a\r\nDELE x") && !FTPSClient.isSafeSecret("a\u{0}b"),
              "Passwort ohne Steuerzeichen")
        // Cross-check with the macOS curl: a path with a line break is written literally, no new option.
        let dir = temp("curl")
        write("inhalt", dir.appendingPathComponent("quelle.txt"))
        let odd = dir.appendingPathComponent("zeile\ninsecure.txt")
        let config = ["silent", "url = \(FTPSClient.quote(dir.appendingPathComponent("quelle.txt").absoluteString))",
                      "output = \(FTPSClient.quote(odd.path))"]
        let copied = Shell.run("/usr/bin/curl", ["-q", "-K", "-"], input: Data((config.joined(separator: "\n") + "\n").utf8))
        check(copied.ok && (try? String(contentsOf: odd, encoding: .utf8)) == "inhalt", "curl: Pfad mit Zeilenumbruch wörtlich", copied.errors)
        let blocked = Shell.run("/usr/bin/curl", ["-q", "-K", "-"], input: Data((["silent", "proto = \"=ftp\"",
            "url = \(FTPSClient.quote(dir.appendingPathComponent("quelle.txt").absoluteString))", "output = \"/dev/null\""]
            .joined(separator: "\n") + "\n").utf8))
        check(!blocked.ok, "curl: nur ftp:// erlaubt (file:// abgelehnt)", "Status \(blocked.status)")
        try? FileManager.default.removeItem(at: dir)
        let newline = FTPSClient(profile: { var p = ServerProfile(); p.proto = .ftps; p.host = "localhost"; p.port = 1; p.user = "u"; return p }(),
                                 password: "pw\nSITE x")
        do {
            _ = try newline.connect(cancel: Cancellation())
            check(false, "FTPS: Passwort mit Zeilenumbruch abgelehnt", "verbunden")
        } catch {
            check(error.localizedDescription.contains("Zeilenumbruch"), "FTPS: Passwort mit Zeilenumbruch abgelehnt", error.localizedDescription)
        }

        // ssh options: quotes in a path stay part of the value (ssh -G does not connect).
        let key = "/tmp/Schlüssel \"x\" ProxyCommand=\"böse\" \\y"
        let parsed = Shell.run("/usr/bin/ssh", ["-G", "-F", "/dev/null", "-o", "IdentityFile=\(SFTPClient.optionValue(key))", "example.org"])
        let identity = parsed.output.split(separator: "\n").first { $0.hasPrefix("identityfile ") }.map { String($0.dropFirst(13)) }
        check(identity == key && !parsed.output.contains("proxycommand böse"), "ssh: Optionswert mit Anführungszeichen",
              "\(identity ?? parsed.errors)")
        var profile = ServerProfile()
        profile.name = "x"; profile.host = "h"; profile.user = "u"; profile.auth = .key; profile.keyPath = "~/.ssh/id\nx"
        check(profile.problem?.contains("Zeilenumbrüche") == true, "Schlüsseldatei mit Zeilenumbruch abgelehnt")

        // Names from the server: no direction or C1 control characters.
        check(!RemotePath.isSafeName("rechnung\u{202E}fdp.app") && !RemotePath.isSafeName("a\u{0085}b")
              && !RemotePath.isSafeName("x\u{2066}y") && RemotePath.isSafeName("Mädchen 日本 🙂.txt"),
              "Täuschende Namen abgelehnt")
        check(ListingParser.mlsd("type=file;size=1; rechnung\u{202E}fdp.app\ntype=file;size=1; ok.txt", in: "/").map(\.name) == ["ok.txt"],
              "Liste: täuschender Name ausgelassen")

        // known_hosts: plain lines for one server only.
        let blob = Data(repeating: 7, count: 51).base64EncodedString()
        let plain = HostKeys.plainLines("""
        [127.0.0.1]:2222 ssh-ed25519 \(blob)
        example.org ssh-ed25519 \(blob) kommentar
        @cert-authority * ssh-ed25519 \(blob)
        @revoked example.org ssh-ed25519 \(blob)
        *.example.org ssh-ed25519 \(blob)
        |1|abc=|def= ssh-ed25519 \(blob)
        a.org,b.org ssh-ed25519 \(blob)
        !a.org ssh-ed25519 \(blob)
        example.org ssh-dss \(blob)
        example.org ssh-ed25519 kein-base64
        [-oProxy]:22 ssh-ed25519 \(blob)
        """)
        check(plain == ["[127.0.0.1]:2222 ssh-ed25519 \(blob)", "example.org ssh-ed25519 \(blob)"],
              "known_hosts: nur schlichte Zeilen übernommen", "\(plain)")
        check(HostKeys.plainLines("[127.0.0.1]:2222 ssh-ed25519 \(blob)\nandere.org ssh-ed25519 \(blob)", only: "[127.0.0.1]:2222").count == 1,
              "known_hosts: Abfrage nur für den gefragten Server")

        // Program output stays bounded.
        let noisy = Shell.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero | tr '\\0' x >&2; echo ENDE >&2"])
        check(noisy.errors.utf8.count < (2 << 20) + 16 && noisy.errors.hasPrefix("xxx") && noisy.errors.hasSuffix("ENDE\n"),
              "stderr begrenzt, Anfang und Ende bleiben", "\(noisy.errors.utf8.count) Bytes")
        var longest = 0, total = 0
        _ = Shell.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero | tr '\\0' x"]) { line in
            longest = max(longest, line.utf8.count)
            total += line.utf8.count
        }
        check(total == 3_000_000 && longest < 2 << 20, "Zeile ohne Ende in Stücken", "\(total) Bytes, längste \(longest)")

        // The askpass bridge also ends when ssh never asks (e.g. server unreachable).
        let bridge = temp("askpass-stop")
        if let idle = try? AskpassServer(directory: bridge, secret: "x") {
            idle.stop()
            let deadline = Date().addingTimeInterval(2)
            while !idle.isClosed, Date() < deadline { usleep(20_000) }
            check(idle.isClosed && !FileManager.default.fileExists(atPath: idle.socketPath), "Askpass: Brücke endet nach stop()")
        } else {
            check(false, "Askpass: Brücke endet nach stop()", "nicht gestartet")
        }
        try? FileManager.default.removeItem(at: bridge)

        // Quarantine for downloads, not on file systems without native extended attributes.
        let downloads = temp("quarantaene")
        let file = downloads.appendingPathComponent("programm.command")
        write("#!/bin/sh", file)
        check(Quarantine.storesAttributes(downloads.path) && !Quarantine.storesAttributes("/dev"), "Quarantäne: Dateisystem erkannt")
        check(Quarantine.mark([file, downloads.appendingPathComponent("fehlt.txt")]) == 1 && Quarantine.isMarked(file),
              "Quarantäne: heruntergeladene Datei markiert")
        try? FileManager.default.removeItem(at: downloads)
    }

    /// Keychain once per launch: load on first access only, failures are not kept, written values
    /// apply without reloading. (No real keychain, or macOS would prompt.)
    static func cachedSecrets() {
        let cache = Cached<[String: String]>()
        var loads = 0
        struct Denied: Error {}
        let denied: () throws -> [String: String] = { loads += 1; throw Denied() }
        let stored: () throws -> [String: String] = { loads += 1; return ["a": "1"] }
        check((try? cache.get(denied)) == nil && loads == 1, "Schlüsselbund: Ablehnung wird gemeldet")
        check((try? cache.get(stored)) == ["a": "1"] && loads == 2, "Schlüsselbund: nach Ablehnung neu gefragt")
        check((try? cache.get(stored)) == ["a": "1"] && (try? cache.get(denied)) == ["a": "1"] && loads == 2,
              "Schlüsselbund: danach nur noch aus dem Speicher", "\(loads) Zugriffe")
        cache.set(["a": "1", "b": "2"])
        check((try? cache.get(stored)) == ["a": "1", "b": "2"] && loads == 2, "Schlüsselbund: Geschriebenes ohne neues Lesen")
        cache.set(nil)
        check((try? cache.get(stored)) == ["a": "1"] && loads == 3, "Schlüsselbund: vergessen heißt neu lesen")
    }

    static func uploadPlan() {
        let root = temp("plan")
        let pub = root.appendingPathComponent("public")
        write("x", pub.appendingPathComponent(".DS_Store"))
        write("RewriteEngine On", pub.appendingPathComponent(".htaccess"))
        write("<?php", pub.appendingPathComponent("index.php"))
        write("sw", pub.appendingPathComponent("sw.js"))
        write("v1", pub.appendingPathComponent("dist/version.txt"))
        write("js", pub.appendingPathComponent("dist/js/app.js"))
        write("x", pub.appendingPathComponent("dist/js/.DS_Store"))
        write("x", pub.appendingPathComponent("dist/js/._app.js"))
        write("inner", pub.appendingPathComponent("dist/sub/dist/x.js"))
        write("css", pub.appendingPathComponent("assets/dist/a.css"))
        write("secret", pub.appendingPathComponent("php/config.php"))
        write("ok", pub.appendingPathComponent("php/lib.php"))
        write("log", pub.appendingPathComponent("logs/today.log"))
        write("x", pub.appendingPathComponent(".git/HEAD"))
        try? FileManager.default.createDirectory(at: pub.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let nfd = "Ma\u{0308}dchen.txt"
        write("u", pub.appendingPathComponent(nfd))
        try? FileManager.default.createSymbolicLink(at: pub.appendingPathComponent("ssh"),
                                                    withDestinationURL: URL(fileURLWithPath: NSHomeDirectory() + "/.ssh"))
        write("privat", pub.appendingPathComponent(".ssh/id_ed25519"))
        write("privat", pub.appendingPathComponent("keys/id_rsa"))
        write("öffentlich", pub.appendingPathComponent("keys/id_rsa.pub"))
        write("{}", pub.appendingPathComponent("FileHub-Verbindungen.filehub"))

        let plan = UploadPlan.build(items: [pub], into: "/www", neverUpload: PathPatterns("php/config.php, logs"),
                                    uploadLast: PathPatterns("dist/version.txt, sw.js"), replace: PathPatterns("dist"))
        let remotes = plan.files.map(\.remote)
        check(!remotes.contains { $0.contains(".DS_Store") || $0.contains("._") || $0.contains(".git") }, "Plan: keine Systemdateien", "\(remotes)")
        // FileManager already hides "._app.js" next to "app.js"; the others are counted.
        check(plan.skippedSystem >= 3, "Plan: Systemdateien gezählt", "\(plan.skippedSystem)")
        check(remotes.contains("/www/public/.htaccess"), "Plan: .htaccess dabei")
        check(!remotes.contains("/www/public/php/config.php") && remotes.contains("/www/public/php/lib.php"), "Plan: „Nie hochladen“ für Datei")
        check(!remotes.contains { $0.hasPrefix("/www/public/logs") } && plan.skippedByRule.contains("/www/public/logs"), "Plan: „Nie hochladen“ für Ordner")
        check(plan.replaceDirectories == ["/www/public/dist"], "Plan: nur dist auf oberster Ebene, nicht assets/dist", "\(plan.replaceDirectories)")
        check(remotes.suffix(2) == ["/www/public/dist/version.txt", "/www/public/sw.js"], "Plan: zuletzt hochladen", "\(remotes.suffix(3))")
        check(plan.directories.first == "/www/public" && plan.directories.contains("/www/public/empty"), "Plan: Ordner inkl. leerer")
        check(remotes.contains("/www/public/M\u{00E4}dchen.txt"), "Plan: Namen als NFC")
        check(plan.skippedLinks.count == 1, "Plan: Verknüpfung ausgelassen")
        check(plan.skippedSecret.count == 3 && !remotes.contains { $0.contains(".ssh") || $0.hasSuffix("/id_rsa") || $0.hasSuffix(".filehub") }
              && remotes.contains("/www/public/keys/id_rsa.pub"),
              "Plan: private Schlüssel und Exportdatei nie hochgeladen", "\(plan.skippedSecret)")
        func build(_ items: [URL], into target: String, never: String = "", replace: String) -> UploadPlan {
            UploadPlan.build(items: items, into: target, neverUpload: PathPatterns(never), uploadLast: PathPatterns(""),
                             replace: PathPatterns(replace))
        }
        check(build([pub.appendingPathComponent("dist")], into: "/www", replace: "dist").replaceDirectories == ["/www/dist"],
              "Plan: dist direkt gezogen")
        let file = build([pub.appendingPathComponent("dist/version.txt")], into: "/www/dist", replace: "dist")
        check(file.replaceDirectories.isEmpty && file.files.count == 1, "Plan: einzelne Datei in dist löscht nichts")
        check(build([pub], into: "/www", replace: "").replaceDirectories.isEmpty, "Plan: leere Liste löscht nichts")
        let custom = build([pub], into: "/www", replace: "assets/dist, php, empty")
        check(custom.replaceDirectories == ["/www/public/assets/dist", "/www/public/empty", "/www/public/php"],
              "Plan: eigene Liste „Alte Daten beim Upload löschen“", "\(custom.replaceDirectories)")
        check(build((try? FileManager.default.contentsOfDirectory(at: pub, includingPropertiesForKeys: nil)) ?? [], into: "/www",
                    replace: "dist").replaceDirectories == ["/www/dist"], "Plan: Inhalt von public gezogen, nur /www/dist")
        check(build([pub.appendingPathComponent("assets")], into: "/www", replace: "dist").replaceDirectories == ["/www/assets/dist"],
              "Plan: dist direkt im gezogenen Ordner")
        check(build([root], into: "/www", replace: "dist").replaceDirectories.isEmpty,
              "Plan: dist tiefer als eine Ebene im gezogenen Ordner löscht nichts")
        let star = build([pub], into: "/www", replace: "*")
        check(star.replaceDirectories == ["/www/public"], "Plan: * ersetzt nur den äußersten Ordner", "\(star.replaceDirectories)")
        check(build([pub], into: "/www", never: "logs", replace: "logs").replaceDirectories.isEmpty,
              "Plan: „Nie hochladen“ geht vor Löschen")
        try? FileManager.default.removeItem(at: root)

        var job = Job(title: "Hochladen", total: 2)
        let labels = [Job.label("/www/dist/css/board.min.css", in: "/www", size: 24_562), Job.label("/www/sw.js", in: "/", size: nil)]
        check(labels == ["dist/css/board.min.css · \(Fmt.size(24_562))", "www/sw.js"], "Anzeige: Datei unterhalb des Ziels", "\(labels)")
        job.step(1, labels: labels)
        check(job.current == "www/sw.js" && job.detail == "1 von 2", "Anzeige: gerade übertragene Datei")
        job.step(2, labels: labels)
        check(job.current.isEmpty && job.done == 2, "Anzeige: fertig ohne Datei")
    }

    static func places() {
        let ssd = URL(fileURLWithPath: "/Volumes/Extreme SSD/web/diaryhub")
        check(Places.volumeRoot(of: ssd)?.path == "/Volumes/Extreme SSD", "Laufwerk eines Pfads")
        check(Places.volumeRoot(of: URL(fileURLWithPath: "/Users/x/web")) == nil
              && Places.volumeRoot(of: URL(fileURLWithPath: "/Volumes")) == nil, "Kein Laufwerk außerhalb von /Volumes")
        check(Places.isInside(ssd, URL(fileURLWithPath: "/Volumes/Extreme SSD"))
              && !Places.isInside(URL(fileURLWithPath: "/Volumes/Extreme SSD 2/a"), URL(fileURLWithPath: "/Volumes/Extreme SSD"))
              && Places.isInside(ssd, URL(fileURLWithPath: "/")), "Liegt in Laufwerk")
        check(Places.display(URL(fileURLWithPath: NSHomeDirectory() + "/web")) == "~/web"
              && Places.display(URL(fileURLWithPath: "/Volumes/Daten" + NSHomeDirectory())) == "/Volumes/Daten" + NSHomeDirectory(),
              "Anzeige mit ~ nur am Anfang")
        let volumes = Places.volumes()
        check(volumes.first?.kind == .startup && volumes.first?.url.path == "/" && volumes.first?.ejectable == false,
              "Startvolume zuerst, nicht auswerfbar")
        check(volumes.dropFirst().allSatisfy { Places.volumeRoot(of: $0.url)?.path == $0.url.path && $0.ejectable },
              "Weitere Laufwerke nur unter /Volumes: \(volumes.map(\.name))")
        check(Places.freeSpace(at: URL(fileURLWithPath: NSTemporaryDirectory())).map { $0 > 0 } == true, "Freier Platz lesbar")
    }

    static func escaping() {
        check(SFTPClient.escape("/a b/c*[1]\"'\\x#$ä.txt") == "/a\\ b/c\\*\\[1\\]\\\"\\'\\\\x\\#\\$ä.txt", "sftp: Escaping",
              SFTPClient.escape("/a b/c*[1]\"'\\x#$ä.txt"))
        check(SFTPClient.optionValue("/A B/100%") == "\"/A B/100%%\"", "ssh: Optionswerte")
        let client = FTPSClient(profile: { var p = ServerProfile(); p.host = "h"; p.port = 21; return p }(), password: "x")
        check(client.directoryURL("/www/a b;type=a/ä") == "ftp://h:21/%2Fwww/a%20b%3Btype%3Da/%C3%A4/", "FTPS: Ordner-URL (ein CWD)",
              client.directoryURL("/www/a b;type=a/ä"))
        check(client.directoryURL("/") == "ftp://h:21/%2F/", "FTPS: URL Wurzel")
        check(FTPSClient.deniedReply("curl: (19) RETR response: 550") && FTPSClient.deniedReply("curl: (19) RETR response: 450")
              && !FTPSClient.deniedReply("curl: (19) RETR response: 500") && !FTPSClient.deniedReply("curl: (19) RETR response: 502"),
              "FTPS: 550 ist kein unbekannter Befehl")
        func file(_ name: String, _ size: Int64) -> UploadPlan.File {
            UploadPlan.File(local: URL(fileURLWithPath: "/tmp/" + name), remote: "/www/" + name, size: size)
        }
        check(FTPSClient.partialName(file("app.js", 2 << 20)) == ".app.js.filehub-part" && FTPSClient.partialName(file("a.css", 900)) == nil,
              "FTPS: große Dateien unter Zwischennamen")
        check(SystemFiles.isSystem(".app.js.filehub-part") && Partial.url(for: URL(fileURLWithPath: "/x/a.zip")).path == "/x/.a.zip.filehub-part",
              "Zwischennamen: Systemdatei, nie übertragen")
        check(FTPSClient.uploadAborted(status: 28, errors: "") && FTPSClient.uploadAborted(status: 56, errors: "")
              && !FTPSClient.uploadAborted(status: 25, errors: "") && !FTPSClient.uploadAborted(status: 18, errors: "522"),
              "FTPS: Abbrüche, die eine Wiederholung lohnen")
        let parent = Cancellation(), child = parent.child(), sibling = parent.child()
        child.cancel()
        check(child.isCancelled && !parent.isCancelled && !sibling.isCancelled, "Abbruch: eine Verbindung allein")
        parent.cancel()
        check(sibling.isCancelled && parent.child().isCancelled, "Abbruch: alle mit dem Auftrag")
        check(client.fileURL("/www/a b/ä#.txt") == "ftp://h:21/%2Fwww/a%20b/%C3%A4%23.txt", "FTPS: Datei-URL ohne CWD",
              client.fileURL("/www/a b/ä#.txt"))
        check(FTPSClient.quote("a\"b\\c") == "\"a\\\"b\\\\c\"", "curl: Konfigurationswerte")
        let macCurl = "curl 8.7.1 (x86_64-apple-darwin26.0) libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12\nRelease-Date: 2024-03-27"
        check(FTPSClient.curlVersion(macCurl) == [8, 7, 1], "curl: Version gelesen", "\(String(describing: FTPSClient.curlVersion(macCurl)))")
        check(FTPSClient.curlVersion("curl 8.10.0-DEV (aarch64)") == [8, 10, 0] && FTPSClient.curlVersion("Fehler") == nil,
              "curl: Version mit Zusatz, unlesbar")
        check(FTPSClient.hasUploadBug([8, 7, 1]) && FTPSClient.hasUploadBug([7, 88, 1]) && FTPSClient.hasUploadBug(nil)
              && !FTPSClient.hasUploadBug([8, 9, 0]) && !FTPSClient.hasUploadBug([8, 10, 1]) && !FTPSClient.hasUploadBug([9, 0]),
              "curl: Hochladen über TLS 1.2 bis 8.8")
        check(FTPSClient.uploadAborted(status: 18, errors: "curl: (18) server did not report OK, got 426")
              && FTPSClient.uploadAborted(status: 56, errors: "curl: (56) Recv failure: Connection reset by peer")
              && !FTPSClient.uploadAborted(status: 18, errors: "curl: (18) server did not report OK, got 522")
              && !FTPSClient.uploadAborted(status: 25, errors: "curl: (25) Failed FTP upload: 553"),
              "FTPS: abgebrochenes Hochladen erkannt")
        check(Redactor.clean("PASS geheim123 und geheim123", secrets: ["geheim123"]) == "PASS •••• und ••••", "Geheimnisse geschwärzt")
    }

    static func validation() {
        check(ServerProfile.isValidHost("w0123456.kasserver.com") && ServerProfile.isValidHost("127.0.0.1")
              && ServerProfile.isValidHost("[::1]"), "Host gültig")
        check(!ServerProfile.isValidHost("-oProxyCommand=x") && !ServerProfile.isValidHost("a b")
              && !ServerProfile.isValidHost("host/../x") && !ServerProfile.isValidHost(""), "Host ungültig")
        check(ServerProfile.isValidUser("w0123456") && ServerProfile.isValidUser("ftp@domain.de"), "Benutzer gültig")
        check(!ServerProfile.isValidUser("-x") && !ServerProfile.isValidUser("a b") && !ServerProfile.isValidUser("a:b")
              && !ServerProfile.isValidUser("a%h"), "Benutzer ungültig")
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Alt","proto":"ftps","host":"h","user":"u"}]"#
        let decoded = try? JSONDecoder().decode([ServerProfile].self, from: Data(json.utf8))
        check(decoded?.first?.port == 21 && decoded?.first?.uploadLast == "dist/version.txt, sw.js"
              && decoded?.first?.replaceOnUpload == "dist", "Ältere Verbindungsdatei lesbar (dist wird weiter ersetzt)")
    }

    static func crypto() {
        var profile = ServerProfile()
        profile.name = "Test"
        let payload = SetupTransfer.Payload(created: "heute", servers: [profile], passwords: [profile.id.uuidString: "pw"], knownHosts: "x")
        do {
            let sealed = try SetupTransfer.seal(payload, password: "richtiges Passwort")
            check(!String(decoding: sealed, as: UTF8.self).contains("\"pw\""), "Export: Passwort nicht im Klartext")
            check((try? SetupTransfer.open(sealed, password: "richtiges Passwort")) == payload, "Export: entschlüsselt")
            check((try? SetupTransfer.open(sealed, password: "falsch")) == nil, "Export: falsches Passwort abgelehnt")
            var tampered = sealed
            tampered[tampered.count / 2] ^= 0x01
            check((try? SetupTransfer.open(tampered, password: "richtiges Passwort")) == nil, "Export: veränderte Datei abgelehnt")
        } catch {
            check(false, "Export", error.localizedDescription)
        }
    }

    static func askpass() {
        let dir = temp("askpass")
        guard let server = try? AskpassServer(directory: dir, secret: "geheim-123") else {
            check(false, "Askpass: Server")
            return
        }
        func ask(_ token: String, prompt: String = "filehub@host's password: ") -> (Int32, String) {
            let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let r = Shell.run(me, [prompt], environment: [AskpassServer.socketKey: server.socketPath, AskpassServer.tokenKey: token])
            return (r.status, r.output)
        }
        check(ask(server.token, prompt: "Enter passphrase for key: ").0 != 0, "Askpass: Passphrase-Frage nicht beantwortet")
        check(ask(String(repeating: "0", count: 64)).1.isEmpty, "Askpass: falsches Token bekommt nichts")
        let right = ask(server.token)
        check(right.0 == 0 && right.1 == "geheim-123\n", "Askpass: richtiges Token", "\(right)")
        check(ask(server.token).1.isEmpty, "Askpass: nur einmal")
        let mode = (try? FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) ?? 0
        check(mode & 0o077 == 0 || !FileManager.default.fileExists(atPath: server.socketPath), "Askpass: Ordner privat")
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Server returns "../böse" and a system file: neither may end up on the Mac.
    final class FakeClient: RemoteClient, @unchecked Sendable {
        var profile = ServerProfile()
        func connect(cancel: Cancellation) throws -> ConnectionInfo { ConnectionInfo(summary: "", details: [], home: "/") }
        func list(_ path: String, cancel: Cancellation) throws -> [RemoteEntry] {
            [RemoteEntry(name: "ok.txt", path: path + "/ok.txt", kind: .file, size: 1),
             RemoteEntry(name: "..", path: path + "/..", kind: .directory),
             RemoteEntry(name: ".DS_Store", path: path + "/.DS_Store", kind: .file, size: 1),
             RemoteEntry(name: "x/../../y", path: path + "/x", kind: .file, size: 1)]
        }
        func makeDirectory(_ path: String, cancel: Cancellation) throws {}
        func rename(_ from: String, to: String, cancel: Cancellation) throws {}
        func changeMode(_ paths: [String], to mode: Int, cancel: Cancellation) throws {}
        func delete(files: [String], directories: [String], ignoreErrors: Bool, cancel: Cancellation) throws {}
        func upload(_ files: [UploadPlan.File], directories: [String], last: Int, cancel: Cancellation, progress: @escaping (Int) -> Void) throws {}
        func download(_ files: [DownloadPlan.File], cancel: Cancellation, progress: @escaping (Int) -> Void) throws {}
        func disconnect() {}
    }

    static func downloadPlan() {
        let target = temp("down")
        let plan = try? DownloadPlan.build([RemoteEntry(name: "sub", path: "/srv/sub", kind: .directory)], into: target,
                                           client: FakeClient(), cancel: Cancellation())
        let locals = plan?.files.map { $0.local.path } ?? []
        check(locals == [target.standardizedFileURL.appendingPathComponent("sub/ok.txt").path], "Download: nur sichere Namen", "\(locals)")
        check(plan?.skippedSystem == 1 && plan?.skippedUnsafe.count == 2, "Download: Auslassungen gezählt")
        try? FileManager.default.removeItem(at: target)
    }
}
