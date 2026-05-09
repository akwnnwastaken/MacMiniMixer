import AppKit

struct WorkspaceApplicationLister: ApplicationListing {
    private let fallbackLister: ApplicationListing
    private let defaultVolume: Double

    init(
        fallbackLister: ApplicationListing = MockApplicationLister(),
        defaultVolume: Double = 70
    ) {
        self.fallbackLister = fallbackLister
        self.defaultVolume = defaultVolume
    }

    func listApplications() -> [MixerAppItem] {
        var seenAppIDs = Set<MixerAppItem.ID>()

        let applications = NSWorkspace.shared.runningApplications
            .filter(isUserFacingApplication)
            .compactMap { application -> MixerAppItem? in
                guard let name = cleanName(for: application) else {
                    return nil
                }

                let id = stableID(for: application)
                guard seenAppIDs.insert(id).inserted else {
                    return nil
                }

                return MixerAppItem(
                    id: id,
                    name: name,
                    icon: icon(for: application),
                    processIdentifier: application.processIdentifier,
                    volume: defaultVolume
                )
            }
            .sorted { first, second in
                first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            }

        return applications.isEmpty ? fallbackLister.listApplications() : applications
    }

    private func isUserFacingApplication(_ application: NSRunningApplication) -> Bool {
        guard application.activationPolicy == .regular else {
            return false
        }

        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return false
        }

        if let currentBundleID = Bundle.main.bundleIdentifier,
           application.bundleIdentifier == currentBundleID {
            return false
        }

        return cleanName(for: application) != nil
    }

    private func cleanName(for application: NSRunningApplication) -> String? {
        guard let name = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }

        return name
    }

    private func stableID(for application: NSRunningApplication) -> MixerAppItem.ID {
        if let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier)"
        }

        if let executablePath = application.executableURL?.path, !executablePath.isEmpty {
            return "executable:\(executablePath)"
        }

        return "pid:\(application.processIdentifier)"
    }

    private func icon(for application: NSRunningApplication) -> MixerAppIcon {
        if let icon = application.icon {
            return .image(icon)
        }

        return .systemSymbol("app.dashed")
    }
}
