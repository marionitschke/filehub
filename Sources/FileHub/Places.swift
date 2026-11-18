import AppKit

/// A place for the Mac column: a folder in the home folder or a mounted volume
/// (startup volume, external SSD, USB stick, memory card, network share).
struct LocalPlace: Identifiable, Equatable {
    enum Kind { case home, folder, startup, internalDrive, external, network }

    let url: URL
    let name: String
    let kind: Kind
    /// Can be ejected (everything except the startup volume).
    let ejectable: Bool

    var id: String { url.path }

    var symbol: String {
        switch kind {
        case .home: return "house"
        case .folder: return "folder"
        case .startup, .internalDrive: return "internaldrive"
        case .external: return "externaldrive"
        case .network: return "network"
        }
    }
}

enum Places {
    /// Home, Desktop, Documents, Downloads.
    static func folders() -> [LocalPlace] {
        let fm = FileManager.default
        var list = [LocalPlace(url: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), name: "Benutzerordner",
                               kind: .home, ejectable: false)]
        let named: [(FileManager.SearchPathDirectory, String)] = [
            (.desktopDirectory, "Schreibtisch"), (.documentDirectory, "Dokumente"), (.downloadsDirectory, "Downloads"),
        ]
        for (directory, name) in named {
            if let url = fm.urls(for: directory, in: .userDomainMask).first {
                list.append(LocalPlace(url: url, name: name, kind: .folder, ejectable: false))
            }
        }
        return list
    }

    private static let volumeKeys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeIsInternalKey,
        .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsBrowsableKey,
    ]

    /// Mounted volumes: the startup volume and everything under /Volumes that Finder shows.
    /// Special mounts elsewhere (such as ~/OrbStack) are left out.
    static func volumes() -> [LocalPlace] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: volumeKeys,
                                                          options: [.skipHiddenVolumes]) ?? []
        let places = urls.compactMap { url -> LocalPlace? in
            let path = url.standardizedFileURL.path
            guard path == "/" || volumeRoot(of: url)?.path == path,
                  let values = try? url.resourceValues(forKeys: Set(volumeKeys)),
                  values.volumeIsBrowsable != false else { return nil }
            let name = values.volumeLocalizedName ?? url.lastPathComponent
            if values.volumeIsRootFileSystem == true || path == "/" {
                return LocalPlace(url: URL(fileURLWithPath: "/", isDirectory: true), name: name, kind: .startup, ejectable: false)
            }
            let kind: LocalPlace.Kind = values.volumeIsLocal == false ? .network
                : values.volumeIsInternal == true ? .internalDrive : .external
            return LocalPlace(url: URL(fileURLWithPath: path, isDirectory: true), name: name, kind: kind, ejectable: true)
        }
        return places.sorted { a, b in
            if (a.kind == .startup) != (b.kind == .startup) { return a.kind == .startup }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Root of the /Volumes volume containing `url` ("/Volumes/SSD/a/b" → "/Volumes/SSD").
    static func volumeRoot(of url: URL) -> URL? {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes/" + parts[2], isDirectory: true)
    }

    /// Is `url` inside `folder` (or `folder` itself)?
    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = folder.standardizedFileURL.path
        if base == "/" { return true }
        return path == base || path.hasPrefix(base + "/")
    }

    /// Free space on the volume of `url`; nil if macOS reports none.
    static func freeSpace(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        else { return nil }
        // Some volumes (exFAT, network) report one of the two values as 0: take the larger one,
        // so a volume is never wrongly reported as full.
        let free = max(values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeAvailableCapacity ?? 0))
        return free > 0 ? free : nil
    }

    /// Path for display, with the home folder as "~".
    static func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
