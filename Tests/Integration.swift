// Real runs against the Docker test server (scripts/testserver.sh), only via scripts/check.sh --server.
import Foundation

enum Integration {
    static let host = "127.0.0.1"
    static let user = "filehub"
    static let password = "filehub-test-pw"

    static func profile(_ proto: TransferProtocol, port: Int, auth: AuthMethod = .password, host: String = host) -> ServerProfile {
        var p = ServerProfile()
        p.name = "Prüfung \(proto.short) \(port)"
        p.proto = proto
        p.host = host
        p.port = port
        p.user = user
        p.auth = auth
        p.keyPath = FileManager.default.currentDirectoryPath + "/build/test/id_test"
        p.neverUpload = "php/config.php, logs"
        return p
    }

    static func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        Checks.check(condition, label, detail())
    }

    static func run() {
        try? FileManager.default.removeItem(at: HostKeys.file)

        // SFTP: unknown server → fingerprint → confirm
        check(!HostKeys.isKnown(host: host, port: 2222), "SFTP: Server anfangs unbekannt")
        do {
            let scan = try HostKeys.scan(host: host, port: 2222)
            check(scan.fingerprints.contains { $0.hasPrefix("ED25519  SHA256:") }, "SFTP: Fingerabdrücke", "\(scan.fingerprints)")
            try HostKeys.trust(scan)
            check(HostKeys.isKnown(host: host, port: 2222), "SFTP: nach Bestätigung bekannt")
            check(!HostKeys.knownFingerprints(host: host, port: 2222).isEmpty, "SFTP: gespeicherte Fingerabdrücke lesbar",
                  "\(HostKeys.knownFingerprints(host: host, port: 2222))")
        } catch {
            check(false, "SFTP: Hostschlüssel", error.localizedDescription)
        }

        exercise(SFTPClient(profile: profile(.sftp, port: 2222), password: password), label: "SFTP Passwort")
        exercise(SFTPClient(profile: profile(.sftp, port: 2222, auth: .key), password: nil), label: "SFTP Schlüssel")
        exercise(FTPSClient(profile: profile(.ftps, port: 2121, host: "localhost"), password: password), label: "FTPS vsftpd")
        exercise(FTPSClient(profile: profile(.ftps, port: 2122, host: "localhost"), password: password), label: "FTPS Pure-FTPd")
        let before = (tls12: proftpdData("TLSv1.2"), tls13: proftpdData("TLSv1.3"))
        exercise(FTPSClient(profile: profile(.ftps, port: 2124, host: "localhost"), password: password), label: "FTPS ProFTPD")
        // As at All-inkl: listing over TLS 1.3, uploads with the macOS curl over TLS 1.2 (curl#13556).
        let tls12 = proftpdData("TLSv1.2") - before.tls12, tls13 = proftpdData("TLSv1.3") - before.tls13
        check(tls13 > 0 && (tls12 > 0) == FTPSClient.curlHasUploadBug, "FTPS ProFTPD: Datenkanal TLS 1.3, Hochladen TLS 1.2",
              "TLS 1.2: \(tls12), TLS 1.3: \(tls13)")
        loginCounts()

        refusals()
    }

    /// Data connections of the ProFTPD test server with this TLS version, from its TLS log.
    static func proftpdData(_ version: String) -> Int {
        let result = Shell.run("/usr/local/bin/docker", ["exec", "filehub-testserver", "grep", "-c",
                                                         "\(version) data connection accepted", "/var/log/proftpd-tls.log"])
        return Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Logins at the vsftpd test server from its log ("OK LOGIN" / "FAIL LOGIN").
    static func vsftpdLogins(_ kind: String) -> Int {
        let result = Shell.run("/usr/local/bin/docker", ["exec", "filehub-testserver", "grep", "-c", "\(kind) LOGIN", "/var/log/vsftpd-tls.log"])
        return Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Counts FTPS logins per operation: one per folder level instead of per folder, one each for
    /// delete plus check and for create plus upload, a single attempt with a wrong password.
    static func loginCounts() {
        let cancel = Cancellation()
        let client = FTPSClient(profile: profile(.ftps, port: 2121, host: "localhost"), password: password)
        func logins(_ work: () throws -> Void) rethrows -> Int {
            let before = vsftpdLogins("OK")
            try work()
            return vsftpdLogins("OK") - before
        }
        do {
            let home = try client.connect(cancel: cancel).home
            // As in the app: show the home folder first. vsftpd has no MLSD; the fallback to LIST happens
            // once per session and does not count towards the operations below.
            _ = try client.list(home, cancel: cancel)
            let base = RemotePath.join(home, "fh-zaehlen-\(UUID().uuidString.prefix(6).lowercased())")
            // dist with four folders side by side and two levels below: dist / a b c d / x / y
            let local = Checks.temp("zaehlen")
            for name in ["a/x/y/tief.txt", "a/eins.txt", "b/zwei.txt", "c/drei.txt", "d/vier.txt", "index.html"] {
                Checks.write(name, local.appendingPathComponent("dist/" + name))
            }
            let plan = UploadPlan.build(items: [local.appendingPathComponent("dist")], into: base,
                                        neverUpload: PathPatterns(""), uploadLast: PathPatterns(""),
                                        replace: PathPatterns("dist"))
            check(try logins { try client.upload(plan.files, directories: [base] + plan.directories, cancel: cancel) { _ in } } == 1,
                  "FTPS Anmeldungen: Ordner anlegen und hochladen = 1")
            try Data(repeating: 0x62, count: 1_200_000).write(to: local.appendingPathComponent("gross.bin"))
            let withBig = [UploadPlan.File(local: local.appendingPathComponent("dist/index.html"), remote: base + "/klein1.html", size: 15),
                           UploadPlan.File(local: local.appendingPathComponent("gross.bin"), remote: base + "/gross.bin", size: 1_200_000),
                           UploadPlan.File(local: local.appendingPathComponent("dist/index.html"), remote: base + "/klein2.html", size: 15)]
            check(try logins { try client.upload(withBig, directories: [], cancel: cancel) { _ in } } == 1,
                  "FTPS Anmeldungen: große Datei mit Zwischennamen zwischen kleinen = 1")
            var tree: (files: [RemoteEntry], directories: [String]) = ([], [])
            let walked = try logins { tree = try client.walk([base + "/dist"], cancel: cancel) }
            check(walked == 4 && tree.files.count == 6 && tree.directories.count == 7,
                  "FTPS Anmeldungen: 7 Ordner lesen = 4 (je Ebene eine)", "\(walked) Anmeldungen, \(tree.files.count) Dateien")
            check(try logins { try client.changeMode([base + "/dist/index.html", base + "/dist/a"], to: 0o755, cancel: cancel) } == 1,
                  "FTPS Anmeldungen: Rechte für 2 Einträge = 1")
            var listings: [String: Result<[RemoteEntry], RemoteError>] = [:]
            let mixed = try logins { listings = try client.listMany([base + "/dist/a", base + "/fehlt", base + "/dist/b"], cancel: cancel) }
            check(mixed == 2 && (try? listings[base + "/dist/b"]?.get())?.count == 1 && (try? listings[base + "/fehlt"]?.get()) == nil,
                  "FTPS Anmeldungen: fehlender Ordner mitten im Stapel = 2", "\(mixed)")
            var found: [RemoteTree] = []
            let search = try logins { found = try Transfers.oldVersions(plan, client: client, cancel: cancel) }
            check(search == 4 && found.map(\.root) == [base + "/dist"] && found.first?.files.count == 6
                  && found.first?.directories.count == 7,
                  "FTPS Anmeldungen: dist suchen und einlesen (vor der Rückfrage) = 4 Ebenen", "\(search), \(found.map(\.root))")
            var gone = false
            guard let old = found.first else { throw RemoteError("dist nicht gefunden") }
            let removal = try logins { gone = try client.deleteTree(old, cancel: cancel) }
            check(removal == 1 && gone, "FTPS Anmeldungen: dist löschen und prüfen = 1", "\(removal)")
            let missing = try logins { found = try Transfers.oldVersions(plan, client: client, cancel: cancel) }
            check(missing == 1 && found.isEmpty, "FTPS Anmeldungen: kein dist da = 1", "\(missing)")

            // Many files: two connections, the second only after the first file; "Zuletzt hochladen"
            // afterwards over a third login, in pattern order.
            let many = Checks.temp("parallel")
            for index in 0..<FTPSClient.parallelMinimum + 5 {
                Checks.write("\(index)", many.appendingPathComponent("site/\(["a", "b", "c"][index % 3])/f\(index).txt"))
            }
            Checks.write("v", many.appendingPathComponent("site/version.txt"))
            Checks.write("s", many.appendingPathComponent("site/sw.js"))
            let big = UploadPlan.build(items: [many.appendingPathComponent("site")], into: base,
                                       neverUpload: PathPatterns(""), uploadLast: PathPatterns("sw.js, version.txt"),
                                       replace: PathPatterns(""))
            var counted = 0
            let parallel = try logins {
                try client.upload(big.files, directories: big.directories, last: big.lastCount, cancel: cancel) { counted = max(counted, $0) }
            }
            let uploaded = try client.walk([base + "/site"], cancel: cancel).files.count
            let order = Shell.run("/usr/local/bin/docker", ["exec", "filehub-testserver", "sh", "-c",
                                                            "grep 'OK UPLOAD' /var/log/vsftpd-tls.log | tail -2"]).output
            let lastTwo = order.split(separator: "\n").map { $0.contains("/site/sw.js\"") ? "sw.js" : $0.contains("/site/version.txt\"") ? "version.txt" : "?" }
            check(parallel == 3 && uploaded == big.files.count && counted == big.files.count && big.lastCount == 2,
                  "FTPS: \(big.files.count) Dateien über 2 Verbindungen + Zuletzt hochladen = 3 Anmeldungen",
                  "\(parallel) Anmeldungen, \(uploaded) auf dem Server, Fortschritt \(counted)")
            check(lastTwo == ["sw.js", "version.txt"], "FTPS parallel: Zuletzt hochladen kommt zuletzt", "\(lastTwo)")
            let wrongMany = FTPSClient(profile: profile(.ftps, port: 2121, host: "localhost"), password: "falsch-falsch")
            let failedBefore = vsftpdLogins("FAIL")
            let refused = (try? wrongMany.upload(big.files, directories: [], cancel: cancel) { _ in }) == nil
            check(refused && vsftpdLogins("FAIL") - failedBefore == 1, "FTPS parallel: falsches Passwort = 1 Fehlversuch",
                  "\(vsftpdLogins("FAIL") - failedBefore)")
            _ = try client.deleteRecursively([RemoteEntry(name: RemotePath.name(base), path: base, kind: .directory)],
                                             ignoreErrors: false, cancel: cancel)
        } catch {
            check(false, "FTPS Anmeldungen zählen", error.localizedDescription)
        }

        // Wrong password: one failed attempt, not one per folder.
        let wrong = FTPSClient(profile: profile(.ftps, port: 2121, host: "localhost"), password: "falsch-falsch")
        let before = vsftpdLogins("FAIL")
        _ = try? wrong.listMany(["/a", "/b", "/c", "/d"], cancel: cancel)
        let failed = vsftpdLogins("FAIL") - before
        check(failed == 1, "FTPS: falsches Passwort = 1 Fehlversuch für 4 Ordner", "\(failed)")
    }

    static func expectFailure(_ label: String, contains text: String, _ work: () throws -> Void) {
        do {
            try work()
            Checks.check(false, label, "kein Fehler")
        } catch {
            Checks.check(error.localizedDescription.contains(text), label, error.localizedDescription)
        }
    }

    static func refusals() {
        let cancel = Cancellation()
        expectFailure("FTPS: unverschlüsselter Server abgelehnt", contains: "kein FTP über TLS") {
            _ = try FTPSClient(profile: profile(.ftps, port: 2123, host: "localhost"), password: password).connect(cancel: cancel)
        }
        let ca = FTPSClient.testCA
        FTPSClient.testCA = nil
        expectFailure("FTPS: unbekanntes Zertifikat abgelehnt", contains: "nicht vertrauenswürdig") {
            _ = try FTPSClient(profile: profile(.ftps, port: 2122, host: "localhost"), password: password).connect(cancel: cancel)
        }
        FTPSClient.testCA = ca
        expectFailure("FTPS: falsches Passwort", contains: "Anmeldung abgelehnt") {
            _ = try FTPSClient(profile: profile(.ftps, port: 2122, host: "localhost"), password: "falsch").connect(cancel: cancel)
        }
        expectFailure("FTPS: Hostname passt nicht zum Zertifikat", contains: "nicht vertrauenswürdig") {
            var p = profile(.ftps, port: 2122, host: "localhost")
            p.host = "127.0.0.1"
            _ = try FTPSClient(profile: p, password: password).connect(cancel: cancel)
        }
        expectFailure("SFTP: falsches Passwort", contains: "Anmeldung abgelehnt") {
            _ = try SFTPClient(profile: profile(.sftp, port: 2222), password: "falsch").connect(cancel: cancel)
        }
        expectFailure("SFTP: unbekannter Server", contains: "nicht bestätigt") {
            _ = try SFTPClient(profile: profile(.sftp, port: 2222, host: "localhost"), password: password).connect(cancel: cancel)
        }
        // Stored key does not match: the connection must fail.
        let saved = HostKeys.exportText()
        HostKeys.forget(host: host, port: 2222)
        let fake = (try? String(contentsOfFile: "build/test/id_test.pub", encoding: .utf8))?
            .split(separator: " ").prefix(2).joined(separator: " ") ?? ""
        try? HostKeys.importText("[\(host)]:2222 \(fake)")
        expectFailure("SFTP: geänderter Hostschlüssel abgelehnt", contains: "passt nicht zum gespeicherten") {
            _ = try SFTPClient(profile: profile(.sftp, port: 2222), password: password).connect(cancel: cancel)
        }
        try? FileManager.default.removeItem(at: HostKeys.file)
        try? HostKeys.importText(saved)
    }

    static func exercise(_ client: RemoteClient, label: String) {
        let cancel = Cancellation()
        defer { client.disconnect() }
        do {
            let info = try client.connect(cancel: cancel)
            print("· \(label): \(info.summary) – Anmeldeordner \(info.home)")
            check(!info.summary.isEmpty, "\(label): verbunden")
            if let tls = info.details.first(where: { $0.hasPrefix("TLS: TLSv1.2") }) {
                check(tls.contains("ECDHE") && (tls.contains("GCM") || tls.contains("CHACHA20")),
                      "\(label): TLS 1.2 nur mit Forward Secrecy und AEAD", tls)
            }
            let base = RemotePath.join(info.home, "fh-\(UUID().uuidString.prefix(6).lowercased())")
            try client.makeDirectory(base, cancel: cancel)

            // Old version with dist/alt.js on the server.
            let stale = Checks.temp("stale")
            Checks.write("alt", stale.appendingPathComponent("dist/alt.js"))
            let stalePlan = UploadPlan.build(items: [stale.appendingPathComponent("dist")], into: base,
                                             neverUpload: PathPatterns(""), uploadLast: PathPatterns(""),
                                        replace: PathPatterns(""))
            _ = try Transfers.upload(stalePlan, replacing: [], client: client, cancel: cancel) { _ in }
            check(try client.list(base + "/dist", cancel: cancel).map(\.name) == ["alt.js"], "\(label): alter Stand liegt")

            // New version: contents of public/ with system files, rules and special characters.
            let local = Checks.temp("public")
            Checks.write("x", local.appendingPathComponent(".DS_Store"))
            Checks.write("RewriteEngine On", local.appendingPathComponent(".htaccess"))
            Checks.write("<?php echo 1;", local.appendingPathComponent("index.php"))
            Checks.write("sw", local.appendingPathComponent("sw.js"))
            Checks.write("v2", local.appendingPathComponent("dist/version.txt"))
            Checks.write("neu", local.appendingPathComponent("dist/js/app.js"))
            Checks.write("x", local.appendingPathComponent("dist/js/._app.js"))
            Checks.write("geheim", local.appendingPathComponent("php/config.php"))
            Checks.write("ok", local.appendingPathComponent("php/lib.php"))
            Checks.write("log", local.appendingPathComponent("logs/a.log"))
            Checks.write("sonder", local.appendingPathComponent("bilder/Foto [1] *neu* \"Ä\".txt"))
            Checks.write("nfd", local.appendingPathComponent("Ma\u{0308}dchen.txt"))
            try FileManager.default.createDirectory(at: local.appendingPathComponent("leer"), withIntermediateDirectories: true)
            let items = try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)
            let plan = UploadPlan.build(items: items, into: base, neverUpload: client.profile.neverUploadPatterns,
                                        uploadLast: client.profile.uploadLastPatterns, replace: client.profile.replacePatterns)
            let dist = try Transfers.oldVersions(plan, client: client, cancel: cancel)
            check(dist.map(\.root) == [base + "/dist"] && dist.first?.files.map(\.name) == ["alt.js"],
                  "\(label): bestehendes dist erkannt und eingelesen", "\(dist)")
            var steps: [String] = []
            var counts: [Int] = []
            let report = try Transfers.upload(plan, replacing: dist, client: client, cancel: cancel) { step in
                switch step {
                case .deleting(let path): steps.append(path)
                case .transferring(let done): counts.append(done)
                }
            }
            check(report.replaced == [base + "/dist"] && steps == [base + "/dist"], "\(label): dist vorher gelöscht")
            // Progress "in progress" = plan.files[done]: every count from 0 to all, ascending.
            check(counts == counts.sorted() && Set(counts) == Set(0...plan.files.count),
                  "\(label): Fortschritt je Datei", "\(counts) bei \(plan.files.count) Dateien")

            let top = try client.list(base, cancel: cancel).map(\.name).sorted()
            check(top == [".htaccess", "Mädchen.txt", "bilder", "dist", "index.php", "leer", "php", "sw.js"], "\(label): Inhalt oben", "\(top)")
            check(try client.list(base + "/dist", cancel: cancel).map(\.name).sorted() == ["js", "version.txt"], "\(label): dist ohne alte Datei")
            check(try client.list(base + "/dist/js", cancel: cancel).map(\.name) == ["app.js"], "\(label): ohne ._-Datei")
            check(try client.list(base + "/php", cancel: cancel).map(\.name) == ["lib.php"], "\(label): config.php nicht hochgeladen")
            check(try client.list(base + "/bilder", cancel: cancel).map(\.name) == ["Foto [1] *neu* \"Ä\".txt"], "\(label): Sonderzeichen")
            let index = try client.list(base, cancel: cancel).first { $0.name == "index.php" }
            check(index?.size == 13 && index?.modified != nil, "\(label): Größe und Datum", "\(String(describing: index))")

            // Rename
            try client.rename(base + "/sw.js", to: base + "/sw alt.js", cancel: cancel)
            check(try client.list(base, cancel: cancel).contains { $0.name == "sw alt.js" }, "\(label): umbenannt")

            // Permissions: a file and a folder in one go; the folder stays readable for the download below.
            try client.changeMode([base + "/index.php", base + "/bilder"], to: 0o640, cancel: cancel)
            try client.changeMode([base + "/bilder"], to: 0o750, cancel: cancel)
            let modes = Dictionary(try client.list(base, cancel: cancel).map { ($0.name, $0.mode) }, uniquingKeysWith: { a, _ in a })
            check(modes["index.php"] == 0o640 && modes["bilder"] == 0o750, "\(label): Rechte geändert",
                  "\(modes.mapValues { $0.map(FileMode.octal) ?? "-" })")

            // A big file goes up under a temporary name and replaces the older version only when complete.
            let bigDir = Checks.temp("gross")
            try Data(repeating: 0x61, count: 1_500_000).write(to: bigDir.appendingPathComponent("gross.bin"))
            Checks.write("vorher", bigDir.appendingPathComponent("a.txt"))
            Checks.write("nachher", bigDir.appendingPathComponent("z.txt"))
            try client.upload([UploadPlan.File(local: bigDir.appendingPathComponent("a.txt"), remote: base + "/gross.bin", size: 6)],
                              directories: [], cancel: cancel) { _ in }
            let mixed = ["a.txt", "gross.bin", "z.txt"].map { name in
                UploadPlan.File(local: bigDir.appendingPathComponent(name), remote: base + "/" + name,
                                size: (try? FileManager.default.attributesOfItem(atPath: bigDir.appendingPathComponent(name).path)[.size] as? Int64) ?? 0)
            }
            var mixedCount = 0
            try client.upload(mixed, directories: [], cancel: cancel) { mixedCount = $0 }
            let afterBig = try client.list(base, cancel: cancel)
            check(afterBig.first { $0.name == "gross.bin" }?.size == 1_500_000 && afterBig.contains { $0.name == "z.txt" }
                  && !afterBig.contains { $0.name.hasSuffix(Partial.suffix) } && mixedCount == 3,
                  "\(label): große Datei über Zwischennamen ersetzt", "\(afterBig.map { "\($0.name) \($0.size ?? -1)" })")

            // Junk on the server is not downloaded.
            let junk = Checks.temp("junk")
            Checks.write("x", junk.appendingPathComponent(".DS_Store"))
            try client.upload([UploadPlan.File(local: junk.appendingPathComponent(".DS_Store"), remote: base + "/dist/.DS_Store", size: 1)],
                              directories: [], cancel: cancel) { _ in }
            let down = Checks.temp("down")
            let entries = try client.list(base, cancel: cancel).filter { ["dist", "bilder", "index.php"].contains($0.name) }
            let downPlan = try DownloadPlan.build(entries, into: down, client: client, cancel: cancel)
            check(downPlan.skippedSystem == 1, "\(label): Systemdatei vom Server ausgelassen")
            var count = 0
            Checks.write("alt", down.appendingPathComponent("index.php"))
            try Transfers.download(downPlan, client: client, cancel: cancel) { count = $0 }
            let leftovers = FileManager.default.enumerator(atPath: down.path)?.compactMap { $0 as? String }
                .filter { $0.hasSuffix(Partial.suffix) } ?? []
            check((try? String(contentsOf: down.appendingPathComponent("index.php"), encoding: .utf8)) == "<?php echo 1;" && leftovers.isEmpty,
                  "\(label): Download ersetzt erst fertig, keine Zwischendateien", "\(leftovers)")
            check(count == downPlan.files.count && count == 4, "\(label): Fortschritt beim Herunterladen", "\(count)")
            let got = try? String(contentsOf: down.appendingPathComponent("dist/version.txt"), encoding: .utf8)
            let special = try? String(contentsOf: down.appendingPathComponent("bilder/Foto [1] *neu* \"Ä\".txt"), encoding: .utf8)
            check(got == "v2" && special == "sonder", "\(label): heruntergeladen")
            check(!FileManager.default.fileExists(atPath: down.appendingPathComponent("dist/.DS_Store").path), "\(label): keine .DS_Store auf dem Mac")
            check(downPlan.files.allSatisfy { Quarantine.isMarked($0.local) }, "\(label): Heruntergeladenes mit Quarantäne-Markierung")

            // Mac folder with a line break in its name: FTPS transfers it literally, sftp refuses cleanly
            // (its batch is line-based). In no case does it become another command.
            let odd = Checks.temp("zeile\ninsecure")
            Checks.write("umbruch", odd.appendingPathComponent("umbruch.txt"))
            let oddPlan = UploadPlan.build(items: [odd.appendingPathComponent("umbruch.txt")], into: base,
                                           neverUpload: PathPatterns(""), uploadLast: PathPatterns(""), replace: PathPatterns(""))
            do {
                try client.upload(oddPlan.files, directories: [], cancel: cancel) { _ in }
                let back = odd.appendingPathComponent("zurück.txt")
                try client.download([DownloadPlan.File(remote: base + "/umbruch.txt", local: back, size: nil)], cancel: cancel) { _ in }
                check(client is FTPSClient && (try? String(contentsOf: back, encoding: .utf8)) == "umbruch",
                      "\(label): Mac-Pfad mit Zeilenumbruch")
            } catch {
                check(client is SFTPClient && error.localizedDescription.contains("Unzulässiger Pfad"),
                      "\(label): Mac-Pfad mit Zeilenumbruch", error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: odd)

            // Clean up
            let deleted = try client.deleteRecursively([RemoteEntry(name: RemotePath.name(base), path: base, kind: .directory)],
                                                       ignoreErrors: false, cancel: cancel)
            let remaining = try client.list(info.home, cancel: cancel)
            check(deleted > 5 && !remaining.contains { $0.path == base }, "\(label): aufgeräumt")
            for url in [stale, local, junk, down] { try? FileManager.default.removeItem(at: url) }
        } catch {
            check(false, "\(label)", error.localizedDescription)
        }
    }
}
