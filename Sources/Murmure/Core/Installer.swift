import AppKit

/// Installation depuis le DMG : si Murmure est lancé directement depuis l'image disque (ou depuis la copie
/// « translocalisée » que macOS crée pour une app non installée), il propose de se ranger tout seul dans
/// Applications. Lancé depuis Applications, il éjecte le DMG resté monté.
/// La copie garde les attributs du fichier (dont la quarantaine) : les vérifications de macOS restent entières.
enum Installer {
    static let destination = URL(fileURLWithPath: "/Applications/Murmure.app")

    private static var bundlePath: String { Bundle.main.bundleURL.standardizedFileURL.path }

    static var runsFromApplications: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/")
    }

    /// Lancé depuis le DMG, depuis sa copie translocalisée, ou depuis Téléchargements. Un build de
    /// développement (dossier build/) n'est pas concerné.
    static var runsFromDownload: Bool {
        if runsFromApplications { return false }
        if UserDefaults.standard.bool(forKey: "demoInstall") { return true }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "~"
        return bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/") || bundlePath.hasPrefix(downloads + "/")
    }

    private static func info(_ app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Une copie de Murmure au moins aussi récente est déjà dans Applications.
    static var installedCopyIsCurrent: Bool {
        guard let info = info(destination),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String else { return false }
        return version.compare(currentVersion, options: .numeric) != .orderedAscending
    }

    enum Failure: Error { case copy(String) }

    /// Copie l'app dans Applications (l'ancienne version part à la corbeille), puis l'ouvre.
    static func install() async throws {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        try await Task.detached {
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.trashItem(at: destination, resultingItemURL: nil)
                }
                try fm.copyItem(at: source, to: destination)
            } catch {
                throw Failure.copy(error.localizedDescription)
            }
        }.value
        await openInstalledCopy()
    }

    /// Ouvre la copie installée et quitte celle-ci (celle du DMG).
    @MainActor static func openInstalledCopy() async {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        _ = try? await NSWorkspace.shared.openApplication(at: destination, configuration: config)
        NSApp.terminate(nil)
    }

    /// Plan B si la copie échoue : le dossier Applications s'ouvre, l'utilisateur y glisse l'icône.
    @MainActor static func revealApplications() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }

    /// Lancé depuis Applications : éjecte les images disque de Murmure encore montées.
    /// Petit délai : la copie lancée depuis le DMG met un instant à se fermer.
    @MainActor static func ejectDiskImages() {
        guard runsFromApplications else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsInternalKey]
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
            for volume in volumes where volume.path.hasPrefix("/Volumes/") {
                let values = try? volume.resourceValues(forKeys: Set(keys))
                guard values?.volumeIsEjectable == true, values?.volumeIsInternal != true,
                      info(volume.appendingPathComponent("Murmure.app"))?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
                else { continue }
                try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            }
        }
    }
}
