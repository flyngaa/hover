import Foundation
import HoverCore

/// ``VaultFinder`` that reads Obsidian's own list of known vaults from its macOS
/// config file, so vaults the user has opened in Obsidian appear automatically.
public struct ObsidianVaultFinder: VaultFinder {

    public init() {}

    public func discoverVaults() -> [ObsidianVault] {
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
