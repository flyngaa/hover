import Foundation

/// Discovers the Obsidian vaults on this Mac so they can be offered as output
/// destinations.
///
/// Vaults are only a convenience for *picking* the output folder — Hover saves
/// transcripts to one place and never copies them, so there is nothing to
/// export. Production uses ``ObsidianVaultFinder``; a test can supply a fake
/// that reports canned vaults.
protocol VaultFinder: Sendable {
    func discoverVaults() -> [ObsidianVault]
}

/// ``VaultFinder`` that reads Obsidian's own list of known vaults from its macOS
/// config file, so vaults the user has opened in Obsidian appear automatically.
struct ObsidianVaultFinder: VaultFinder {

    func discoverVaults() -> [ObsidianVault] {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard
            let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let vaults = json["vaults"] as? [String: Any]
        else { return [] }

        var result: [ObsidianVault] = []
        for (_, value) in vaults {
            guard
                let dict = value as? [String: Any],
                let path = dict["path"] as? String
            else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                result.append(ObsidianVault(path: url))
            }
        }
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
